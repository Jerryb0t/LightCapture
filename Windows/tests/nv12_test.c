// The test predicates must execute even in an optimized Zig build.
#ifdef NDEBUG
#undef NDEBUG
#endif
#include "lc_nv12.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(void) {
    uint8_t bgra[4*4*4]={0};
    uint8_t result[4*4*3/2+1];
    result[24]=99;
    for (int i=0;i<4*2*4;i++) bgra[i]=255; /* bottom half white */
    lc_bgra_to_nv12(bgra,result,4,4);
    for (int i=0;i<8;i++) assert(result[i]==16);
    for (int i=8;i<16;i++) assert(result[i]==235);
    for (int i=16;i<24;i++) assert(result[i]==128);
    assert(result[24]==99);
    memset(bgra,0,sizeof bgra);
    for (int i=0;i<16;i++) bgra[i*4+2]=255;
    lc_bgra_to_nv12(bgra,result,4,4);
    for (int i=0;i<16;i++) assert(result[i]==63);
    for (int i=16;i<24;i+=2) { assert(result[i]==102); assert(result[i+1]==240); }
    puts("NV12 conversion: orientation, luma, chroma, buffer boundary passed");
    return 0;
}
