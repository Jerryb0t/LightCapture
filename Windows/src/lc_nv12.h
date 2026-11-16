#ifndef LC_NV12_H
#define LC_NV12_H
#include <stddef.h>
#include <stdint.h>

/* Limited-range BT.709, packed bottom-up BI_RGB BGRA input to top-down NV12.
 * Width and height are positive even dimensions validated by the caller. */
static inline void lc_bgra_to_nv12(const uint8_t *src,uint8_t *out,int w,int h) {
    uint8_t *uv=out+(size_t)w*h;
    for (int y=0;y<h;y+=2) {
        const uint8_t *p=src+(size_t)(h-1-y)*w*4,*q=p-(size_t)w*4;
        uint8_t *a=out+(size_t)y*w,*b=a+w;
        for (int x=0;x<w;x+=2,p+=8,q+=8) {
            a[x]=(uint8_t)(16+(47*p[2]+157*p[1]+16*p[0]+128)/256);
            a[x+1]=(uint8_t)(16+(47*p[6]+157*p[5]+16*p[4]+128)/256);
            b[x]=(uint8_t)(16+(47*q[2]+157*q[1]+16*q[0]+128)/256);
            b[x+1]=(uint8_t)(16+(47*q[6]+157*q[5]+16*q[4]+128)/256);
            int red=(p[2]+p[6]+q[2]+q[6]+2)/4;
            int green=(p[1]+p[5]+q[1]+q[5]+2)/4;
            int blue=(p[0]+p[4]+q[0]+q[4]+2)/4;
            *uv++=(uint8_t)((32768-26*red-86*green+112*blue+128)/256);
            *uv++=(uint8_t)((32768+112*red-102*green-10*blue+128)/256);
        }
    }
}
#endif
