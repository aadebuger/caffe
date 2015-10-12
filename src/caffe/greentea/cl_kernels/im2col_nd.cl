#ifndef __OPENCL_VERSION__
#include "header.cl"
#endif

__kernel void TEMPLATE(im2col_nd, Dtype)(const int n, const int num_axes,
                                     const int channel_axis,
                                     __global const Dtype* data_im,
                                     const int data_off,
                                     __global const int* im_shape,
                                     __global const int* col_shape,
                                     __global const int* kernel_shape,
                                     __global const int* pad,
                                     __global const int* stride,
                                     __global Dtype* data_col,
                                     const int data_col_off) {

  int d_temp[6];
  int d_iter[6];
  int i;

  __global const int* im_shape_ptr = im_shape + channel_axis;
  __global const int* col_shape_ptr = col_shape + channel_axis;

  for (int index = get_global_id(0); index < n; index += get_global_size(0)) {
    // Initialize channel_in, computed in the loop below, with intermediate
    // computations used to compute the spatial indices.
    int channel_in = index;
    int channel_out = 1;
    for (i = num_axes - 1; i >= 0; --i) {
      d_temp[i] = channel_in % col_shape_ptr[i + 1];
      channel_in /= col_shape_ptr[i + 1];
      channel_out *= kernel_shape[i];
    }
    channel_out *= channel_in;
    int data_col_inc = 1;
    for (i = 0; i < num_axes; ++i) {
      channel_out *= col_shape_ptr[i + 1];
      channel_out += d_temp[i];
      d_temp[i] = d_temp[i] * stride[i] - pad[i];
      channel_in *= im_shape_ptr[i + 1];
      channel_in += d_temp[i];
      data_col_inc *= col_shape_ptr[i + 1];
      d_iter[i] = 0;
    }
    __global Dtype* data_col_ptr = data_col + data_col_off + channel_out;
    __global const Dtype* data_im_ptr = data_im + data_off + channel_in;
    bool incremented;
    do {
      bool in_range = true;
      for (i = 0; i < num_axes; ++i) {
        const int d_iter_im = d_iter[i] + d_temp[i];
        in_range &= d_iter_im >= 0 && d_iter_im < im_shape_ptr[i + 1];
        if (!in_range) {
          break;
        }
      }
      if (in_range) {
        int data_im_offset = d_iter[0];
        for (i = 1; i < num_axes; ++i) {
          data_im_offset *= im_shape_ptr[i + 1];
          data_im_offset += d_iter[i];
        }
        *data_col_ptr = data_im_ptr[data_im_offset];
      } else {
        *data_col_ptr = 0;
      }
      data_col_ptr += data_col_inc;
      incremented = false;
      for (i = num_axes - 1; i >= 0; --i) {
        const int d_max = kernel_shape[i];
        if (d_iter[i] == d_max - 1) {
          d_iter[i] = 0;
        } else {  // d_iter[i] < d_max - 1
          ++d_iter[i];
          incremented = true;
          break;
        }
      }  // for (int i = num_axes - 1; i >= 0; --i)
    } while (incremented);  // do
  }
}



__kernel void TEMPLATE(col2im_nd, Dtype)(const int n, const int num_axes,
                                         const int channel_axis,
                                         __global const Dtype* data_col,
                                         const int data_col_off,
                                         __global const int* im_shape,
                                         __global const int* col_shape,
                                         __global const int* kernel_shape,
                                         __global const int* pad,
                                         __global const int* stride,
                                         __global Dtype* data_im,
                                         const int data_im_off) {
  int d_im[6];
  int d_col_iter[6];
  int d_col_start[6];
  int d_col_end[6];

  __global const int* im_shape_ptr = im_shape + channel_axis;
  __global const int* col_shape_ptr = col_shape + channel_axis;
  __global Dtype* data_col_ptr = data_col + data_col_off;

  for (int index = get_global_id(0); index < n; index += get_global_size(0)) {
    // Initialize channel_in, computed in the loop below, with intermediate
    // computations used to compute the spatial indices.
    int channel_im = index;
    // Calculate d_im (image dimensions).
    for (int i = num_axes - 1; i >= 0; --i) {
      d_im[i] = channel_im % im_shape_ptr[i + 1] + pad[i];
      channel_im /= im_shape_ptr[i + 1];
    }
    // Calculate col start/end indices.
    bool done = false;
    for (int i = 0; i < num_axes; ++i) {
      d_col_start[i] = d_col_iter[i] =
          (d_im[i] < kernel_shape[i]) ?
              0 : (d_im[i] - kernel_shape[i]) / stride[i] + 1;
      d_col_end[i] = min(d_im[i] / stride[i] + 1, col_shape_ptr[i + 1]);
      if (d_col_start[i] >= d_col_end[i]) {
        // Skip computation if the dimension is 0 at any spatial axis --
        // final val will be 0.
        data_im[index + data_im_off] = 0;
        done = true;
        break;  // for (int i = 0; i < num_axes; ++i)
      }
    }
    if (done) {
      continue;
    }
    // Loop over the col to compute the output val.
    Dtype val = 0;
    bool incremented = true;
    do {
      // Compute the final offset.
      int final_offset = 0;
      int kernel_shape_prod = 1;
      for (int i = num_axes - 1; i >= 0; --i) {
        final_offset += (d_im[i] - d_col_iter[i] * stride[i])
            * kernel_shape_prod;
        kernel_shape_prod *= kernel_shape[i];
      }
      final_offset += kernel_shape_prod * channel_im;
      for (int i = 0; i < num_axes; ++i) {
        final_offset *= col_shape_ptr[i + 1];
        final_offset += d_col_iter[i];
      }
      val += data_col_ptr[final_offset];
      incremented = false;
      for (int i = num_axes - 1; i >= 0; --i) {
        const int d_max = d_col_end[i];
        if (d_col_iter[i] == d_max - 1) {
          d_col_iter[i] = d_col_start[i];
        } else {  // d_col_iter[i] < d_max - 1
          ++d_col_iter[i];
          incremented = true;
          break;  // for (int i = num_axes - 1; i >= 0; --i)
        }
      }  // for (int i = num_axes - 1; i >= 0; --i)
    } while (incremented);
    data_im[index + data_im_off] = val;
  }
}