#include <cuda.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void print(const char *str)
{
    printf("%s\n", str);
    fflush(stdout);
}

void print_cuda_error(int error_code, int function)
{
    switch (function)
    {
    case 0:
        printf("CUINIT Error: %d\n", error_code);
        break;
    case 1:
        printf("CUDEVICEGET Error: %d\n", error_code);
        break;
    case 2:
        printf("CUCTXCREATE Error: %d\n", error_code);
        break;
    case 3:
        printf("CUMODULELOADDATA Error: %d\n", error_code);
        break;
    case 4:
        printf("CUMEMALLOC Error: %d\n", error_code);
        break;
    case 5:
        printf("CUMEMCPYHTOD Error: %d\n", error_code);
        break;
    case 6:
        printf("CUMEMCPYDTOH Error: %d\n", error_code);
        break;
    case 7:
        printf("CULAUNCHKERNEL Error: %d\n", error_code);
        break;
    case 8:
        printf("CUMODULEGETFUNCTION Error: %d\n", error_code);
        break;
    default:
        printf("CUDA Unknown function error: %d (Function: %d)\n", error_code, function);
        break;
    }
}
const char *int_to_string(int value)
{
    print("JÄVLA");
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

const char *array_to_string(void *array_ptr, int length, int elem_type)
{
    static char buffer[1024];
    int offset = 0;

    buffer[offset++] = '[';

    for (int i = 0; i < length; i++)
    {
        if (elem_type == 0)
        {
            int value = ((int *)array_ptr)[i];
            offset += snprintf(buffer + offset, sizeof(buffer) - offset, "%d", value);
        }
        else if (elem_type == 1)
        {
            float value = ((float *)array_ptr)[i];
            offset += snprintf(buffer + offset, sizeof(buffer) - offset, "%f", value);
        }
        else if (elem_type == 2)
        {
            const char *value = ((const char **)array_ptr)[i];
            offset += snprintf(buffer + offset, sizeof(buffer) - offset, "\"%s\"", value);
        }

        if (i < length - 1)
        {
            buffer[offset++] = ',';
            buffer[offset++] = ' ';
        }
    }

    buffer[offset++] = ']';
    buffer[offset] = '\0';

    return buffer;
}

int string_length(const char str[])
{
    const char *s = str;
    while (*s)
    {
        s++;
    }
    return s - str + 100;
}

static CUdevice device;
static CUcontext context;
static CUmodule module;

void print_results(void *result, int n)
{
    float *result_array = (float *)result;
    printf("Results:\n");
    for (int i = 0; i < n; i++)
    {
        printf("%d: %f\n", i, result_array[i]);
    }
}

void load_cuda_kernel(const char *ptx_code)
{
    CUresult err;
    err = cuInit(0);
    if (err != CUDA_SUCCESS)
    {
        fprintf(stderr, "cuInit failed: %d\n", err);
        exit(1);
    }

    CUdevice device;
    err = cuDeviceGet(&device, 0);
    if (err != CUDA_SUCCESS)
    {
        fprintf(stderr, "cuDeviceGet failed: %d\n", err);
        exit(1);
    }

    err = cuCtxCreate(&context, 0, device);
    if (err != CUDA_SUCCESS)
    {
        fprintf(stderr, "cuCtxCreate failed: %d\n", err);
        exit(1);
    }

    err = cuModuleLoadData(&module, ptx_code);
    if (err != CUDA_SUCCESS)
    {
        fprintf(stderr, "cuModuleLoadData failed: %d\n", err);
        exit(1);
    }
}

CUresult run_cu_mem_dtoh(void *host, CUdeviceptr device, size_t bytebount)
{
    CUresult err;
    err = cuMemcpyDtoH(host, device, bytebount);
    if (err != CUDA_SUCCESS)
    {
        fprintf(stderr, "cuMemcpyDtoH for d_output failed: %d\n", err);
        exit(1);
    }
    return err;
}

void print_cu_memcpy_dtoh_error(int code)
{
    printf("cuMemcpyDtoH fucked up, code: %d\n", code);
}

// take an array of inputs as device pointers
// take result pointer, also as device pointer
// grid dimensions as raw values, 3 int array
// ^ same with block dims
//
// TODO: currently takes host pointers, change this
int run_cuda_kernel(void **inputs, unsigned int num_inputs, CUdeviceptr *d_output, unsigned int *grid_dims, unsigned int *block_dims)
{
    CUresult err;
    CUfunction kernel;
    CUdeviceptr d_input;
    void *result = malloc(6 * sizeof(float));
    void *input1 = inputs[0];
    uint32_t param_n = 6;
    size_t data_size = 6 * sizeof(float);


    void *params[2] = {&d_input, d_output};

    err = cuLaunchKernel(kernel,
                         grid_dims[0], grid_dims[1], grid_dims[2],    // grid dimensions
                         block_dims[0], block_dims[1], block_dims[2], // block dimensions
                         0, NULL,                                     // shared memory bytes and stream
                         params, NULL);
    if (err != CUDA_SUCCESS)
    {
        fprintf(stderr, "cuLaunchKernel failed: %d\n", err);
        exit(1);
    }

    print_results(result, 6);
}