#include "png.h"
#include <stdlib.h>

png_structp png_create_write_struct(png_const_charp v, png_voidp e, png_error_ptr err, png_error_ptr warn) {
    (void)v; (void)e; (void)err; (void)warn;
    return (png_structp)calloc(1, sizeof(png_struct));
}
png_infop png_create_info_struct(png_structp png_ptr) {
    (void)png_ptr;
    return (png_infop)calloc(1, sizeof(png_info));
}
void png_destroy_write_struct(png_structpp png_ptr, png_infopp info_ptr) {
    if (info_ptr && *info_ptr) { free(*info_ptr); *info_ptr = NULL; }
    if (png_ptr && *png_ptr) { free(*png_ptr); *png_ptr = NULL; }
}
void png_set_write_fn(png_structp png_ptr, png_voidp io, png_rw_ptr write_fn, png_flush_ptr flush_fn) {
    (void)write_fn; (void)flush_fn;
    if (png_ptr) png_ptr->io_ptr = io;
}
void png_set_IHDR(png_structp png_ptr, png_infop info, unsigned width, unsigned height, int bit_depth,
                  int color_type, int interlace, int compression, int filter) {
    (void)png_ptr; (void)info; (void)width; (void)height; (void)bit_depth;
    (void)color_type; (void)interlace; (void)compression; (void)filter;
}
void png_set_rows(png_structp png_ptr, png_infop info, png_bytepp rows) {
    (void)png_ptr; (void)info; (void)rows;
}
void png_write_png(png_structp png_ptr, png_infop info, int transforms, png_voidp params) {
    (void)png_ptr; (void)info; (void)transforms; (void)params;
}
png_voidp png_get_io_ptr(png_structp png_ptr) { return png_ptr ? png_ptr->io_ptr : NULL; }
