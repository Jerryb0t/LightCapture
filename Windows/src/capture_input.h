/* SPDX-License-Identifier: MIT */
#ifndef LIGHTCAPTURE_CAPTURE_INPUT_H
#define LIGHTCAPTURE_CAPTURE_INPUT_H

#include "long_outline.h"

enum LcCaptureMode { LC_CAPTURE_SCREENSHOT, LC_CAPTURE_LONG };
enum LcCaptureAction { LC_CAPTURE_NONE, LC_CAPTURE_SAVE_SCREENSHOT, LC_CAPTURE_START_LONG,
                      LC_CAPTURE_CANCEL_SELECTION, LC_CAPTURE_SAVE_LONG, LC_CAPTURE_CANCEL_LONG };
enum LcCaptureKey { LC_CAPTURE_OTHER, LC_CAPTURE_RETURN, LC_CAPTURE_ESCAPE };

static inline int lc_selection_has_area(LcOutlineRect r){
    return r.right-r.left>=2&&r.bottom-r.top>=2;
}
static inline int lc_selection_is_drag(int x0,int y0,int x1,int y1,int moved){
    int dx=x1-x0,dy=y1-y0;
    return moved||dx>3||dx< -3||dy>3||dy< -3;
}
static inline LcOutlineRect lc_selection_resolve(int x0,int y0,int x1,int y1,int moved,LcOutlineRect hover){
    if(lc_selection_is_drag(x0,y0,x1,y1,moved)){
        LcOutlineRect r={x0<x1?x0:x1,y0<y1?y0:y1,x0>x1?x0:x1,y0>y1?y0:y1};
        return r;
    }
    return hover;
}
static inline enum LcCaptureAction lc_selection_released(enum LcCaptureMode mode,LcOutlineRect r){
    return mode==LC_CAPTURE_LONG&&lc_selection_has_area(r)?LC_CAPTURE_START_LONG:LC_CAPTURE_NONE;
}
static inline enum LcCaptureAction lc_selection_key(enum LcCaptureMode mode,enum LcCaptureKey key,
                                                   int selecting,LcOutlineRect r){
    if(key==LC_CAPTURE_ESCAPE)return LC_CAPTURE_CANCEL_SELECTION;
    if(key!=LC_CAPTURE_RETURN||selecting||!lc_selection_has_area(r))return LC_CAPTURE_NONE;
    return mode==LC_CAPTURE_LONG?LC_CAPTURE_START_LONG:LC_CAPTURE_SAVE_SCREENSHOT;
}
static inline enum LcCaptureAction lc_long_key(enum LcCaptureKey key,int enter_bound,int esc_bound){
    if(key==LC_CAPTURE_RETURN&&enter_bound)return LC_CAPTURE_SAVE_LONG;
    if(key==LC_CAPTURE_ESCAPE&&esc_bound)return LC_CAPTURE_CANCEL_LONG;
    return LC_CAPTURE_NONE;
}
#endif
