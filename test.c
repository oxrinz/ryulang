#include <cuda.h>
#include <stdio.h>

int main() {
    CUdevice dev;
    CUcontext ctx;
    CUmodule mod;
    CUfunction kernel;
    CUdeviceptr d_x;

    cuInit(0);
    cuDeviceGet(&dev, 0);
    cuCtxCreate(&ctx, 0, dev);

    cuModuleLoad(&mod, "kernel.ptx");
    cuModuleGetFunction(&kernel, mod, "myKernel");

    int x[3] = {1, 2, 3};
    
    cuMemAlloc(&d_x, 3 * sizeof(int));

    cuMemcpyHtoD(d_x, x, 3 * sizeof(int));

    void *params[] = {&d_x};

    cuLaunchKernel(kernel, 1, 1, 1, 3, 1, 1, 0, 0, params, 0);

    cuMemFree(d_x);
    cuCtxDestroy(ctx);

    return 0;
}