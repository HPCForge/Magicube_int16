/* Copyright (c) 2019, NVIDIA CORPORATION. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *  * Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *  * Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *  * Neither the name of NVIDIA CORPORATION nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 * OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/**
 * Matrix multiplication: C = A * B.
 * Host code.
 *
 * This sample implements matrix multiplication which makes use of shared memory
 * to ensure data reuse, the matrix multiplication is done using tiling approach.
 * It has been written for clarity of exposition to illustrate various CUDA programming
 * principles, not with the goal of providing the most performant generic kernel for matrix multiplication.
 * See also:
 * V. Volkov and J. Demmel, "Benchmarking GPUs to tune dense linear algebra,"
 * in Proc. 2008 ACM/IEEE Conf. on Supercomputing (SC '08),
 * Piscataway, NJ: IEEE Press, 2008, pp. Art. 31:1-11.
 */

// System includes
#include <stdio.h>
#include <assert.h>
#include <cuda.h>
#include <mma.h>

// CUDA runtime
#include <cuda_runtime.h>

// Helper functions and utilities to work with CUDA
#include <helper_functions.h>
#include <helper_cuda.h>

#ifndef CPU_DEBUG
// Set this to 1 to verify the correctness of the GPU-computed matrix.
#define CPU_DEBUG 0
#endif

#ifndef SHARED_MEMORY_LIMIT_64K
// Set this to 0 to use more than 64 Kb of shared memory to cache data, to
// improve the performance of the computations on GPU.
// Note that you need a GPU that can have more than 64 Kb of shared memory
// per multiprocessor.
#define SHARED_MEMORY_LIMIT_64K 1
#endif

// GPU configuration.

#define WARP_SIZE 32

// MMA matrix tile dimensions.

#define M 16
#define N 16
#define K 16

#define WMMA_M 16
#define WMMA_N 16
#define WMMA_K 16

// GEMM configuration.

#define M_TILES 256
#define N_TILES 256
#define K_TILES 256

#define M_GLOBAL (M * M_TILES)
#define N_GLOBAL (N * N_TILES)
#define K_GLOBAL (K * K_TILES)

#define C_LAYOUT wmma::mem_row_major

// Implementation constants.

#define WARPS_PER_BLOCK 8
#define THREADS_PER_BLOCK (WARP_SIZE * WARPS_PER_BLOCK)

#if SHARED_MEMORY_LIMIT_64K
// With only 64 Kb shared memory available, we can fit two 8-tile chunks of
// the A and B matrix data, that are 16 * 16 * 8 * 8 * 2 = 32 Kb each
// (i.e. two 8x8 arrays of tiles of 16x16 half-typed elements per CTA).
// But we cannot account the 8 Kb total skew overhead, without which the
// performance would be severely impacted. So we choose to reduce the chunk size
// in half, i.e. the amount of A and B matrix data we cache in shared memory.
// Accordingly, this doubles the number of outer iterations across the global K
// dimension, which only slightly impacts the performance.
#define CHUNK_K 4
#else
#define CHUNK_K 8
#endif

#define CHUNK_LINE_BYTES (CHUNK_K * K * sizeof(half))
#define WARP_COPY_BYTES (WARP_SIZE * sizeof(int4))
#define CHUNK_COPY_LINES_PER_WARP (WARP_COPY_BYTES / CHUNK_LINE_BYTES)
#define CHUNK_COPY_LINE_LANES (WARP_SIZE / CHUNK_COPY_LINES_PER_WARP)

#define BLOCK_ROW_WARPS 2
#define BLOCK_COL_WARPS 4

#define WARP_ROW_TILES 4
#define WARP_COL_TILES 2

#define BLOCK_ROW_TILES (WARP_ROW_TILES * BLOCK_ROW_WARPS)
#define BLOCK_COL_TILES (WARP_COL_TILES * BLOCK_COL_WARPS)

#define GLOBAL_MEM_STRIDE N_GLOBAL

#define SHMEM_STRIDE (N * BLOCK_ROW_TILES)
#define SHMEM_OFFSET (N * WARP_ROW_TILES)

// The macro below is used to shift rows of the A matrix and columns of the B matrix
// in shared memory to minimize possible bank conflicts.
// Before performing the nvcuda::wmma::mma_sync operation, the warp must load the matrix
// data using the nvcuda::wmma::load_matrix_sync operation. Although the memory access pattern
// is not specified for that function, each lane in the warp can read one or multiple matrix
// elements from different matrix rows or columns.
// For shared memory, such access can result in bank conflicts if different rows / columns
// of the matrix map to the same bank. By shifting each row and column by a few bytes, we
// make sure that they map to different banks, thus reducing the number of possible bank
// conflicts.
// The number of 16 two-byte "half" elements is chosen as the minimum possible shift because
// we must keep each row and column 256-bit aligned, as required by nvcuda::wmma::load_matrix_sync.
#define SKEW_HALF 16

#define checkKernelErrors(expr)                             \
  do {                                                      \
    expr;                                                   \
                                                            \
    cudaError_t __err = cudaGetLastError();                 \
    if (__err != cudaSuccess) {                             \
      printf("Line %d: '%s' failed: %s\n", __LINE__, #expr, \
             cudaGetErrorString(__err));                    \
      abort();                                              \
    }                                                       \
  } while (0)

using namespace nvcuda;

__host__ void init_host_matrices(half *a, half *b, float *c) {
  for (int i = 0; i < M_GLOBAL; i++) {
    for (int j = 0; j < K_GLOBAL; j++) {
      a[i * K_GLOBAL + j] = (half)(rand() % 3);
    }
  }

  for (int i = 0; i < N_GLOBAL; i++) {
    for (int j = 0; j < K_GLOBAL; j++) {
      b[i * K_GLOBAL + j] = (half)(rand() % 3);
    }
  }

  for (int t = 0; t < M_GLOBAL * N_GLOBAL; t++) {
    c[t] = static_cast<float>(rand() % 3);
  }
}

__global__ void compute_gemm(const half *A, const half *B, const float *C,
                             float *D, float alpha, float beta) {
  extern __shared__ half shmem[][CHUNK_K * K + SKEW_HALF];

  // Warp and lane identification.
  const unsigned int warpId = threadIdx.x / WARP_SIZE;
  const unsigned int laneId = threadIdx.x % WARP_SIZE;

  // Offset in shared memory from which the B matrix is stored.
  const size_t shmem_idx_b_off = BLOCK_COL_TILES * M;

  // This pointer is used to access the C and D matrix tiles this warp computes.
  float *shmem_warp_tile_ptr = (float *)&shmem[0][0] +
                               (warpId / 2) * SHMEM_STRIDE * K * 2 +
                               (warpId % 2) * SHMEM_OFFSET;

  // This pointer is used to stream the C and D matrices block-wide tile to and
  // from shared memory.
  float *shmem_warp_stream_ptr =
      (float *)&shmem[0][0] + warpId * SHMEM_STRIDE * K;

  // Adjust the beta scaler, as it'll be multiplied by alpha at the end of
  // each tile computation. Technically this is not generally correct (may
  // result in a loss of precision). Zero still needs to be specially handled
  // though.
  beta /= alpha;

  // Each CTA slides along the 128 x 128 tiles from the top left corner of the
  // matrix to the right and down, and selects the next tile to compute. Once
  // there's no such tile, all warps in this CTA exit.
  for (unsigned int block_pos = blockIdx.x;; block_pos += gridDim.x) {
    const unsigned int block_tile_i =
        ((block_pos * BLOCK_ROW_TILES) / N_TILES) * (BLOCK_COL_TILES);
    const unsigned int block_tile_j = (block_pos * BLOCK_COL_TILES) % N_TILES;

    // Stop when there are no more D matrix tiles to compute in this CTA.
    if (block_tile_i >= M_TILES) {
      break;
    }

    // This warp's pointer to the C matrix data to copy memory from to shared
    // memory.
    const size_t gmem_idx =
        (block_tile_i + warpId) * M * GLOBAL_MEM_STRIDE + block_tile_j * N;
    const float *src_gmem_warp_stream_ptr = &C[gmem_idx];

    // Stream multiple C tiles to shared memory.
#pragma unroll
    for (int i = 0; i < K; i++) {
      typedef int4 copy_t;

      *((copy_t *)(shmem_warp_stream_ptr + SHMEM_STRIDE * i) + laneId) =
          *((copy_t *)(src_gmem_warp_stream_ptr + GLOBAL_MEM_STRIDE * i) +
            laneId);
    }

    __syncthreads();

    // These fragments will accumulate the result of A and B matrix fragment
    // multiplications along the K_GLOBAL dimension.
    wmma::fragment<wmma::accumulator, M, N, K, float> c[WARP_COL_TILES]
                                                       [WARP_ROW_TILES];

    // Load the C matrix tiles into fragments from shared memory.
#pragma unroll
    for (int i = 0; i < WARP_COL_TILES; i++) {
#pragma unroll
      for (int j = 0; j < WARP_ROW_TILES; j++) {
        const float *tile_ptr =
            shmem_warp_tile_ptr + i * SHMEM_STRIDE * K + j * N;

        wmma::load_matrix_sync(c[i][j], tile_ptr, SHMEM_STRIDE, C_LAYOUT);
      }
    }

    __syncthreads();

    // Scale the C matrix.
#pragma unroll
    for (int i = 0; i < WARP_COL_TILES; i++) {
#pragma unroll
      for (int j = 0; j < WARP_ROW_TILES; j++) {
#pragma unroll
        for (int t = 0; t < c[i][j].num_elements; t++) {
          c[i][j].x[t] *= beta;
        }
      }
    }

    // Select what warp copies what matrix to shared memory.
    // Warps 0-3 copy the A matrix, warps 4-7 copy the B matrix.
    const half *warp_ptr = (warpId < 4) ? (&A[block_tile_i * M * K_GLOBAL] +
                                           M * K_GLOBAL * (warpId % 4) * 2)
                                        : (&B[block_tile_j * N * K_GLOBAL] +
                                           N * K_GLOBAL * (warpId % 4) * 2);

    // Go through the global K dimension by a fixed step at a time.
#pragma unroll
    for (int tile_k = 0; tile_k < K_TILES; tile_k += CHUNK_K) {
      // Copy slices of the A and B matrices to shared memory.
      // The first half of the warps in the CTA copy the A matrix, the rest copy
      // the B matrix.
      size_t shmem_idx =
          warpId < (WARPS_PER_BLOCK / 2)
              ? (M * (warpId % (WARPS_PER_BLOCK / 2)) * 2)
              : (N * (warpId % (WARPS_PER_BLOCK / 2)) * 2 + shmem_idx_b_off);

      // First half of the warp copies the first row / column of the matrix,
      // the second half of the warp copies the next.
      int4 *lane_ptr = (int4 *)(warp_ptr + tile_k * K +
                                (laneId / CHUNK_COPY_LINE_LANES) * K_GLOBAL) +
                       (laneId % CHUNK_COPY_LINE_LANES);

      // Shift the second half of the warp to the next row / column in the
      // shared memory.
      shmem_idx += laneId / CHUNK_COPY_LINE_LANES;

#pragma unroll
      for (int i = 0; i < ((WARP_SIZE / 2) / CHUNK_COPY_LINES_PER_WARP) * 2;
           i++) {
        // Copy 16 bytes at once in each lane.
        *((int4 *)&shmem[shmem_idx][0] + (laneId % CHUNK_COPY_LINE_LANES)) =
            *lane_ptr;

        // Advance the global memory pointer and the shared memory index.
        lane_ptr =
            (int4 *)((half *)lane_ptr + K_GLOBAL * CHUNK_COPY_LINES_PER_WARP);
        shmem_idx += CHUNK_COPY_LINES_PER_WARP;
      }

      __syncthreads();

      // Compute a grid of C matrix tiles in each warp.
#pragma unroll
      for (int k_step = 0; k_step < CHUNK_K; k_step++) {
        wmma::fragment<wmma::matrix_a, M, N, K, half, wmma::row_major>
            a[WARP_COL_TILES];
        wmma::fragment<wmma::matrix_b, M, N, K, half, wmma::col_major>
            b[WARP_ROW_TILES];

#pragma unroll
        for (int i = 0; i < WARP_COL_TILES; i++) {
          size_t shmem_idx_a = (warpId / 2) * M * 2 + (i * M);
          const half *tile_ptr = &shmem[shmem_idx_a][k_step * K];

          wmma::load_matrix_sync(a[i], tile_ptr, K * CHUNK_K + SKEW_HALF);

#pragma unroll
          for (int j = 0; j < WARP_ROW_TILES; j++) {
            if (i == 0) {
              // Load the B matrix fragment once, because it is going to be
              // reused against the other A matrix fragments.
              size_t shmem_idx_b = shmem_idx_b_off +
                                   (WARP_ROW_TILES * N) * (warpId % 2) +
                                   (j * N);
              const half *tile_ptr = &shmem[shmem_idx_b][k_step * K];

              wmma::load_matrix_sync(b[j], tile_ptr, K * CHUNK_K + SKEW_HALF);
            }

            wmma::mma_sync(c[i][j], a[i], b[j], c[i][j]);
          }
        }
      }

      __syncthreads();
    }

      // Store the D fragments to shared memory.
#pragma unroll
    for (int i = 0; i < WARP_COL_TILES; i++) {
#pragma unroll
      for (int j = 0; j < WARP_ROW_TILES; j++) {
#pragma unroll
        // Uniform, point-wise transformations of ALL fragment elements by ALL
        // threads in the warp are well-defined even though element indices
        // within fragment storage are not defined.
        for (int t = 0; t < c[i][j].num_elements; t++) c[i][j].x[t] *= alpha;

        float *tile_ptr = shmem_warp_tile_ptr + i * SHMEM_STRIDE * K + j * N;

        wmma::store_matrix_sync(tile_ptr, c[i][j], SHMEM_STRIDE, C_LAYOUT);
      }
    }

    __syncthreads();

    // Now that shared memory contains all the D tiles, stream them to global
    // memory.
    float *dst_gmem_warp_stream_ptr = &D[gmem_idx];

#pragma unroll
    for (int i = 0; i < K; i++) {
      *((int4 *)(dst_gmem_warp_stream_ptr + GLOBAL_MEM_STRIDE * i) + laneId) =
          *((int4 *)(shmem_warp_stream_ptr + SHMEM_STRIDE * i) + laneId);
    }

    __syncthreads();
  }
}

// Performs an MxNxK GEMM (C=alpha*A*B + beta*C) assuming:
//  1) Matrices are packed in memory.
//  2) M, N and K are multiples of 16.
//  3) Neither A nor B are transposed.
// Note: This is a less performant version of the compute_gemm kernel. It is
// designed for
//       demonstration purposes only to show the CUDA WMMA API use without
//       relying on availability of the shared memory.
__global__ void simple_wmma_gemm(half *a, half *b, float *c, float *d, int m_ld,
                                 int n_ld, int k_ld, float alpha, float beta) {
  // Leading dimensions. Packed with no transpositions.
  int lda = k_ld;
  int ldb = k_ld;
  int ldc = n_ld;

  // Tile using a 2D grid
  int warpM = (blockIdx.x * blockDim.x + threadIdx.x) / warpSize;
  int warpN = (blockIdx.y * blockDim.y + threadIdx.y);

  // Declare the fragments
  wmma::fragment<wmma::matrix_a, WMMA_M, WMMA_N, WMMA_K, half, wmma::row_major>
      a_frag;
  wmma::fragment<wmma::matrix_b, WMMA_M, WMMA_N, WMMA_K, half, wmma::col_major>
      b_frag;
  wmma::fragment<wmma::accumulator, WMMA_M, WMMA_N, WMMA_K, float> acc_frag;
  wmma::fragment<wmma::accumulator, WMMA_M, WMMA_N, WMMA_K, float> c_frag;

  wmma::fill_fragment(acc_frag, 0.0f);

  // Loop over k
  for (int i = 0; i < k_ld; i += WMMA_K) {
    int aCol = i;
    int aRow = warpM * WMMA_M;
    int bCol = warpN * N;
    int bRow = i;

    // Bounds checking
    if (aRow < m_ld && aCol < k_ld && bRow < k_ld && bCol < n_ld) {
      // Load the inputs
      wmma::load_matrix_sync(a_frag, a + aCol + aRow * lda, lda);
      wmma::load_matrix_sync(b_frag, b + bRow + bCol * ldb, ldb);

      // Perform the matrix multiplication
      wmma::mma_sync(acc_frag, a_frag, b_frag, acc_frag);
    }
  }

  // Load in the current value of c, scale it by beta, and add this our result
  // scaled by alpha
  int cCol = warpN * WMMA_N;
  int cRow = warpM * WMMA_M;

  if (cRow < m_ld && cCol < n_ld) {
    wmma::load_matrix_sync(c_frag, c + cCol + cRow * ldc, ldc,
                           wmma::mem_row_major);

    for (int i = 0; i < c_frag.num_elements; i++) {
      c_frag.x[i] = alpha * acc_frag.x[i] + beta * c_frag.x[i];
    }

    // Store the output
    wmma::store_matrix_sync(d + cCol + cRow * ldc, c_frag, ldc,
                            wmma::mem_row_major);
  }
}

__host__ void matMultiplyOnHost(half *A, half *B, float *C, float alpha,
                                float beta, int numARows, int numAColumns,
                                int numBRows, int numBColumns, int numCRows,
                                int numCColumns) {
  for (int i = 0; i < numCRows; i++) {
    for (int j = 0; j < numCColumns; j++) {
      float temp = 0.0;

      for (int k = 0; k < numAColumns; k++) {
        temp += (float)A[i * numAColumns + k] * (float)B[j * numBRows + k];
      }

      C[i * numCColumns + j] = temp * alpha + beta * C[i * numCColumns + j];
    }
  }
}

/**
 * Matrix multiplication (CUDA Kernel) on the device: C = A * B
 * wA is A's width and wB is B's width
 */
template <int BLOCK_SIZE> __global__ void MatrixMulCUDA(float *C, float *A,
    float *B, int wA,
    int wB) {
  // Block index
  int bx = blockIdx.x;
  int by = blockIdx.y;

  // Thread index
  int tx = threadIdx.x;
  int ty = threadIdx.y;

  // Index of the first sub-matrix of A processed by the block
  int aBegin = wA * BLOCK_SIZE * by;

  // Index of the last sub-matrix of A processed by the block
  int aEnd   = aBegin + wA - 1;

  // Step size used to iterate through the sub-matrices of A
  int aStep  = BLOCK_SIZE;

  // Index of the first sub-matrix of B processed by the block
  int bBegin = BLOCK_SIZE * bx;

  // Step size used to iterate through the sub-matrices of B
  int bStep  = BLOCK_SIZE * wB;

  // Csub is used to store the element of the block sub-matrix
  // that is computed by the thread
  float Csub = 0;

  // Loop over all the sub-matrices of A and B
  // required to compute the block sub-matrix
  for (int a = aBegin, b = bBegin;
       a <= aEnd;
       a += aStep, b += bStep) {
    // Declaration of the shared memory array As used to
    // store the sub-matrix of A
    __shared__ float As[BLOCK_SIZE][BLOCK_SIZE];

    // Declaration of the shared memory array Bs used to
    // store the sub-matrix of B
    __shared__ float Bs[BLOCK_SIZE][BLOCK_SIZE];

    // Load the matrices from device memory
    // to shared memory; each thread loads
    // one element of each matrix
    As[ty][tx] = A[a + wA * ty + tx];
    Bs[ty][tx] = B[b + wB * ty + tx];

    // Synchronize to make sure the matrices are loaded
    __syncthreads();

    // Multiply the two matrices together;
    // each thread computes one element
    // of the block sub-matrix
#pragma unroll

    for (int k = 0; k < BLOCK_SIZE; ++k) {
      Csub += As[ty][k] * Bs[k][tx];
    }

    // Synchronize to make sure that the preceding
    // computation is done before loading two new
    // sub-matrices of A and B in the next iteration
    __syncthreads();
  }

  // Write the block sub-matrix to device memory;
  // each thread writes one element
  int c = wB * BLOCK_SIZE * by + BLOCK_SIZE * bx;
  C[c + wB * ty + tx] = Csub;
}

void ConstantInit(float *data, int size, float val) {
  for (int i = 0; i < size; ++i) {
    data[i] = val;
  }
}

/**
 * Run a simple test of matrix multiplication using CUDA
 */
int MatrixMultiply(int argc, char **argv,
                   int block_size, const dim3 &dimsA,
                   const dim3 &dimsB) {
  printf("Initializing...\n");

  int dev = findCudaDevice(argc, (const char **)argv);

  cudaDeviceProp deviceProp;
  checkCudaErrors(cudaGetDeviceProperties(&deviceProp, dev));

  // Tensor cores require a GPU of Volta (SM7X) architecture or higher.
  if (deviceProp.major < 7) {
    printf(
        "cudaTensorCoreGemm requires SM 7.0 or higher to use Tensor "
        "Cores.  Exiting...\n");
    exit(EXIT_WAIVED);
  }
  printf("M: %d (%d x %d)\n", M_GLOBAL, M, M_TILES);
  printf("N: %d (%d x %d)\n", N_GLOBAL, N, N_TILES);
  printf("K: %d (%d x %d)\n", K_GLOBAL, K, K_TILES);

  half *TFA_h = NULL;
  half *TFB_h = NULL;
  float *TFC_h = NULL;
#if CPU_DEBUG
  float *result_hD = NULL;
  float *result_host = NULL;
#endif

  TFA_h = (half *)malloc(sizeof(half) * M_GLOBAL * K_GLOBAL);
  TFB_h = (half *)malloc(sizeof(half) * K_GLOBAL * N_GLOBAL);
  TFC_h = (float *)malloc(sizeof(float) * M_GLOBAL * N_GLOBAL);
#if CPU_DEBUG
  result_hD = (float *)malloc(sizeof(float) * M_GLOBAL * N_GLOBAL);
  result_host = (float *)malloc(sizeof(float) * M_GLOBAL * N_GLOBAL);
#endif

  half *A = NULL;
  half *B = NULL;
  float *C = NULL;
  float *D = NULL;

  checkCudaErrors(cudaMalloc(reinterpret_cast<void **>(&A),
                             sizeof(half) * M_GLOBAL * K_GLOBAL));
  checkCudaErrors(cudaMalloc(reinterpret_cast<void **>(&B),
                             sizeof(half) * N_GLOBAL * K_GLOBAL));
  checkCudaErrors(cudaMalloc(reinterpret_cast<void **>(&C),
                             sizeof(float) * M_GLOBAL * N_GLOBAL));
  checkCudaErrors(cudaMalloc(reinterpret_cast<void **>(&D),
                             sizeof(float) * M_GLOBAL * N_GLOBAL));

  assert(((unsigned long long)A) % 128 == 0);
  assert(((unsigned long long)B) % 128 == 0);
  assert(((unsigned long long)C) % 128 == 0);
  assert(((unsigned long long)D) % 128 == 0);

  init_host_matrices(TFA_h, TFB_h, TFC_h);

  printf("Preparing data for GPU...\n");

  checkCudaErrors(cudaMemcpy(A, TFA_h, sizeof(half) * M_GLOBAL * K_GLOBAL,
                             cudaMemcpyHostToDevice));
  checkCudaErrors(cudaMemcpy(B, TFB_h, sizeof(half) * N_GLOBAL * K_GLOBAL,
                             cudaMemcpyHostToDevice));
  checkCudaErrors(cudaMemcpy(C, TFC_h, sizeof(float) * M_GLOBAL * N_GLOBAL,
                             cudaMemcpyHostToDevice));
  checkCudaErrors(cudaMemset(D, 0, sizeof(float) * M_GLOBAL * N_GLOBAL));

  enum {
    // Compute the right amount of shared memory to request.
    // We need shared memory to hold per-CTA C and D matrix tiles, and to cache
    // per-CTA chunks
    // of the A and B matrices. Therefore, the right amount to request is the
    // maximum of those
    // two numbers.
    SHMEM_SZ = MAX(
        sizeof(half) * (BLOCK_COL_TILES * M) * (CHUNK_K * K + SKEW_HALF) * 2,
        M * (BLOCK_ROW_WARPS * WARP_ROW_TILES) * N *
            (BLOCK_COL_WARPS * WARP_COL_TILES) * sizeof(float))
  };

  printf("Required shared memory size: %lu Kb\n", SHMEM_SZ / 1024UL);

  const float alpha = 1.1f;
  const float beta = 1.2f;

  cudaEvent_t start, stop;




  //checkCudaErrors(cudaEventRecord(stop));
  //checkCudaErrors(cudaEventSynchronize(stop));


  //float milliseconds = 0;

  //checkCudaErrors(cudaEventElapsedTime(&milliseconds, start, stop));

  //printf("Time: %f ms\n", milliseconds);
  //printf("TFLOPS: %.2f\n", static_cast<double>((static_cast<double>(M_GLOBAL) *
  //                                              N_GLOBAL * K_GLOBAL * 2) /
  //                                             (milliseconds / 1000.)) /
  //                             1e12);







  // Allocate host memory for matrices A and B
  unsigned int size_A = dimsA.x * dimsA.y;
  unsigned int mem_size_A = sizeof(float) * size_A;
  float *h_A;
  checkCudaErrors(cudaMallocHost(&h_A, mem_size_A));
  unsigned int size_B = dimsB.x * dimsB.y;
  unsigned int mem_size_B = sizeof(float) * size_B;
  float *h_B;
  checkCudaErrors(cudaMallocHost(&h_B, mem_size_B));
  cudaStream_t stream;
  cudaStream_t stream1;
  cudaEvent_t event0;

  // Initialize host memory
  const float valB = 0.01f;
  ConstantInit(h_A, size_A, 1.0f);
  ConstantInit(h_B, size_B, valB);

  // Allocate device memory
  float *d_A, *d_B, *d_C;

  // Allocate host matrix C
  dim3 dimsC(dimsB.x, dimsA.y, 1);
  unsigned int mem_size_C = dimsC.x * dimsC.y * sizeof(float);
  float *h_C;
  checkCudaErrors(cudaMallocHost(&h_C, mem_size_C));

  if (h_C == NULL) {
    fprintf(stderr, "Failed to allocate host matrix C!\n");
    exit(EXIT_FAILURE);
  }

  checkCudaErrors(cudaMalloc(reinterpret_cast<void **>(&d_A), mem_size_A));
  checkCudaErrors(cudaMalloc(reinterpret_cast<void **>(&d_B), mem_size_B));
  checkCudaErrors(cudaMalloc(reinterpret_cast<void **>(&d_C), mem_size_C));
  // Allocate CUDA events that we'll use for timing
  //cudaEvent_t start, stop;
  checkCudaErrors(cudaEventCreate(&start));
  checkCudaErrors(cudaEventCreate(&stop));

  checkCudaErrors(cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking));
  checkCudaErrors(cudaStreamCreateWithFlags(&stream1, cudaStreamNonBlocking));
  checkCudaErrors(cudaEventCreate(&event0));

  // copy host memory to device
  checkCudaErrors(
      cudaMemcpyAsync(d_A, h_A, mem_size_A, cudaMemcpyHostToDevice, stream));
  checkCudaErrors(
      cudaMemcpyAsync(d_B, h_B, mem_size_B, cudaMemcpyHostToDevice, stream));

  cudaEventRecord(event0, stream);
  // Setup execution parameters
  dim3 threads(block_size, block_size);
  dim3 grid(dimsB.x / threads.x, dimsA.y / threads.y);
  checkCudaErrors(cudaFuncSetAttribute(
      compute_gemm, cudaFuncAttributeMaxDynamicSharedMemorySize, SHMEM_SZ));

  // Create and start timer
  printf("Computing result using CUDA Kernel...\n");
  cudaStreamWaitEvent(stream1, event0); // wait for event0 in stream
  cudaDeviceSynchronize();

  // Performs warmup operation using matrixMul CUDA kernel
  if (block_size == 16) {
      MatrixMulCUDA<16><<<grid, threads, 0, stream>>>(d_C, d_A, d_B, dimsA.x, dimsB.x);
      compute_gemm<<<deviceProp.multiProcessorCount, THREADS_PER_BLOCK,
                      SHMEM_SZ, stream1>>>(A, B, C, D, alpha, beta);
  } else {
      MatrixMulCUDA<32><<<grid, threads, 0, stream>>>(d_C, d_A, d_B, dimsA.x, dimsB.x);
      compute_gemm<<<deviceProp.multiProcessorCount, THREADS_PER_BLOCK,
                      SHMEM_SZ, stream1>>>(A, B, C, D, alpha, beta);
  }

  printf("done\n");
  checkCudaErrors(cudaStreamSynchronize(stream));

  cudaDeviceSynchronize();

  // Record the start event
  checkCudaErrors(cudaEventRecord(start, stream));

  // Execute the kernel
  int nIter = 300;

  for (int j = 0; j < nIter; j++) {
    if (block_size == 16) {
      MatrixMulCUDA<16><<<grid, threads, 0, stream>>>(d_C, d_A, d_B, dimsA.x, dimsB.x);
      compute_gemm<<<deviceProp.multiProcessorCount, THREADS_PER_BLOCK,
                      SHMEM_SZ, stream1>>>(A, B, C, D, alpha, beta);
    } else {
      MatrixMulCUDA<32><<<grid, threads, 0, stream>>>(d_C, d_A, d_B, dimsA.x, dimsB.x);
      compute_gemm<<<deviceProp.multiProcessorCount, THREADS_PER_BLOCK,
                      SHMEM_SZ, stream1>>>(A, B, C, D, alpha, beta);
    }
  }

  cudaDeviceSynchronize();

  // Record the stop event
  checkCudaErrors(cudaEventRecord(stop, stream));

  // Wait for the stop event to complete
  checkCudaErrors(cudaEventSynchronize(stop));

  float msecTotal = 0.0f;
  checkCudaErrors(cudaEventElapsedTime(&msecTotal, start, stop));

  // Compute and print the performance
  float msecPerMatrixMul = msecTotal / nIter;
  double flopsPerMatrixMul = 2.0 * static_cast<double>(dimsA.x) *
                             static_cast<double>(dimsA.y) *
                             static_cast<double>(dimsB.x);
  double gigaFlops =
      (flopsPerMatrixMul * 1.0e-9f) / (msecPerMatrixMul / 1000.0f);
  printf(
      "Performance= %.2f GFlop/s, Time= %.3f msec, Size= %.0f Ops,"
      " WorkgroupSize= %u threads/block\n",
      gigaFlops, msecPerMatrixMul, flopsPerMatrixMul, threads.x * threads.y);

  // Copy result from device to host
  checkCudaErrors(
      cudaMemcpyAsync(h_C, d_C, mem_size_C, cudaMemcpyDeviceToHost, stream));
  checkCudaErrors(cudaStreamSynchronize(stream));
  checkCudaErrors(cudaStreamSynchronize(stream1));

  printf("Checking computed result for correctness: ");
  bool correct = true;

  // test relative error by the formula
  //     |<x, y>_cpu - <x,y>_gpu|/<|x|, |y|>  < eps
  double eps = 1.e-6;  // machine zero

  for (int i = 0; i < static_cast<int>(dimsC.x * dimsC.y); i++) {
    double abs_err = fabs(h_C[i] - (dimsA.x * valB));
    double dot_length = dimsA.x;
    double abs_val = fabs(h_C[i]);
    double rel_err = abs_err / abs_val / dot_length;

    if (rel_err > eps) {
      printf("Error! Matrix[%05d]=%.8f, ref=%.8f error term is > %E\n",
             i, h_C[i], dimsA.x * valB, eps);
      correct = false;
    }
  }

#if CPU_DEBUG
  checkCudaErrors(cudaMemcpy(result_hD, D,
                             sizeof(float) * M_GLOBAL * N_GLOBAL,
                             cudaMemcpyDeviceToHost));
#endif

#if CPU_DEBUG
  printf("Verifying correctness of the computations...\n");

  memcpy(result_host, TFC_h, sizeof(float) * M_GLOBAL * N_GLOBAL);

  matMultiplyOnHost(TFA_h, TFB_h, result_host, alpha, beta, M_GLOBAL, K_GLOBAL,
                    K_GLOBAL, N_GLOBAL, M_GLOBAL, N_GLOBAL);

  for (int i = 0; i < N_GLOBAL * M_GLOBAL; i++) {
    if (fabs(result_hD[i] - result_host[i]) > 0.1f)
      printf("mismatch i=%d result_hD=%f result_host=%f\n", i, result_hD[i],
             result_host[i]);
  }
  free(result_hD);
  free(result_host);
#endif

  free(TFA_h);
  free(TFB_h);
  free(TFC_h);
  checkCudaErrors(cudaFree(reinterpret_cast<void *>(A)));
  checkCudaErrors(cudaFree(reinterpret_cast<void *>(B)));
  checkCudaErrors(cudaFree(reinterpret_cast<void *>(C)));
  checkCudaErrors(cudaFree(reinterpret_cast<void *>(D)));

  // Clean up memory
  checkCudaErrors(cudaFreeHost(h_A));
  checkCudaErrors(cudaFreeHost(h_B));
  checkCudaErrors(cudaFreeHost(h_C));
  checkCudaErrors(cudaFree(d_A));
  checkCudaErrors(cudaFree(d_B));
  checkCudaErrors(cudaFree(d_C));
  checkCudaErrors(cudaEventDestroy(start));
  checkCudaErrors(cudaEventDestroy(stop));
  printf(
      "\nNOTE: The CUDA Samples are not meant for performance"
      "measurements. Results may vary when GPU Boost is enabled.\n");

  if (correct) {
    return EXIT_SUCCESS;
  } else {
    return EXIT_FAILURE;
  }
}


/**
 * Program main
 */
int main(int argc, char **argv) {
  printf("[Matrix Multiply Using CUDA] - Starting...\n");

  if (checkCmdLineFlag(argc, (const char **)argv, "help") ||
      checkCmdLineFlag(argc, (const char **)argv, "?")) {
    printf("Usage -device=n (n >= 0 for deviceID)\n");
    printf("      -wA=WidthA -hA=HeightA (Width x Height of Matrix A)\n");
    printf("      -wB=WidthB -hB=HeightB (Width x Height of Matrix B)\n");
    printf("  Note: Outer matrix dimensions of A & B matrices" \
           " must be equal.\n");

    exit(EXIT_SUCCESS);
  }

  // This will pick the best possible CUDA capable device, otherwise
  // override the device ID based on input provided at the command line
  int dev = findCudaDevice(argc, (const char **)argv);

  int block_size = 32;

  //dim3 dimsA(5 * 2 * block_size, 5 * 2 * block_size, 1);
  //dim3 dimsB(5 * 4 * block_size, 5 * 2 * block_size, 1);
  dim3 dimsA(32 * block_size, 32 * block_size, 1);
  dim3 dimsB(32 * block_size, 32 * block_size, 1);
  //dim3 dimsA(5 * 2 * 8 * block_size, 5 * 2 * 8 * block_size, 1);
  //dim3 dimsB(5 * 4 * 8 * block_size, 5 * 2 * 8 * block_size, 1);

  // width of Matrix A
  if (checkCmdLineFlag(argc, (const char **)argv, "wA")) {
    dimsA.x = getCmdLineArgumentInt(argc, (const char **)argv, "wA");
  }

  // height of Matrix A
  if (checkCmdLineFlag(argc, (const char **)argv, "hA")) {
    dimsA.y = getCmdLineArgumentInt(argc, (const char **)argv, "hA");
  }

  // width of Matrix B
  if (checkCmdLineFlag(argc, (const char **)argv, "wB")) {
    dimsB.x = getCmdLineArgumentInt(argc, (const char **)argv, "wB");
  }

  // height of Matrix B
  if (checkCmdLineFlag(argc, (const char **)argv, "hB")) {
    dimsB.y = getCmdLineArgumentInt(argc, (const char **)argv, "hB");
  }

  if (dimsA.x != dimsB.y) {
    printf("Error: outer matrix dimensions must be equal. (%d != %d)\n",
           dimsA.x, dimsB.y);
    exit(EXIT_FAILURE);
  }

  printf("MatrixA(%d,%d), MatrixB(%d,%d)\n", dimsA.x, dimsA.y,
         dimsB.x, dimsB.y);

  int matrix_result = MatrixMultiply(argc, argv, block_size, dimsA, dimsB);

  exit(matrix_result);
}
