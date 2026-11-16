/* SPDX-License-Identifier: MIT */
#ifndef LIGHTCAPTURE_LONG_OUTLINE_H
#define LIGHTCAPTURE_LONG_OUTLINE_H

typedef struct { int left, top, right, bottom; } LcOutlineRect;

static inline unsigned lc_outline_strips(LcOutlineRect crop,LcOutlineRect desktop,LcOutlineRect out[4]){
    const int s=2;
    LcOutlineRect a[4]={
        {crop.left-s,crop.top-s,crop.right+s,crop.top},
        {crop.left-s,crop.bottom,crop.right+s,crop.bottom+s},
        {crop.left-s,crop.top,crop.left,crop.bottom},
        {crop.right,crop.top,crop.right+s,crop.bottom}};
    unsigned n=0;
    for(unsigned i=0;i<4;i++){
        LcOutlineRect r={
            a[i].left<desktop.left?desktop.left:a[i].left,
            a[i].top<desktop.top?desktop.top:a[i].top,
            a[i].right>desktop.right?desktop.right:a[i].right,
            a[i].bottom>desktop.bottom?desktop.bottom:a[i].bottom};
        if(r.right>r.left&&r.bottom>r.top)out[n++]=r;
    }
    return n;
}
#endif
