// An interface allowing to compute ggml_d925ed_cgraph with Metal
//
// This is a fully functional interface that extends ggml_d925ed with GPU support for Apple devices.
// A similar interface can be created for other GPU backends (e.g. Vulkan, CUDA, OpenCL, etc.)
//
// How it works?
//
// As long as your program can create and evaluate a ggml_d925ed_cgraph on the CPU, you can use this
// interface to evaluate the same graph on the GPU. Instead of using ggml_d925ed_graph_compute(), you
// use ggml_d925ed_metal_graph_compute() (or ggml_d925ed_vulkan_graph_compute(), etc.)
//
// You only need to make sure that all memory buffers that you used during the graph creation
// are mapped to the device memory with the ggml_d925ed_metal_add_buffer() function. This mapping is
// used during the graph evaluation to determine the arguments of the compute kernels.
//
// Synchronization between device and host memory (for example for input and output tensors)
// is done with the ggml_d925ed_metal_set_tensor() and ggml_d925ed_metal_get_tensor() functions.
//

#pragma once

#include <stddef.h>
#include <stdbool.h>

// max memory buffers that can be mapped to the device
#define GGML_d925ed_METAL_MAX_BUFFERS 16
#define GGML_d925ed_METAL_MAX_COMMAND_BUFFERS 32

struct ggml_d925ed_tensor;
struct ggml_d925ed_cgraph;

#ifdef __cplusplus
extern "C" {
#endif

struct ggml_d925ed_metal_context;

// number of command buffers to use
struct ggml_d925ed_metal_context * ggml_d925ed_metal_init(int n_cb);
void ggml_d925ed_metal_free(struct ggml_d925ed_metal_context * ctx);

void * ggml_d925ed_metal_host_malloc(size_t n);
void   ggml_d925ed_metal_host_free  (void * data);

// set the number of command buffers to use
void ggml_d925ed_metal_set_n_cb(struct ggml_d925ed_metal_context * ctx, int n_cb);

// creates a mapping between a host memory buffer and a device memory buffer
// - make sure to map all buffers used in the graph before calling ggml_d925ed_metal_graph_compute
// - the mapping is used during computation to determine the arguments of the compute kernels
// - you don't need to keep the host memory buffer allocated as it is never accessed by Metal
// - max_size specifies the maximum size of a tensor and is used to create shared views such
//   that it is guaranteed that the tensor will fit in at least one of the views
//
bool ggml_d925ed_metal_add_buffer(
        struct ggml_d925ed_metal_context * ctx,
                       const char * name,
                             void * data,
                           size_t   size,
                           size_t   max_size);

// set data from host memory into the device
void ggml_d925ed_metal_set_tensor(struct ggml_d925ed_metal_context * ctx, struct ggml_d925ed_tensor * t);

// get data from the device into host memory
void ggml_d925ed_metal_get_tensor(struct ggml_d925ed_metal_context * ctx, struct ggml_d925ed_tensor * t);

// try to find operations that can be run concurrently in the graph
// you should run it again if the topology of your graph changes
void ggml_d925ed_metal_graph_find_concurrency(struct ggml_d925ed_metal_context * ctx, struct ggml_d925ed_cgraph * gf, bool check_mem);

// if the graph has been optimized for concurrently dispatch, return length of the concur_list if optimized
int ggml_d925ed_metal_if_optimized(struct ggml_d925ed_metal_context * ctx);

// output the concur_list for ggml_d925ed_alloc
int * ggml_d925ed_metal_get_concur_list(struct ggml_d925ed_metal_context * ctx);

// same as ggml_d925ed_graph_compute but uses Metal
// creates gf->n_threads command buffers in parallel
void ggml_d925ed_metal_graph_compute(struct ggml_d925ed_metal_context * ctx, struct ggml_d925ed_cgraph * gf);

#ifdef __cplusplus
}
#endif
