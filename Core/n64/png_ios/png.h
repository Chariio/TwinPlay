#ifndef TWINPLAY_PNG_STUB_H
#define TWINPLAY_PNG_STUB_H
#include <setjmp.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

#define PNG_LIBPNG_VER_STRING "1.6.40-stub"
#define PNG_COLOR_TYPE_RGB 2
#define PNG_COLOR_TYPE_RGB_ALPHA 6
#define PNG_INTERLACE_NONE 0
#define PNG_COMPRESSION_TYPE_DEFAULT 0
#define PNG_FILTER_TYPE_DEFAULT 0

typedef unsigned char png_byte;
typedef png_byte* png_bytep;
typedef png_byte** png_bytepp;
typedef const char* png_const_charp;
typedef void* png_voidp;
typedef size_t png_size_t;

typedef struct png_struct {
    jmp_buf jmp;
    png_voidp io_ptr;
} png_struct;
typedef png_struct* png_structp;
typedef png_struct** png_structpp;

typedef struct png_info {
    int dummy;
} png_info;
typedef png_info* png_infop;
typedef png_info** png_infopp;

typedef void (*png_error_ptr)(png_structp, png_const_charp);
typedef void (*png_rw_ptr)(png_structp, png_bytep, png_size_t);
typedef void (*png_flush_ptr)(png_structp);

#define png_jmpbuf(png_ptr) ((png_ptr)->jmp)

png_structp png_create_write_struct(png_const_charp v, png_voidp e, png_error_ptr err, png_error_ptr warn);
png_infop png_create_info_struct(png_structp png_ptr);
void png_destroy_write_struct(png_structpp png_ptr, png_infopp info_ptr);
void png_set_write_fn(png_structp png_ptr, png_voidp io, png_rw_ptr write_fn, png_flush_ptr flush_fn);
void png_set_IHDR(png_structp png_ptr, png_infop info, unsigned width, unsigned height, int bit_depth,
                  int color_type, int interlace, int compression, int filter);
void png_set_rows(png_structp png_ptr, png_infop info, png_bytepp rows);
void png_write_png(png_structp png_ptr, png_infop info, int transforms, png_voidp params);
png_voidp png_get_io_ptr(png_structp png_ptr);

#ifdef __cplusplus
}
#endif
#endif
