// nanosvg (build.zig.zon) compiled in, behind one function: file_icon.zig
// rasterizes the icon pack's SVGs with it.
#include <stdlib.h>
#include <string.h>

#define NANOSVG_IMPLEMENTATION
#include "nanosvg.h"
#define NANOSVGRAST_IMPLEMENTATION
#include "nanosvgrast.h"

// Renders the SVG `data` (`len` bytes) scaled to fill `px` x `px` pixels.
// Returns RGBA pixels (not premultiplied) to free with `svgFree`, or NULL.
unsigned char *svgRasterize(const char *data, size_t len, int px) {
    // nsvgParse writes into the text it parses.
    char *text = malloc(len + 1);
    if (!text) return NULL;
    memcpy(text, data, len);
    text[len] = 0;
    NSVGimage *image = nsvgParse(text, "px", 96);
    free(text);
    if (!image) return NULL;

    unsigned char *pixels = NULL;
    NSVGrasterizer *rast = nsvgCreateRasterizer();
    float side = image->width > image->height ? image->width : image->height;
    if (rast && side > 0) {
        pixels = calloc((size_t)px * px, 4);
        if (pixels) nsvgRasterize(rast, image, 0, 0, px / side, pixels, px, px, px * 4);
    }
    nsvgDeleteRasterizer(rast);
    nsvgDelete(image);
    return pixels;
}

void svgFree(unsigned char *pixels) { free(pixels); }
