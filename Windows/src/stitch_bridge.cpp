#include "lightcapture_stitch.hpp"
#include <new>
extern "C" {
void *lc_stitch_new(void){try{return new lightcapture::VerticalStitch;}catch(...){return nullptr;}}
void lc_stitch_free(void *h){delete static_cast<lightcapture::VerticalStitch*>(h);}
int lc_stitch_add(void *h,const uint8_t *p,int w,int r){
    if(!h)return -1;
    using E=lightcapture::StitchResult;
    try {
        switch(static_cast<lightcapture::VerticalStitch*>(h)->append({p,w,r,static_cast<ptrdiff_t>(w)*4})){
            case E::Started:return 0;
            case E::Added:return 1;
            case E::Unchanged:return 2;
            case E::Ambiguous:return 3;
            case E::Invalid:return 4;
            case E::Limit:return 5;
        }
    }catch(...){}
    return -1;
}
const uint8_t *lc_stitch_view(void *h,int *w,int *r){
    if(!h)return nullptr;
    auto *p=static_cast<lightcapture::VerticalStitch*>(h);
    *w=p->width();*r=p->height();
    return p->data();
}
}
