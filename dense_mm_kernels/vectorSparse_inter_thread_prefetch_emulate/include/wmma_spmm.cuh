#include "cuda_fp16.h"
#ifndef WMMA_SPMM_H
#define WMMA_SPMM_H

namespace spmm{

//cudaError_t wmmaSpmm(int m_vec, int vec_length, int k, int n, 
//    const int* __restrict__ row_indices, 
//    const int* __restrict__ row_offsets,
//    const int* __restrict__ column_indices,
//    const int* __restrict__ values,
//    const int* __restrict__ rhs_matrix,
//    int* __restrict__ output_matrix) ;
//
//cudaError_t wmmaSpmm(int m_vec, int vec_length, int k, int n, 
//    const int* __restrict__ row_indices, 
//    const int* __restrict__ row_offsets,
//    const int* __restrict__ column_indices,
//    const short* __restrict__ values,
//    const int* __restrict__ rhs_matrix,
//    int* __restrict__ output_matrix) ;

cudaError_t wmmaSpmm_4b8v(int m_vec, int vec_length, int k, int n, 
    const int* __restrict__ row_indices, 
    const int* __restrict__ row_offsets,
    const int* __restrict__ column_indices,
    const int* __restrict__ values,
    const int* __restrict__ rhs_matrix,
    int* __restrict__ output_matrix);

cudaError_t wmmaSpmm_8b(int m_vec, int vec_length, int n, int k,
    const int* __restrict__ row_indices,
    const int* __restrict__ row_offsets,
    const int* __restrict__ column_indices,
    const int* __restrict__ values,
    const int* __restrict__ rhs_matrix,
    int* __restrict__ output_matrix);

cudaError_t wmmaSpmm_8b4b4v(int m_vec, int vec_length, int n, int k,
    const int* __restrict__ row_indices,
    const int* __restrict__ row_offsets,
    const int* __restrict__ column_indices,
    const int* __restrict__ values,
    const int* __restrict__ rhs_matrix,
    int* __restrict__ output_matrix);

//cudaError_t wmmaSpmm_8b4v(int m_vec, int vec_length, int n, int k,
//    const int* __restrict__ row_indices,
//    const int* __restrict__ row_offsets,
//    const int* __restrict__ column_indices,
//    const int* __restrict__ values,
//    const int* __restrict__ rhs_matrix,
//    int* __restrict__ output_matrix);



//template <typename IndexType, typename VecType, int Tile_M, int Tile_N, int Tile_K, int BlockWidth>
//cudaError_t wmmaSpmmEx_4bit(
//    int m_vec, int vec_length, int k, int n,
//    const int* __restrict__ row_indices,
//    const int* __restrict__ row_offsets,
//    const int* __restrict__ column_indices,
//    const VecType* __restrict__ values,
//    const int* __restrict__ rhs_matrix,
//    int* __restrict__ output_matrix);

//cudaError_t wmmaSpmm(int m_vec, int vec_length, int k, int n, 
//    const int* __restrict__ row_indices, 
//    const int* __restrict__ row_offsets,
//    const int* __restrict__ column_indices,
//    const half* __restrict__ values,
//    const half* __restrict__ rhs_matrix,
//    float* __restrict__ output_matrix) ;
//
//cudaError_t wmmaSpmm(int m_vec, int vec_length, int k, int n, 
//    const int* __restrict__ row_indices, 
//    const int* __restrict__ row_offsets,
//    const int* __restrict__ column_indices,
//    const half* __restrict__ values,
//    const half* __restrict__ rhs_matrix,
//    half* __restrict__ output_matrix) ;
//
//cudaError_t wmmaSpmm(int m_vec, int vec_length, int k, int n, 
//    const int* __restrict__ row_indices, 
//    const int* __restrict__ row_offsets,
//    const int* __restrict__ column_indices,
//    const float* __restrict__ values,
//    const float* __restrict__ rhs_matrix,
//    float* __restrict__ output_matrix) ;

} // namespace spmm

#endif