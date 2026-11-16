/* SPDX-License-Identifier: MIT */
#ifndef LIGHTCAPTURE_LONG_FINISH_H
#define LIGHTCAPTURE_LONG_FINISH_H

/* A first frame alone is a normal screenshot, not a long screenshot. */
static inline int lc_long_can_save(int viewport_height,int stitched_height){
    return viewport_height>0&&stitched_height>viewport_height;
}
#endif
