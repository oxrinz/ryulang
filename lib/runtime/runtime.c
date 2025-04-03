#include <cuda.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void print(const char *str)
{
    printf("%s\n", str);
}

const char *int_to_string(int value)
{
    static char buffer[32];
    snprintf(buffer, sizeof(buffer), "%d", value);
    return buffer;
}

const char *float_to_string(float value)
{
    static char buffer[32];
    snprintf(buffer, sizeof(buffer), "%f", value);
    return buffer;
}

const char *bool_to_string(int value)
{
    return value ? "true" : "false";
}

static CUdevice device;
static CUcontext context;
static CUmodule module;
static int initialized = 0;

void print_results(void *result, int n)
{
    float *result_array = (float *)result;
    printf("Results:\n");
    for (int i = 0; i < n; i++)
    {
        printf("%d: %f\n", i, result_array[i]);
    }
}

// take ptx pointer as input
// take an array of inputs as device pointers
// take result pointer, also as device pointer
// grid dimensions as raw values, 3 int array
// ^ same with block dims
int run_cuda_kernel(const char *ptx_code, void **inputs, void *result, int n)
{
    CUresult err;
    CUdevice device;
    CUcontext context;
    CUmodule module;
    CUfunction kernel;
    CUdeviceptr d_input, d_output;
    void *input1 = inputs[0];
    float host_output[4];
    uint32_t param_n = 4;
    size_t data_size = 4 * sizeof(float);

    err = cuInit(0);
    if (err != CUDA_SUCCESS) {
        fprintf(stderr, "cuInit failed: %d\n", err);
        exit(1);
    }

    err = cuDeviceGet(&device, 0);
    if (err != CUDA_SUCCESS) {
        fprintf(stderr, "cuDeviceGet failed: %d\n", err);
        exit(1);
    }

    err = cuCtxCreate(&context, 0, device);
    if (err != CUDA_SUCCESS) {
        fprintf(stderr, "cuCtxCreate failed: %d\n", err);
        exit(1);
    }

    err = cuModuleLoadData(&module, ptx_code);
    if (err != CUDA_SUCCESS) {
        fprintf(stderr, "cuModuleLoadData failed: %d\n", err);
        exit(1);
    }

    err = cuModuleGetFunction(&kernel, module, "main");
    if (err != CUDA_SUCCESS) {
        fprintf(stderr, "cuModuleGetFunction failed: %d\n", err);
        exit(1);
    }

    err = cuMemAlloc(&d_input, data_size);
    if (err != CUDA_SUCCESS) {
        fprintf(stderr, "cuMemAlloc for d_input failed: %d\n", err);
        exit(1);
    }
    err = cuMemAlloc(&d_output, data_size);
    if (err != CUDA_SUCCESS) {
        fprintf(stderr, "cuMemAlloc for d_output failed: %d\n", err);
        exit(1);
    }

    err = cuMemcpyHtoD(d_input, input1, data_size);
    if (err != CUDA_SUCCESS) {
        fprintf(stderr, "cuMemcpyHtoD for d_input failed: %d\n", err);
        exit(1);
    }

    void* params[3] = {&d_input, &d_output, &param_n};

    err = cuLaunchKernel(kernel,
                         1, 1, 1,   // grid dimensions: 1x1x1
                         4, 1, 1,   // block dimensions: 4x1x1
                         0, NULL,   // shared memory bytes and stream
                         params, NULL);  // kernel parameters and extra
    if (err != CUDA_SUCCESS) {
        fprintf(stderr, "cuLaunchKernel failed: %d\n", err);
        exit(1);
    }

    // Copy output data from device to host
    err = cuMemcpyDtoH(host_output, d_output, data_size);
    if (err != CUDA_SUCCESS) {
        fprintf(stderr, "cuMemcpyDtoH for d_output failed: %d\n", err);
        exit(1);
    }

    print("fuck");

    // Print results
    printf("Kernel results:\n");
    for (int i = 0; i < 4; i++) {
        printf("%.2f ", host_output[i]);
    }
    printf("\n");

    cuMemFree(d_input);
    cuMemFree(d_output);
    cuModuleUnload(module);
    cuCtxDestroy(context);
}