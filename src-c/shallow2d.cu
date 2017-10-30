#include <string.h>
#include <math.h>

//ldoc on
/**
 * ## Implementation
 *
 * The actually work of computing the fluxes and speeds is done
 * by local (`static`) helper functions that take as arguments
 * pointers to all the individual fields.  This is helpful to the
 * compilers, since by specifying the `restrict` keyword, we are
 * promising that we will not access the field data through the
 * wrong pointer.  This lets the compiler do a better job with
 * vectorization.
 */


static const float g = 9.8;

__device__
static
void shallow2dv_flux(float* __restrict__ fh,
                     float* __restrict__ fhu,
                     float* __restrict__ fhv,
                     float* __restrict__ gh,
                     float* __restrict__ ghu,
                     float* __restrict__ ghv,
                     const float* __restrict__ h,
                     const float* __restrict__ hu,
                     const float* __restrict__ hv,
                     float g,
                     int ncell)
{
    memcpy(fh, hu, ncell * sizeof(float));
    memcpy(gh, hv, ncell * sizeof(float));
    //cudaMemcpy(fh, &hu, ncell * sizeof(float), cudaMemcpyDeviceToDevice);
    //cudaMemcpy(gh, &hv, ncell * sizeof(float), cudaMemcpyDeviceToDevice);

    //int index = blockIdx.x * blockDim.x + threadIdx.x;
    //int stride = blockDim.x * gridDim.x;

    for (int i = 0; i < ncell; i += 1) {
        float hi = h[i], hui = hu[i], hvi = hv[i];
        float inv_h = 1/hi;
        fhu[i] = hui*hui*inv_h + (0.5f*g)*hi*hi;
        fhv[i] = hui*hvi*inv_h;
        ghu[i] = hui*hvi*inv_h;
        ghv[i] = hvi*hvi*inv_h + (0.5f*g)*hi*hi;
    }
}
__device__
static
void shallow2dv_speed(float* __restrict__ cxy,
                      const float* __restrict__ h,
                      const float* __restrict__ hu,
                      const float* __restrict__ hv,
                      float g,
                      int ncell)
{
	//printf("&&&&&&");
	//err = ::cudaDeviceSynchronize();
    float cx = cxy[0];
    float cy = cxy[1];
	
    //int index = blockIdx.x * blockDim.x + threadIdx.x;
    //int stride = blockDim.x * gridDim.x;

    for (int i = 0; i < ncell; i += 1) {
        float hi = h[i];
        float inv_hi = 1.0f/h[i];
        float root_gh = sqrtf(g * hi);
        float cxi = fabsf(hu[i] * inv_hi) + root_gh;
        float cyi = fabsf(hv[i] * inv_hi) + root_gh;
        if (cx < cxi) cx = cxi;
        if (cy < cyi) cy = cyi;
    }
    cxy[0] = cx;
    cxy[1] = cy;
}

__device__
void shallow2d_flux(float* FU, float* GU,const float* U,
                    int ncell, int field_stride)
{
	
    shallow2dv_flux(FU, FU+field_stride, FU+2*field_stride,
                    GU, GU+field_stride, GU+2*field_stride,
                    U,  U +field_stride, U +2*field_stride,
                    g, ncell);
}

__device__
void shallow2d_speed(float* cxy, const float* U,
                     int ncell, int field_stride)
{
    shallow2dv_speed(cxy, U, U+field_stride, U+2*field_stride, g, ncell);
}
