#include "stepper.h"

#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <assert.h>
#include <stdbool.h>

#include <stdio.h>

#ifndef THREADS_PER_BLOCK
	#define THREADS_PER_BLOCK 512
#endif


//ldoc on
/**
 * ## Implementation
 *
 * ### Structure allocation
 */

central2d_t* central2d_init(float w, float h, int nx, int ny,
                            int nfield, flux_t flux, speed_t speed,
                            float cfl)
{
    // We extend to a four cell buffer to avoid BC comm on odd time steps
    int ng = 4;

    central2d_t* sim = (central2d_t*) malloc(sizeof(central2d_t));
    sim->nx = nx;
    sim->ny = ny;
    sim->ng = ng;
    sim->nfield = nfield;
    sim->dx = w/nx;
    sim->dy = h/ny;
    sim->flux = flux;
    sim->speed = speed;
    sim->cfl = cfl;

    int nx_all = nx + 2*ng;
    int ny_all = ny + 2*ng;
    int nc = nx_all * ny_all;
    int N  = nfield * nc;
    sim->u  = (float*) malloc((4*N + 6*nx_all)* sizeof(float));
    sim->v  = sim->u +   N;
    sim->f  = sim->u + 2*N;
    sim->g  = sim->u + 3*N;
    sim->scratch = sim->u + 4*N;
	/*
	cudaMallocManaged(&(sim->u), N * sizeof(float));//(4*N + 6*nx_all)* sizeof(float));
	cudaMallocManaged(&(sim->v), N * sizeof(float));
	cudaMallocManaged(&(sim->f), N * sizeof(float));
	cudaMallocManaged(&(sim->g), N * sizeof(float));
	cudaMallocManaged(&(sim->scratch), N * sizeof(float));
*/
	
	sim->dev_u = (float*) malloc((4*N + 6*nx_all)* sizeof(float));//(float*) malloc(N*sizeof(float));//(float*) malloc((4*N + 6*nx_all)* sizeof(float));
	sim->dev_v = sim->dev_u + N;
	sim->dev_f = sim->dev_u + 2*N;
	sim->dev_g = sim->dev_u + 3*N;
	sim->scratch = sim->dev_u +4*N;
	
	cudaMalloc( (void**)&sim->dev_u, N*sizeof(float));
	cudaMalloc( (void**)&sim->dev_v, N*sizeof(float));
	cudaMalloc( (void**)&sim->dev_scratch, N*sizeof(float));
	cudaMalloc( (void**)&sim->dev_f, N*sizeof(float));
	cudaMalloc( (void**)&sim->dev_g, N*sizeof(float));	
	cudaDeviceSynchronize();

    return sim;
}


void central2d_free(central2d_t* sim)
{
    free(sim->u);
    cudaFree(sim->dev_u);
    cudaFree(sim->dev_v);
    cudaFree(sim->dev_f);
    cudaFree(sim->dev_g);
    cudaFree(sim->dev_scratch);
    free(sim);
}

//__global__
int central2d_offset(central2d_t* sim, int k, int ix, int iy)
{
	//printf("b1");	
    int nx = sim->nx, ny = sim->ny, ng = sim->ng;
	//printf("b2");      
   int nx_all = nx + 2*ng;
	//printf("b3");     
    int ny_all = ny + 2*ng;
	//printf("b4");
	int result = (k*ny_all+(ng+iy))*nx_all+(ng+ix);
	//printf("b5");     
    return result;
}


/**
 * ### Boundary conditions
 *
 * In finite volume methods, boundary conditions are typically applied by
 * setting appropriate values in ghost cells.  For our framework, we will
 * apply periodic boundary conditions; that is, waves that exit one side
 * of the domain will enter from the other side.
 *
 * We apply the conditions by assuming that the cells with coordinates
 * `nghost <= ix <= nx+nghost` and `nghost <= iy <= ny+nghost` are
 * "canonical", and setting the values for all other cells `(ix,iy)`
 * to the corresponding canonical values `(ix+p*nx,iy+q*ny)` for some
 * integers `p` and `q`.
 */
__device__
 static inline
void copy_subgrid(float* __restrict__ dst,
                  const float* __restrict__ src,
                  int nx, int ny, int stride)
{
	//int index = blockIdx.x * blockDim.x + threadIdx.x;
	//int blockStride = blockDim.x * gridDim.x;
    for (int iy = 0; iy < ny; iy += 1)
        for (int ix = 0; ix < nx; ++ix)
            dst[iy*stride+ix] = src[iy*stride+ix];
}

__global__
void central2d_periodic(float* __restrict__ u,
                        int nx, int ny, int ng, int nfield)
{
    // Stride and number per field
    int s = nx + 2*ng;
    int field_stride = (ny+2*ng)*s;

    // Offsets of left, right, top, and bottom data blocks and ghost blocks
    int l = nx,   lg = 0;
    int r = ng,   rg = nx+ng;
    int b = ny*s, bg = 0;
    int t = ng*s, tg = (nx+ng)*s;

    // Copy data into ghost cells on each side
    for (int k = 0; k < nfield; ++k) {
        float* uk = u + k*field_stride;
        copy_subgrid(uk+lg, uk+l, ng, ny+2*ng, s);
        copy_subgrid(uk+rg, uk+r, ng, ny+2*ng, s);
        copy_subgrid(uk+tg, uk+t, nx+2*ng, ng, s);
        copy_subgrid(uk+bg, uk+b, nx+2*ng, ng, s);
    }
}


/**
 * ### Derivatives with limiters
 *
 * In order to advance the time step, we also need to estimate
 * derivatives of the fluxes and the solution values at each cell.
 * In order to maintain stability, we apply a limiter here.
 *
 * The minmod limiter *looks* like it should be expensive to computer,
 * since superficially it seems to require a number of branches.
 * We do something a little tricky, getting rid of the condition
 * on the sign of the arguments using the `copysign` instruction.
 * If the compiler does the "right" thing with `max` and `min`
 * for floating point arguments (translating them to branch-free
 * intrinsic operations), this implementation should be relatively fast.
 */


// Branch-free computation of minmod of two numbers times 2s
__device__
static inline
float xmin2s(float s, float a, float b) {
    float sa = copysignf(s, a);
    float sb = copysignf(s, b);
    float abs_a = fabsf(a);
    float abs_b = fabsf(b);
    float min_abs = (abs_a < abs_b ? abs_a : abs_b);
    return (sa+sb) * min_abs;
}


// Limited combined slope estimate
__device__
 static inline
float limdiff(float um, float u0, float up) {
    const float theta = 2.0;
    const float quarter = 0.25;
    float du1 = u0-um;   // Difference to left
    float du2 = up-u0;   // Difference to right
    float duc = up-um;   // Twice centered difference
    return xmin2s( quarter, xmin2s(theta, du1, du2), duc );
}


// Compute limited derivs
__device__ 
static inline
void limited_deriv1(float* __restrict__ du,
                    const float* __restrict__ u,
                    int ncell)
{
    for (int i = 0; i < ncell; ++i)
        du[i] = limdiff(u[i-1], u[i], u[i+1]);
}


// Compute limited derivs across stride
__device__
 static inline
void limited_derivk(float* __restrict__ du,
                    const float* __restrict__ u,
                    int ncell, int stride)
{
    assert(stride > 0);
    for (int i = 0; i < ncell; ++i)
        du[i] = limdiff(u[i-stride], u[i], u[i+stride]);
}


/**
 * ### Advancing a time step
 *
 * Take one step of the numerical scheme.  This consists of two pieces:
 * a first-order corrector computed at a half time step, which is used
 * to obtain new $F$ and $G$ values; and a corrector step that computes
 * the solution at the full step.  For full details, we refer to the
 * [Jiang and Tadmor paper][jt].
 *
 * The `compute_step` function takes two arguments: the `io` flag
 * which is the time step modulo 2 (0 if even, 1 if odd); and the `dt`
 * flag, which actually determines the time step length.  We need
 * to know the even-vs-odd distinction because the Jiang-Tadmor
 * scheme alternates between a primary grid (on even steps) and a
 * staggered grid (on odd steps).  This means that the data at $(i,j)$
 * in an even step and the data at $(i,j)$ in an odd step represent
 * values at different locations in space, offset by half a space step
 * in each direction.  Every other step, we shift things back by one
 * mesh cell in each direction, essentially resetting to the primary
 * indexing scheme.
 *
 * We're slightly tricky in the corrector in that we write
 * $$
 *   v(i,j) = (s(i+1,j) + s(i,j)) - (d(i+1,j)-d(i,j))
 * $$
 * where $s(i,j)$ comprises the $u$ and $x$-derivative terms in the
 * update formula, and $d(i,j)$ the $y$-derivative terms.  This cuts
 * the arithmetic cost a little (not that it's that big to start).
 * It also makes it more obvious that we only need four rows worth
 * of scratch space.
 */


// Predictor half-step
__device__
static
void central2d_predict(float* __restrict__ v,
                       float* __restrict__ scratch,
                       const float* __restrict__ u,
                       const float* __restrict__ f,
                       const float* __restrict__ g,
                       float dtcdx2, float dtcdy2,
                       int nx, int ny, int nfield)
{
    float* __restrict__ fx = scratch;
    float* __restrict__ gy = scratch+nx;
    for (int k = 0; k < nfield; ++k) {
        for (int iy = 1; iy < ny-1; ++iy) {
            int offset = (k*ny+iy)*nx+1;
            limited_deriv1(fx+1, f+offset, nx-2);
            limited_derivk(gy+1, g+offset, nx-2, nx);
            for (int ix = 1; ix < nx-1; ++ix) {
                int offset = (k*ny+iy)*nx+ix;
                v[offset] = u[offset] - dtcdx2 * fx[ix] - dtcdy2 * gy[ix];
            }
        }
    }
}


// Corrector
__device__
static
void central2d_correct_sd(float* __restrict__ s,
                          float* __restrict__ d,
                          const float* __restrict__ ux,
                          const float* __restrict__ uy,
                          const float* __restrict__ u,
                          const float* __restrict__ f,
                          const float* __restrict__ g,
                          float dtcdx2, float dtcdy2,
                          int xlo, int xhi)
{
    for (int ix = xlo; ix < xhi; ++ix)
        s[ix] =
            0.2500f * (u [ix] + u [ix+1]) +
            0.0625f * (ux[ix] - ux[ix+1]) +
            dtcdx2  * (f [ix] - f [ix+1]);
    for (int ix = xlo; ix < xhi; ++ix)
        d[ix] =
            0.0625f * (uy[ix] + uy[ix+1]) +
            dtcdy2  * (g [ix] + g [ix+1]);
}


// Corrector
__device__
static
void central2d_correct(float* __restrict__ v,
                       float* __restrict__ scratch,
                       const float* __restrict__ u,
                       const float* __restrict__ f,
                       const float* __restrict__ g,
                       float dtcdx2, float dtcdy2,
                       int xlo, int xhi, int ylo, int yhi,
                       int nx, int ny, int nfield)
{
    assert(0 <= xlo && xlo < xhi && xhi <= nx);
    assert(0 <= ylo && ylo < yhi && yhi <= ny);

    float* __restrict__ ux = scratch;
    float* __restrict__ uy = scratch +   nx;
    float* __restrict__ s0 = scratch + 2*nx;
    float* __restrict__ d0 = scratch + 3*nx;
    float* __restrict__ s1 = scratch + 4*nx;
    float* __restrict__ d1 = scratch + 5*nx;

    for (int k = 0; k < nfield; ++k) {

        float*       __restrict__ vk = v + k*ny*nx;
        const float* __restrict__ uk = u + k*ny*nx;
        const float* __restrict__ fk = f + k*ny*nx;
        const float* __restrict__ gk = g + k*ny*nx;

        limited_deriv1(ux+1, uk+ylo*nx+1, nx-2);
        limited_derivk(uy+1, uk+ylo*nx+1, nx-2, nx);
        central2d_correct_sd(s1, d1, ux, uy,
                             uk + ylo*nx, fk + ylo*nx, gk + ylo*nx,
                             dtcdx2, dtcdy2, xlo, xhi);

        for (int iy = ylo; iy < yhi; ++iy) {

            float* tmp;
            tmp = s0; s0 = s1; s1 = tmp;
            tmp = d0; d0 = d1; d1 = tmp;

            limited_deriv1(ux+1, uk+(iy+1)*nx+1, nx-2);
            limited_derivk(uy+1, uk+(iy+1)*nx+1, nx-2, nx);
            central2d_correct_sd(s1, d1, ux, uy,
                                 uk + (iy+1)*nx, fk + (iy+1)*nx, gk + (iy+1)*nx,
                                 dtcdx2, dtcdy2, xlo, xhi);

            for (int ix = xlo; ix < xhi; ++ix)
                vk[iy*nx+ix] = (s1[ix]+s0[ix])-(d1[ix]-d0[ix]);
        }
    }
}

__global__
static
void central2d_step(float* __restrict__ u, float* __restrict__ v,
                    float* __restrict__ scratch,
                    float* __restrict__ f,
                    float* __restrict__ g,
                    int io, int nx, int ny, int ng,
                    int nfield, flux_t flux, speed_t speed,
                    float dt, float dx, float dy)
{
    int nx_all = nx + 2*ng;
    int ny_all = ny + 2*ng;

    float dtcdx2 = 0.5 * dt / dx;
    float dtcdy2 = 0.5 * dt / dy;

    flux(f, g, u, nx_all * ny_all, nx_all * ny_all);

    central2d_predict(v, scratch, u, f, g, dtcdx2, dtcdy2,
                      nx_all, ny_all, nfield);

    // Flux values of f and g at half step
    for (int iy = 1; iy < ny_all-1; ++iy) {
        int jj = iy*nx_all+1;
        flux(f+jj, g+jj, v+jj, nx_all-2, nx_all * ny_all);
    }

    central2d_correct(v+io*(nx_all+1), scratch, u, f, g, dtcdx2, dtcdy2,
                      ng-io, nx+ng-io,
                      ng-io, ny+ng-io,
                      nx_all, ny_all, nfield);
}


/**
 * ### Advance a fixed time
 *
 * The `run` method advances from time 0 (initial conditions) to time
 * `tfinal`.  Note that `run` can be called repeatedly; for example,
 * we might want to advance for a period of time, write out a picture,
 * advance more, and write another picture.  In this sense, `tfinal`
 * should be interpreted as an offset from the time represented by
 * the simulator at the start of the call, rather than as an absolute time.
 *
 * We always take an even number of steps so that the solution
 * at the end lives on the main grid instead of the staggered grid.
 */
static
int central2d_xrun(float* __restrict__ u, float* __restrict__ v,
                   float* __restrict__ scratch,
                   float* __restrict__ f,
                   float* __restrict__ g,
			float* __restrict__ dev_u,
			float* __restrict__ dev_v,
			float* __restrict__ dev_scratch,
			float* __restrict__ dev_f,
			float* __restrict__ dev_g,
                   int nx, int ny, int ng,
                   int nfield, flux_t flux, speed_t speed,
                   float tfinal, float dx, float dy, float cfl)
{
    int nstep = 0;
    int nx_all = nx + 2*ng;
    int ny_all = ny + 2*ng;
    bool done = false;
    float t = 0;


   
    int nc = nx_all * ny_all;
    int N  = nfield * nc;

	// move host memory to device
	// TODO correct fsize
	int fsize = N * sizeof(float);
	int bigsize = ((4*N + 6*nx_all)*sizeof(float));
	
	float cxy[2] = {1.0e-15f, 1.0e-15f};	
	float *dev_cxy;
	cudaMalloc( (void**)&dev_cxy, 2*sizeof(float));
	cudaMemcpy( dev_u, u, bigsize, cudaMemcpyHostToDevice);
	cudaMemcpy( dev_v, v, fsize, cudaMemcpyHostToDevice);
	cudaMemcpy( dev_scratch, scratch, fsize, cudaMemcpyHostToDevice);
	cudaMemcpy( dev_f, f, fsize, cudaMemcpyHostToDevice);
	cudaMemcpy( dev_g, g, fsize, cudaMemcpyHostToDevice);
	cudaDeviceSynchronize();
	

	printf(">Allocation complete \n");
    while (!done) {
        cxy[0] = 1.0e-15f;
	cxy[1] = 1.0e-15f;
        //float *dev_cxy;
	printf("z1\n");
	cudaMemcpy( (float*)dev_cxy, (float*)cxy, 2 * sizeof(float), cudaMemcpyHostToDevice);
	printf("z2\n");
	central2d_periodic<<<1,1>>>(dev_u, nx, ny, ng, nfield);
        printf("z3\n");
	cudaDeviceSynchronize();
	printf(">>Periodic done\n");
	speed<<<1,1>>>(dev_cxy, dev_u, nx_all * ny_all, nx_all * ny_all);
        printf(">>Speed done\n");
	cudaDeviceSynchronize();
        printf("f1\n");
	cudaMemcpy( (float*)cxy, (float*)dev_cxy, 2 * sizeof(float), cudaMemcpyDeviceToHost);
	printf("f2\n");
	cudaDeviceSynchronize();
	printf("f3\n");
	//cxy[0] = dev_cxy[0];
	//cxy[1] = dev_cxy[1];
	printf("cxy back\n");
	float dt = cfl / fmaxf(cxy[0]/dx, cxy[1]/dy);
        if (t + 2*dt >= tfinal) {
            dt = (tfinal-t)/2;
            done = true;
        }
	printf(">>Calcystuff done\n");
        central2d_step<<<1,1>>>(dev_u, dev_v, dev_scratch, dev_f, dev_g,
                       0, nx+4, ny+4, ng-2,
                       nfield, flux, speed,
                       dt, dx, dy);
	cudaDeviceSynchronize();
	printf(">>2d step 1 done\n");
        central2d_step<<<1,1>>>(dev_v, dev_u, dev_scratch, dev_f, dev_g,
                       1, nx, ny, ng,
                       nfield, flux, speed,
                       dt, dx, dy);
	cudaDeviceSynchronize();
	printf(">>2d step 2 done\n");
        t += 2*dt;
        nstep += 2;
    }
	
	printf(">Calculation round complete \n");

	cudaFree(cxy);
	//  move device memory back to host
	cudaMemcpy( u, dev_u, bigsize, cudaMemcpyDeviceToHost);
        cudaMemcpy( v, dev_v, fsize, cudaMemcpyDeviceToHost);
        cudaMemcpy( scratch, dev_scratch, fsize, cudaMemcpyDeviceToHost);
        cudaMemcpy( f, dev_f, fsize, cudaMemcpyDeviceToHost);
        cudaMemcpy( g, dev_g, fsize, cudaMemcpyDeviceToHost);
	cudaDeviceSynchronize();

	//u = dev_u;
	//v = dev_v;
	//scratch = dev_scratch;
	//f = dev_f;
	//g = dev_v;

	printf("Memory re-transferred \n");
	assert(1==0);
    return nstep;
}


int central2d_run(central2d_t* sim, float tfinal)
{
    return central2d_xrun(sim->u, sim->v, sim->scratch,
                          sim->f, sim->g,
			  sim->dev_u, sim->dev_v, sim->dev_scratch, sim->dev_f, sim->dev_g,
                          sim->nx, sim->ny, sim->ng,
                          sim->nfield, sim->flux, sim->speed,
                          tfinal, sim->dx, sim->dy, sim->cfl);
}
