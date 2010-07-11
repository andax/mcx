////////////////////////////////////////////////////////////////////////////////
//
//  Monte Carlo eXtreme (MCX)  - GPU accelerated Monte Carlo 3D photon migration
//  Author: Qianqian Fang <fangq at nmr.mgh.harvard.edu>
//
//  Reference (Fang2009):
//        Qianqian Fang and David A. Boas, "Monte Carlo Simulation of Photon 
//        Migration in 3D Turbid Media Accelerated by Graphics Processing 
//        Units," Optics Express, vol. 17, issue 22, pp. 20178-20190 (2009)
//
//  mcx_core.cu: GPU kernels and CUDA host code
//
//  License: GNU General Public License v3, see LICENSE.txt for details
//
////////////////////////////////////////////////////////////////////////////////

#include "br2cu.h"
#include "mcx_core.h"
#include "tictoc.h"
#include "mcx_const.h"

#ifdef USE_MT_RAND
#include "mt_rand_s.cu"     // use Mersenne Twister RNG (MT)
#else
#include "logistic_rand.cu" // use Logistic Lattice ring 5 RNG (LL5)
#endif


// optical properties saved in the constant memory
// {x}:mua,{y}:mus,{z}:anisotropy (g),{w}:refraction index (n)
__constant__ float4 gproperty[MAX_PROP];

// kernel constant parameters
__constant__ MCXParam gcfg[1];

// tested with texture memory for media, only improved 1% speed
// to keep code portable, use global memory for now
// also need to change all media[idx1d] to tex1Dfetch() below
//texture<uchar, 1, cudaReadModeElementType> texmedia;

#ifdef USE_ATOMIC
/*
 float-atomic-add from:
 http://forums.nvidia.com/index.php?showtopic=67691&st=0&p=380935&#entry380935
 this makes the program non-scalable and about 5 times slower compared 
 with non-atomic write, see Fig. 4 and 7 in Fang2009
*/
__device__ inline void atomicFloatAdd(float *address, float val){
      int i_val = __float_as_int(val);
      int tmp0 = 0,tmp1;
      while( (tmp1 = atomicCAS((int *)address, tmp0, i_val)) != tmp0){
              tmp0 = tmp1;
              i_val = __float_as_int(val + __int_as_float(tmp1));
      }
}
#endif

/*
   this is the core Monte Carlo simulation kernel, please see Fig. 1 in Fang2009
*/
kernel void mcx_main_loop(int nphoton,int ophoton,uchar media[],float field[],
     float genergy[],uint n_seed[],float4 n_pos[],float4 n_dir[],float4 n_len[]){

     int idx= blockDim.x * blockIdx.x + threadIdx.x;

     MCXpos  p,p0;//{x,y,z}: coordinates, w:packet weight
     MCXdir  v;   //{x,y,z}: unitary direction vector, nscat:total scat event
     MCXtime f;   //tscat: remaining scattering time,t: photon elapse time, 
                  //tnext: next accumulation time, ndone: completed photons
     float3 htime;            //reflection var
     float  energyloss=genergy[idx<<1];
     float  energyabsorbed=genergy[(idx<<1)+1];

     int np,idx1d, idx1dold,idxorig;   //idx1dold is related to reflection
     //np=nphoton+((idx==blockDim.x*gridDim.x-1) ? ophoton: 0);

#ifdef TEST_RACING
     int cc=0;
#endif
     uchar  mediaid, mediaidorig;
     char   medid=-1;
     float  atten;         //can be taken out to minimize registers
     float  flipdir,n1,Rtotal;   //reflection var

     //for MT RNG, these will be zero-length arrays and be optimized out
     RandType t[RAND_BUF_LEN],tnew[RAND_BUF_LEN];
     Medium prop;    //can become float2 if no reflection

     float len,cphi,sphi,theta,stheta,ctheta,tmp0,tmp1;
     float accumweight=0.f;

     *((float4*)(&p))=n_pos[idx];
     *((float4*)(&v))=n_dir[idx];
     *((float4*)(&f))=n_len[idx];

     gpu_rng_init(t,tnew,n_seed,idx);

     // assuming the initial position is within the domain (mcx_config is supposed to ensure)
     idx1d=gcfg->isrowmajor?int(floorf(p.x)*gcfg->dimlen.y+floorf(p.y)*gcfg->dimlen.x+floorf(p.z)):\
                      int(floorf(p.z)*gcfg->dimlen.y+floorf(p.y)*gcfg->dimlen.x+floorf(p.x));
     idxorig=idx1d;
     mediaid=media[idx1d];
     mediaidorig=mediaid;
	  
     if(mediaid==0) {
          return; // the initial position is not within the medium
     }
     *((float4*)(&prop))=gproperty[mediaid];

     /*
      using a while-loop to terminate a thread by np will cause MT RNG to be 3.5x slower
      LL5 RNG will only be slightly slower than for-loop with photon-move criterion
     */
     //while(f.ndone<np) {

     for(np=0;np<nphoton;np++){ // here nphoton actually means photon moves

          GPUDEBUG(("*i= (%d) L=%f w=%e a=%f\n",(int)f.ndone,f.tscat,p.w,f.t));

	  if(f.tscat<=0.f) {  // if this photon has finished the current jump
               rand_need_more(t,tnew);
   	       f.tscat=rand_next_scatlen(t);

               GPUDEBUG(("next scat len=%20.16e \n",f.tscat));
	       if(p.w<1.f){ //weight
                       //random arimuthal angle
                       tmp0=TWO_PI*rand_next_aangle(t); //next arimuth angle
                       sincosf(tmp0,&sphi,&cphi);
                       GPUDEBUG(("next angle phi %20.16e\n",tmp0));

                       //Henyey-Greenstein Phase Function, "Handbook of Optical 
                       //Biomedical Diagnostics",2002,Chap3,p234, also see Boas2002

                       if(prop.g>EPS){  //if prop.g is too small, the distribution of theta is bad
		           tmp0=(1.f-prop.g*prop.g)/(1.f-prop.g+2.f*prop.g*rand_next_zangle(t));
		           tmp0*=tmp0;
		           tmp0=(1.f+prop.g*prop.g-tmp0)/(2.f*prop.g);

                           // when ran=1, CUDA will give me 1.000002 for tmp0 which produces nan later
                           // detected by Ocelot,thanks to Greg Diamos,see http://bit.ly/cR2NMP
                           tmp0=max(-1.f, min(1.f, tmp0));

		           theta=acosf(tmp0);
		           stheta=sinf(theta);
		           ctheta=tmp0;
                       }else{  //Wang1995 has acos(2*ran-1), rather than 2*pi*ran, need to check
			   theta=ONE_PI*rand_next_zangle(t);
                           sincosf(theta,&stheta,&ctheta);
                       }
                       GPUDEBUG(("next scat angle theta %20.16e\n",theta));

		       if( v.z>-1.f+EPS && v.z<1.f-EPS ) {
		           tmp0=1.f-v.z*v.z;   //reuse tmp to minimize registers
		           tmp1=rsqrtf(tmp0);
		           tmp1=stheta*tmp1;
		           *((float4*)(&v))=float4(
				tmp1*(v.x*v.z*cphi - v.y*sphi) + v.x*ctheta,
				tmp1*(v.y*v.z*cphi + v.x*sphi) + v.y*ctheta,
				-tmp1*tmp0*cphi                + v.z*ctheta,
				v.nscat
			   );
                           GPUDEBUG(("new dir: %10.5e %10.5e %10.5e\n",v.x,v.y,v.z));
		       }else{
			   *((float4*)(&v))=float4(stheta*cphi,stheta*sphi,(v.z>0.f)?ctheta:-ctheta,v.nscat);
                           GPUDEBUG(("new dir-z: %10.5e %10.5e %10.5e\n",v.x,v.y,v.z));
 		       }
                       v.nscat++;
	       }
	  }

          n1=prop.n;
	  *((float4*)(&prop))=gproperty[mediaid];
	  len=gcfg->minstep*prop.mus; //Wang1995: gcfg->minstep*(prop.mua+prop.mus)

          p0=p;
	  if(len>f.tscat){  //scattering ends in this voxel: mus*gcfg->minstep > s 
               tmp0=f.tscat/prop.mus;
	       energyabsorbed+=p.w;
   	       *((float4*)(&p))=float4(p.x+v.x*tmp0,p.y+v.y*tmp0,p.z+v.z*tmp0,
                           p.w*expf(-prop.mua*tmp0));
	       energyabsorbed-=p.w;
	       f.tscat=SAME_VOXEL;
	       f.t+=tmp0*prop.n*R_C0;  // accumulative time
               GPUDEBUG((">>ends in voxel %f<%f %f [%d]\n",f.tscat,len,prop.mus,idx1d));
	  }else{                      //otherwise, move gcfg->minstep
	       energyabsorbed+=p.w;
               if(mediaid!=medid){
                  atten=expf(-prop.mua*gcfg->minstep);
               }
   	       *((float4*)(&p))=float4(p.x+v.x,p.y+v.y,p.z+v.z,p.w*atten);
               medid=mediaid;
	       energyabsorbed-=p.w;
	       f.tscat-=len;     //remaining probability: sum(s_i*mus_i)
	       f.t+=gcfg->minaccumtime*prop.n; //total time
               GPUDEBUG((">>keep going %f<%f %f [%d] %e %e\n",f.tscat,len,prop.mus,idx1d,f.t,f.tnext));
	  }

          idx1dold=idx1d;
          idx1d=gcfg->isrowmajor?int(floorf(p.x)*gcfg->dimlen.y+floorf(p.y)*gcfg->dimlen.x+floorf(p.z)):\
                           int(floorf(p.z)*gcfg->dimlen.y+floorf(p.y)*gcfg->dimlen.x+floorf(p.x));
          GPUDEBUG(("old and new voxel: %d<->%d\n",idx1dold,idx1d));
          if(p.x<0||p.y<0||p.z<0||p.x>=gcfg->maxidx.x||p.y>=gcfg->maxidx.y||p.z>=gcfg->maxidx.z){
	      mediaid=0;
	  }else{
              mediaid=media[idx1d];
          }

          //if hit the boundary, exceed the max time window or exit the domain, rebound or launch a new one
	  if(mediaid==0||f.t>gcfg->tmax||f.t>gcfg->twin1){
              flipdir=0.f;
              if(gcfg->doreflect) {
                //time-of-flight to hit the wall in each direction
                htime.x=(v.x>EPS||v.x<-EPS)?(floorf(p0.x)+(v.x>0.f)-p0.x)/v.x:VERY_BIG;
                htime.y=(v.y>EPS||v.y<-EPS)?(floorf(p0.y)+(v.y>0.f)-p0.y)/v.y:VERY_BIG;
                htime.z=(v.z>EPS||v.z<-EPS)?(floorf(p0.z)+(v.z>0.f)-p0.z)/v.z:VERY_BIG;
                //get the direction with the smallest time-of-flight
                tmp0=fminf(fminf(htime.x,htime.y),htime.z);
                flipdir=(tmp0==htime.x?1.f:(tmp0==htime.y?2.f:(tmp0==htime.z&&idx1d!=idx1dold)?3.f:0.f));

                //move to the 1st intersection pt
                tmp0*=JUST_ABOVE_ONE;
                htime.x=floorf(p0.x+tmp0*v.x);
       	        htime.y=floorf(p0.y+tmp0*v.y);
       	        htime.z=floorf(p0.z+tmp0*v.z);

                if(htime.x>=0&&htime.y>=0&&htime.z>=0&&htime.x<gcfg->maxidx.x&&htime.y<gcfg->maxidx.y&&htime.z<gcfg->maxidx.z){
                    if( media[gcfg->isrowmajor?int(htime.x*gcfg->dimlen.y+htime.y*gcfg->dimlen.x+htime.z):\
                           int(htime.z*gcfg->dimlen.y+htime.y*gcfg->dimlen.x+htime.x)]){ //hit again

                     GPUDEBUG((" first try failed: [%.1f %.1f,%.1f] %d (%.1f %.1f %.1f)\n",htime.x,htime.y,htime.z,
                           media[gcfg->isrowmajor?int(htime.x*gcfg->dimlen.y+htime.y*gcfg->dimlen.x+htime.z):\
                           int(htime.z*gcfg->dimlen.y+htime.y*gcfg->dimlen.x+htime.x)], gcfg->maxidx.x, gcfg->maxidx.y,gcfg->maxidx.z));

                     htime.x=(v.x>EPS||v.x<-EPS)?(floorf(p.x)+(v.x<0.f)-p.x)/(-v.x):VERY_BIG;
                     htime.y=(v.y>EPS||v.y<-EPS)?(floorf(p.y)+(v.y<0.f)-p.y)/(-v.y):VERY_BIG;
                     htime.z=(v.z>EPS||v.z<-EPS)?(floorf(p.z)+(v.z<0.f)-p.z)/(-v.z):VERY_BIG;
                     tmp0=fminf(fminf(htime.x,htime.y),htime.z);
                     tmp1=flipdir;   //save the previous ref. interface id
                     flipdir=(tmp0==htime.x?1.f:(tmp0==htime.y?2.f:(tmp0==htime.z&&idx1d!=idx1dold)?3.f:0.f));

                     if(gcfg->doreflect3){
                       tmp0*=JUST_ABOVE_ONE;
                       htime.x=floorf(p.x-tmp0*v.x); //move to the last intersection pt
                       htime.y=floorf(p.y-tmp0*v.y);
                       htime.z=floorf(p.z-tmp0*v.z);

                       if(tmp1!=flipdir&&htime.x>=0&&htime.y>=0&&htime.z>=0&&htime.x<gcfg->maxidx.x&&htime.y<gcfg->maxidx.y&&htime.z<gcfg->maxidx.z){
                           if(! media[gcfg->isrowmajor?int(htime.x*gcfg->dimlen.y+htime.y*gcfg->dimlen.x+htime.z):\
                                  int(htime.z*gcfg->dimlen.y+htime.y*gcfg->dimlen.x+htime.x)]){ //this is an air voxel

                               GPUDEBUG((" second try failed: [%.1f %.1f,%.1f] %d (%.1f %.1f %.1f)\n",htime.x,htime.y,htime.z,
                                   media[gcfg->isrowmajor?int(htime.x*gcfg->dimlen.y+htime.y*gcfg->dimlen.x+htime.z):\
                                   int(htime.z*gcfg->dimlen.y+htime.y*gcfg->dimlen.x+htime.x)], gcfg->maxidx.x, gcfg->maxidx.y,gcfg->maxidx.z));

                               /*to compute the remaining interface, we used the following fact to accelerate: 
                                 if there exist 3 intersections, photon must pass x/y/z interface exactly once,
                                 we solve the coeff of the following equation to find the last interface:
                                    a*1+b*2+c=3
       	       	       	       	    a*1+b*3+c=2 -> [a b c]=[-1 -1 6], this will give the remaining interface id
       	       	       	       	    a*2+b*3+c=1
                               */
                               flipdir=-tmp1-flipdir+6.f;
                           }
                       }
                     }
                  }
                }
              }

              *((float4*)(&prop))=gproperty[mediaid];

              GPUDEBUG(("->ID%d J%d C%d tlen %e flip %d %.1f!=%.1f dir=%f %f %f pos=%f %f %f\n",idx,(int)v.nscat,
                  (int)f.ndone,f.t, (int)flipdir, n1,prop.n,v.x,v.y,v.z,p.x,p.y,p.z));

              //recycled some old register variables to save memory
	      //if hit boundary within the time window and is n-mismatched, rebound

              if(gcfg->doreflect&&f.t<gcfg->tmax&&f.t<gcfg->twin1&& flipdir>0.f && n1!=prop.n&&p.w>gcfg->minenergy){
                  tmp0=n1*n1;
                  tmp1=prop.n*prop.n;
                  if(flipdir>=3.f) { //flip in z axis
                     cphi=fabs(v.z);
                     sphi=v.x*v.x+v.y*v.y;
                     v.z=-v.z;
                  }else if(flipdir>=2.f){ //flip in y axis
                     cphi=fabs(v.y);
       	       	     sphi=v.x*v.x+v.z*v.z;
                     v.y=-v.y;
                  }else if(flipdir>=1.f){ //flip in x axis
                     cphi=fabs(v.x);                //cos(si)
                     sphi=v.y*v.y+v.z*v.z; //sin(si)^2
                     v.x=-v.x;
                  }
		  energyabsorbed+=p.w-p0.w;
                  p=p0;   //move back
                  idx1d=idx1dold;
                  len=1.f-tmp0/tmp1*sphi;   //1-[n1/n2*sin(si)]^2
	          GPUDEBUG((" ref len=%f %f+%f=%f w=%f\n",len,cphi,sphi,cphi*cphi+sphi,p.w));

                  if(len>0.f) {
                     ctheta=tmp0*cphi*cphi+tmp1*len;
                     stheta=2.f*n1*prop.n*cphi*sqrtf(len);
                     Rtotal=(ctheta-stheta)/(ctheta+stheta);
       	       	     ctheta=tmp1*cphi*cphi+tmp0*len;
       	       	     Rtotal=(Rtotal+(ctheta-stheta)/(ctheta+stheta))*0.5f;
	             GPUDEBUG(("  dir=%f %f %f htime=%f %f %f Rs=%f\n",v.x,v.y,v.z,htime.x,htime.y,htime.z,Rtotal));
	             GPUDEBUG(("  ID%d J%d C%d flip=%3f (%d %d) cphi=%f sphi=%f p=%f %f %f p0=%f %f %f\n",
                         idx,(int)v.nscat,(int)f.tnext,
	                 flipdir,idx1dold,idx1d,cphi,sphi,p.x,p.y,p.z,p0.x,p0.y,p0.z));
		     energyloss+=(1.f-Rtotal)*p.w; //energy loss due to reflection
                     p.w*=Rtotal;
                  } // else, total internal reflection, no loss
                  mediaid=media[idx1d];
                  *((float4*)(&prop))=gproperty[mediaid];
                  n1=prop.n;
                  //v.nscat++;
              }else{  // launch a new photon
                  energyloss+=p.w;  // sum all the remaining energy
	          *((float4*)(&p))=gcfg->ps;
	          *((float4*)(&v))=gcfg->c0;
	          *((float4*)(&f))=float4(0.f,0.f,gcfg->minaccumtime,f.ndone+1);
                  idx1d=idxorig;
		  mediaid=mediaidorig;
              }
	  }else if(f.t>=f.tnext){
             GPUDEBUG(("field add to %d->%f(%d)  t(%e)>t0(%e)\n",idx1d,p.w,(int)f.ndone,f.t,f.tnext));
             // if t is within the time window, which spans cfg->maxgate*cfg->tstep wide
             if(gcfg->save2pt && f.t>=gcfg->twin0 && f.t<gcfg->twin1){
#ifdef TEST_RACING
                  // enable TEST_RACING to determine how many missing accumulations due to race
                  if( (p.x-gcfg->ps.x)*(p.x-gcfg->ps.x)+(p.y-gcfg->ps.y)*(p.y-gcfg->ps.y)+(p.z-gcfg->ps.z)*(p.z-gcfg->ps.z)>gcfg->skipradius2) {
                      field[idx1d+(int)(floorf((f.t-gcfg->twin0)*gcfg->Rtstep))*gcfg->dimlen.z]+=1.f;
		      cc++;
                  }
#else
  #ifndef USE_ATOMIC
                  // set gcfg->skipradius2 to only start depositing energy when dist^2>gcfg->skipradius2 
                  if(gcfg->skipradius2>EPS){
                      if((p.x-gcfg->ps.x)*(p.x-gcfg->ps.x)+(p.y-gcfg->ps.y)*(p.y-gcfg->ps.y)+(p.z-gcfg->ps.z)*(p.z-gcfg->ps.z)>gcfg->skipradius2){
                          field[idx1d+(int)(floorf((f.t-gcfg->twin0)*gcfg->Rtstep))*gcfg->dimlen.z]+=p.w;
                      }else{
                          accumweight+=p.w*prop.mua; // weight*absorption
                      }
                  }else{
                      field[idx1d+(int)(floorf((f.t-gcfg->twin0)*gcfg->Rtstep))*gcfg->dimlen.z]+=p.w;
                  }
  #else
                  // ifndef CUDA_NO_SM_11_ATOMIC_INTRINSICS
		  atomicFloatAdd(& field[idx1d+(int)(floorf((f.t-gcfg->twin0)*gcfg->Rtstep))*gcfg->dimlen.z], p.w);
  #endif
#endif
	     }
             f.tnext+=gcfg->minaccumtime; // fluence is a temporal-integration
	  }
     }
     // accumweight saves the total absorbed energy in the sphere r<sradius.
     // in non-atomic mode, accumweight is more accurate than saving to the grid
     // as it is not influenced by race conditions.
     // now I borrow f.tnext to pass this value back

     f.tnext=accumweight;

     genergy[idx<<1]=energyloss;
     genergy[(idx<<1)+1]=energyabsorbed;

#ifdef TEST_RACING
     n_seed[idx]=cc;
#endif
     n_pos[idx]=*((float4*)(&p));
     n_dir[idx]=*((float4*)(&v));
     n_len[idx]=*((float4*)(&f));
}

kernel void mcx_sum_trueabsorption(float energy[],uchar media[], float field[], int maxgate,uint3 dimlen){
     int i;
     float phi=0.f;
     int idx= blockIdx.x*dimlen.y+blockIdx.y*dimlen.x+ threadIdx.x;

     for(i=0;i<maxgate;i++){
        phi+=field[i*dimlen.z+idx];
     }
     energy[2]+=phi*gproperty[media[idx]].x;
}


/*
   assert cuda memory allocation result
*/
void mcx_cu_assess(cudaError_t cuerr,const char *file, const int linenum){
     if(cuerr!=cudaSuccess){
         mcx_error(-(int)cuerr,(char *)cudaGetErrorString(cuerr),file,linenum);
     }
}


/*
  query GPU info and set active GPU
*/
int mcx_set_gpu(Config *cfg){

#if __DEVICE_EMULATION__
    return 1;
#else
    int dev;
    int deviceCount;
    cudaGetDeviceCount(&deviceCount);
    if (deviceCount == 0){
        printf("No CUDA-capable GPU device found\n");
        return 0;
    }
    if (cfg->gpuid && cfg->gpuid > deviceCount){
        printf("Specified GPU ID is out of range\n");
        return 0;
    }
    // scan from the last device, hopefully it is more dedicated
    for (dev = 0; dev<deviceCount; dev++) {
        cudaDeviceProp dp;
        cudaGetDeviceProperties(&dp, dev);
        if (strncmp(dp.name, "Device Emulation", 16)) {
	  if(cfg->isgpuinfo){
	    printf("=============================   GPU Infomation  ================================\n");
	    printf("Device %d of %d:\t\t%s\n",dev+1,deviceCount,dp.name);
	    printf("Global Memory:\t\t%u B\nConstant Memory:\t%u B\n\
Shared Memory:\t\t%u B\nRegisters:\t\t%u\nClock Speed:\t\t%.2f GHz\n",
               (unsigned int)dp.totalGlobalMem,(unsigned int)dp.totalConstMem,
               (unsigned int)dp.sharedMemPerBlock,(unsigned int)dp.regsPerBlock,dp.clockRate*1e-6f);
	  #if CUDART_VERSION >= 2000
	       printf("Number of MPs:\t\t%u\nNumber of Cores:\t%u\n",
	          dp.multiProcessorCount,dp.multiProcessorCount<<3);
	  #endif
	  }
          if(cfg->isgpuinfo!=2) break;
	}
    }
    if(cfg->isgpuinfo==2){ //list GPU info only
          exit(0);
    }
    if (cfg->gpuid==0)
        mcx_cu_assess(cudaSetDevice(deviceCount-1),__FILE__,__LINE__);
    else
        mcx_cu_assess(cudaSetDevice(cfg->gpuid-1),__FILE__,__LINE__);

    return 1;
#endif
}


/*
   master driver code to run MC simulations
*/
void mcx_run_simulation(Config *cfg){

     int i,j,iter;
     float  minstep=MIN(MIN(cfg->steps.x,cfg->steps.y),cfg->steps.z);
     float4 p0=float4(cfg->srcpos.x,cfg->srcpos.y,cfg->srcpos.z,1.f);
     float4 c0=float4(cfg->srcdir.x,cfg->srcdir.y,cfg->srcdir.z,0.f);
     float3 maxidx=float3(cfg->dim.x,cfg->dim.y,cfg->dim.z);
     float t;
     float energyloss=0.f,energyabsorbed=0.f;
     float *energy;
     int threadphoton, oddphotons;

     int photoncount=0,printnum;
     int tic,fieldlen;
     uint3 cp0=cfg->crop0,cp1=cfg->crop1;
     uint2 cachebox;
     uint3 dimlen;
     //uint3 threaddim;
     float Vvox,scale,absorp,eabsorp;

     dim3 mcgrid, mcblock;
     dim3 clgrid, clblock;
     
     int dimxyz=cfg->dim.x*cfg->dim.y*cfg->dim.z;
     
     uchar  *media=(uchar *)(cfg->vol);
     float  *field;
     MCXParam param={cfg->steps,minstep,0,0,cfg->tend,cfg->isrowmajor,
                     cfg->issave2pt,cfg->isreflect,cfg->isref3,1.f/cfg->tstep,
		     p0,c0,maxidx,uint3(0,0,0),cp0,cp1,uint2(0,0),cfg->minenergy,
                     cfg->sradius*cfg->sradius,minstep*R_C0};

     if(cfg->respin>1){
         field=(float *)calloc(sizeof(float)*dimxyz,cfg->maxgate*2);
     }else{
         field=(float *)calloc(sizeof(float)*dimxyz,cfg->maxgate); //the second half will be used to accumulate
     }
     threadphoton=cfg->nphoton/cfg->nthread/cfg->respin;
     oddphotons=cfg->nphoton-threadphoton*cfg->nthread*cfg->respin;

     float4 *Ppos;
     float4 *Pdir;
     float4 *Plen;
     uint   *Pseed;

     if(cfg->nthread%cfg->nblocksize)
     	cfg->nthread=(cfg->nthread/cfg->nblocksize)*cfg->nblocksize;
     mcgrid.x=cfg->nthread/cfg->nblocksize;
     mcblock.x=cfg->nblocksize;

     clgrid.x=cfg->dim.x;
     clgrid.y=cfg->dim.y;
     clblock.x=cfg->dim.z;
	
     Ppos=(float4*)malloc(sizeof(float4)*cfg->nthread);
     Pdir=(float4*)malloc(sizeof(float4)*cfg->nthread);
     Plen=(float4*)malloc(sizeof(float4)*cfg->nthread);
     Pseed=(uint*)malloc(sizeof(uint)*cfg->nthread*RAND_SEED_LEN);
     energy=(float*)calloc(sizeof(float),cfg->nthread*2);

     uchar *gmedia;
     mcx_cu_assess(cudaMalloc((void **) &gmedia, sizeof(uchar)*(dimxyz)),__FILE__,__LINE__);
     float *gfield;
     mcx_cu_assess(cudaMalloc((void **) &gfield, sizeof(float)*(dimxyz)*cfg->maxgate),__FILE__,__LINE__);

     //cudaBindTexture(0, texmedia, gmedia);

     float4 *gPpos;
     mcx_cu_assess(cudaMalloc((void **) &gPpos, sizeof(float4)*cfg->nthread),__FILE__,__LINE__);
     float4 *gPdir;
     mcx_cu_assess(cudaMalloc((void **) &gPdir, sizeof(float4)*cfg->nthread),__FILE__,__LINE__);
     float4 *gPlen;
     mcx_cu_assess(cudaMalloc((void **) &gPlen, sizeof(float4)*cfg->nthread),__FILE__,__LINE__);
     uint   *gPseed;
     mcx_cu_assess(cudaMalloc((void **) &gPseed, sizeof(uint)*cfg->nthread*RAND_SEED_LEN),__FILE__,__LINE__);

     float *genergy;
     cudaMalloc((void **) &genergy, sizeof(float)*cfg->nthread*2);
     
     if(cfg->isrowmajor){ // if the volume is stored in C array order
	     cachebox.x=(cp1.z-cp0.z+1);
	     cachebox.y=(cp1.y-cp0.y+1)*(cp1.z-cp0.z+1);
	     dimlen.x=cfg->dim.z;
	     dimlen.y=cfg->dim.y*cfg->dim.z;
     }else{               // if the volume is stored in matlab/fortran array order
	     cachebox.x=(cp1.x-cp0.x+1);
	     cachebox.y=(cp1.y-cp0.y+1)*(cp1.x-cp0.x+1);
	     dimlen.x=cfg->dim.x;
	     dimlen.y=cfg->dim.y*cfg->dim.x;
     }
     dimlen.z=cfg->dim.x*cfg->dim.y*cfg->dim.z;
     param.dimlen=dimlen;
     param.cachebox=cachebox;
     /*
      threaddim.x=cfg->dim.z;
      threaddim.y=cfg->dim.y*cfg->dim.z;
      threaddim.z=dimlen.z;
     */
     Vvox=cfg->steps.x*cfg->steps.y*cfg->steps.z;

     if(cfg->seed>0)
     	srand(cfg->seed);
     else
        srand(time(0));
	
     for (i=0; i<cfg->nthread; i++) {
	   Ppos[i]=p0;  // initial position
           Pdir[i]=c0;
           Plen[i]=float4(0.f,0.f,minstep*R_C0,0.f);
     }
     for (i=0; i<cfg->nthread*RAND_SEED_LEN; i++) {
	   Pseed[i]=rand();
     }    
     
     fprintf(cfg->flog,"\
###############################################################################\n\
#                  Monte Carlo Extreme (MCX) -- CUDA                          #\n\
###############################################################################\n\
$MCX $Rev::     $ Last Commit:$Date::                     $ by $Author:: fangq$\n\
###############################################################################\n");

     tic=StartTimer();
     fprintf(cfg->flog,"compiled with: [RNG] %s [Seed Length] %d\n",MCX_RNG_NAME,RAND_SEED_LEN);
     fprintf(cfg->flog,"threadph=%d oddphotons=%d np=%d nthread=%d repetition=%d\n",threadphoton,oddphotons,
           cfg->nphoton,cfg->nthread,cfg->respin);
     fprintf(cfg->flog,"initializing streams ...\t");
     fflush(cfg->flog);
     fieldlen=dimxyz*cfg->maxgate;

     cudaMemcpy(gPpos,  Ppos,  sizeof(float4)*cfg->nthread,  cudaMemcpyHostToDevice);
     cudaMemcpy(gPdir,  Pdir,  sizeof(float4)*cfg->nthread,  cudaMemcpyHostToDevice);
     cudaMemcpy(gPlen,  Plen,  sizeof(float4)*cfg->nthread,  cudaMemcpyHostToDevice);
     cudaMemcpy(gPseed, Pseed, sizeof(uint)  *cfg->nthread*RAND_SEED_LEN,  cudaMemcpyHostToDevice);
     cudaMemcpy(gfield, field, sizeof(float) *fieldlen, cudaMemcpyHostToDevice);
     cudaMemcpy(gmedia, media, sizeof(uchar) *dimxyz, cudaMemcpyHostToDevice);
     cudaMemcpy(genergy,energy,sizeof(float) *cfg->nthread*2, cudaMemcpyHostToDevice);

     cudaMemcpyToSymbol(gproperty, cfg->prop,  cfg->medianum*sizeof(Medium), 0, cudaMemcpyHostToDevice);

     fprintf(cfg->flog,"init complete : %d ms\n",GetTimeMillis()-tic);

     /*
         if one has to simulate a lot of time gates, using the GPU global memory
	 requires extra caution. If the total global memory is bigger than the total
	 memory to save all the snapshots, i.e. size(field)*(tend-tstart)/tstep, one
	 simply sets cfg->maxgate to the total gate number; this will run GPU kernel
	 once. If the required memory is bigger than the video memory, set cfg->maxgate
	 to a number which fits, and the snapshot will be saved with an increment of 
	 cfg->maxgate snapshots. In this case, the later simulations will restart from
	 photon launching and exhibit redundancies.
	 
	 The calculation of the energy conservation will only reflect the last simulation.
     */
     
     //simulate for all time-gates in maxgate groups per run
     for(t=cfg->tstart;t<cfg->tend;t+=cfg->tstep*cfg->maxgate){

       param.twin0=t;
       param.twin1=t+cfg->tstep*cfg->maxgate;
       cudaMemcpyToSymbol(gcfg,   &param,     sizeof(MCXParam), 0, cudaMemcpyHostToDevice);

       fprintf(cfg->flog,"lauching mcx_main_loop for time window [%.1fns %.1fns] ...\n"
           ,param.twin0*1e9,param.twin1*1e9);

       //total number of repetition for the simulations, results will be accumulated to field
       for(iter=0;iter<cfg->respin;iter++){

           fprintf(cfg->flog,"simulation run#%2d ... \t",iter+1); fflush(cfg->flog);
           mcx_main_loop<<<mcgrid,mcblock>>>(cfg->nphoton,0,gmedia,gfield,genergy,gPseed,gPpos,gPdir,gPlen);

           cudaThreadSynchronize();
           cudaMemcpy(field, gfield,sizeof(float),cudaMemcpyDeviceToHost);
           fprintf(cfg->flog,"kernel complete:  \t%d ms\nretrieving fields ... \t",GetTimeMillis()-tic);
           mcx_cu_assess(cudaGetLastError(),__FILE__,__LINE__);

	   //handling the 2pt distributions
           if(cfg->issave2pt){
               cudaMemcpy(field, gfield,sizeof(float) *dimxyz*cfg->maxgate,cudaMemcpyDeviceToHost);
               fprintf(cfg->flog,"transfer complete:\t%d ms\n",GetTimeMillis()-tic);  fflush(cfg->flog);

               if(cfg->respin>1){
                   for(i=0;i<fieldlen;i++)  //accumulate field, can be done in the GPU
                      field[fieldlen+i]+=field[i];
               }
               if(iter+1==cfg->respin){ 
                   if(cfg->respin>1)  //copy the accumulated fields back
                       memcpy(field,field+fieldlen,sizeof(float)*fieldlen);

                   if(cfg->isnormalized){
                       //normalize field if it is the last iteration, temporarily do it in CPU
                       //mcx_sum_trueabsorption<<<clgrid,clblock>>>(genergy,gmedia,gfield,
                       //  	cfg->maxgate,threaddim);

                       fprintf(cfg->flog,"normizing raw data ...\t");

                       cudaMemcpy(energy,genergy,sizeof(float)*cfg->nthread*2,cudaMemcpyDeviceToHost);
		       cudaMemcpy(Plen,  gPlen,  sizeof(float4)*cfg->nthread, cudaMemcpyDeviceToHost);
                       eabsorp=0.f;
                       for(i=1;i<cfg->nthread;i++){
                           energy[0]+=energy[i<<1];
       	       	       	   energy[1]+=energy[(i<<1)+1];
                           eabsorp+=Plen[i].z;  // the accumulative absorpted energy near the source
                       }
       	       	       for(i=0;i<dimxyz;i++){
                           absorp=0.f;
                           for(j=0;j<cfg->maxgate;j++)
                              absorp+=field[j*dimxyz+i];
                           eabsorp+=absorp*cfg->prop[media[i]].mua;
       	       	       }
                       scale=energy[1]/((energy[0]+energy[1])*Vvox*cfg->tstep*eabsorp);
                       fprintf(cfg->flog,"normalization factor alpha=%f\n",scale);  fflush(cfg->flog);
                       mcx_normalize(field,scale,fieldlen);
                   }
                   fprintf(cfg->flog,"data normalization complete : %d ms\n",GetTimeMillis()-tic);

                   fprintf(cfg->flog,"saving data to file ...\t");
                   mcx_savedata(field,fieldlen,t>cfg->tstart,cfg);
                   fprintf(cfg->flog,"saving data complete : %d ms\n",GetTimeMillis()-tic);
                   fflush(cfg->flog);
               }
           }
	   //initialize the next simulation
	   if(param.twin1<cfg->tend && iter<cfg->respin){
                  cudaMemset(gfield,0,sizeof(float)*fieldlen); // cost about 1 ms

 		  cudaMemcpy(gPpos,  Ppos,  sizeof(float4)*cfg->nthread,  cudaMemcpyHostToDevice); //following 3 cost about 50 ms
		  cudaMemcpy(gPdir,  Pdir,  sizeof(float4)*cfg->nthread,  cudaMemcpyHostToDevice);
		  cudaMemcpy(gPlen,  Plen,  sizeof(float4)*cfg->nthread,  cudaMemcpyHostToDevice);
	   }
	   if(cfg->respin>1 && RAND_SEED_LEN>1){
               for (i=0; i<cfg->nthread*RAND_SEED_LEN; i++)
		   Pseed[i]=rand();
	       cudaMemcpy(gPseed, Pseed, sizeof(uint)*cfg->nthread*RAND_SEED_LEN,  cudaMemcpyHostToDevice);
	   }
       }
       if(param.twin1<cfg->tend){
            cudaMemset(genergy,0,sizeof(float)*cfg->nthread*2);
       }
     }

     cudaMemcpy(Ppos,  gPpos, sizeof(float4)*cfg->nthread, cudaMemcpyDeviceToHost);
     cudaMemcpy(Pdir,  gPdir, sizeof(float4)*cfg->nthread, cudaMemcpyDeviceToHost);
     cudaMemcpy(Plen,  gPlen, sizeof(float4)*cfg->nthread, cudaMemcpyDeviceToHost);
     cudaMemcpy(Pseed, gPseed,sizeof(uint)  *cfg->nthread*RAND_SEED_LEN,   cudaMemcpyDeviceToHost);
     cudaMemcpy(energy,genergy,sizeof(float)*cfg->nthread*2,cudaMemcpyDeviceToHost);

     for (i=0; i<cfg->nthread; i++) {
	  photoncount+=(int)Plen[i].w;
          energyloss+=energy[i<<1];
          energyabsorbed+=energy[(i<<1)+1];
     }

#ifdef TEST_RACING
     {
       float totalcount=0.f,hitcount=0.f;
       for (i=0; i<fieldlen; i++)
          hitcount+=field[i];
       for (i=0; i<cfg->nthread; i++)
	  totalcount+=Pseed[i];
     
       fprintf(cfg->flog,"expected total recording number: %f, got %f, missed %f\n",
          totalcount,hitcount,(totalcount-hitcount)/totalcount);
     }
#endif

     printnum=cfg->nthread<cfg->printnum?cfg->nthread:cfg->printnum;
     for (i=0; i<printnum; i++) {
           fprintf(cfg->flog,"% 4d[A% f % f % f]C%3d J%5d W% 8f(P%6.3f %6.3f %6.3f)T% 5.3e L% 5.3f %.0f\n", i,
            Pdir[i].x,Pdir[i].y,Pdir[i].z,(int)Plen[i].w,(int)Pdir[i].w,Ppos[i].w, 
            Ppos[i].x,Ppos[i].y,Ppos[i].z,Plen[i].y,Plen[i].x,(float)Pseed[i]);
     }
     // total energy here equals total simulated photons+unfinished photons for all threads
     fprintf(cfg->flog,"simulated %d photons (%d) with %d threads (repeat x%d)\n",
             photoncount,cfg->nphoton,cfg->nthread,cfg->respin); fflush(cfg->flog);
     fprintf(cfg->flog,"exit energy:%16.8e + absorbed energy:%16.8e = total: %16.8e\n",
             energyloss,energyabsorbed,energyloss+energyabsorbed);fflush(cfg->flog);
     fflush(cfg->flog);

     cudaFree(gmedia);
     cudaFree(gfield);
     cudaFree(gPpos);
     cudaFree(gPdir);
     cudaFree(gPlen);
     cudaFree(gPseed);
     cudaFree(genergy);

     free(Ppos);
     free(Pdir);
     free(Plen);
     free(Pseed);
     free(energy);
     free(field);
}
