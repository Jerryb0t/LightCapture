#define WIN32_LEAN_AND_MEAN
#define UNICODE
#define _UNICODE
#include <windows.h>
#include <windowsx.h>
#include <dwmapi.h>
#include <wincodec.h>
#include <commdlg.h>
#include <shlobj.h>
#include <shellapi.h>
#include <strsafe.h>
#include <stdint.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <wchar.h>
#include "lightcapture_video.h"
#include "long_outline.h"
extern void lc_show_support(HWND owner,BOOL zh);
extern void lc_hide_support(void);

#define CLIP 1
#define HOTKEY 900
#define LONG_SAVE_HOTKEY 901
#define LONG_CANCEL_HOTKEY 902
#define LONG_TIMER 1
#define LONG_SAMPLE_MS 180
#define REOPEN (WM_APP+1)
#define SETTINGS_CAPTURE 10
#define SETTINGS_CHOOSE 11
#define SETTINGS_OPEN 12
#define SETTINGS_LOGIN 13
#define SETTINGS_SAVE 14
#define SETTINGS_QUIT 15
#define SETTINGS_KEY 16
#define SETTINGS_APPLY_KEY 17
#define MAX_CANDIDATES 512
#define MAX_PIXELS 24000000LL
#define REGKEY L"Software\\LightCapture"
#define WCLS L"LightCaptureWindows.Settings.v1"
#define OCLS L"LightCaptureWindows.Overlay.v1"
#define IDENTITY L"Local\\LightCaptureWindows.app.v1"

typedef struct {
    HBITMAP bitmap;
    void *pixels;
    BITMAPINFO info;
    int width, height;
} Image;
typedef struct { RECT area; int popup; } Candidate;
enum { NONE, PEN, ARROW, BOX, TEXT };
static HINSTANCE instance;
static HWND mainWindow, overlay, longControl;
static HWND preOverlayFocus;
static HDC frozenDc;
static HGDIOBJ frozenOld;
static Image frozen;
static RECT virtualScreen, hover, selection;
static Candidate candidates[MAX_CANDIDATES];
static size_t candidateCount;
static BOOL isZh, selecting, dragged, annotating, saveWithCopy=TRUE;
static POINT anchor, current, lastInk;
static RECT toolbar, actions[9];
static int tool;
static unsigned hotMods=0, hotKey=VK_F2;
static WCHAR outputDir[MAX_PATH], exe[MAX_PATH];
static HFONT font;
static const COLORREF accent=RGB(95,176,254), ink=RGB(250,87,84);

static const WCHAR *tr(const WCHAR *cn,const WCHAR *en){return isZh?cn:en;}
static int width(RECT r){return r.right-r.left;}
static int height(RECT r){return r.bottom-r.top;}
static BOOL has_area(RECT r){return width(r)>0&&height(r)>0;}
static RECT rect_from(POINT a, POINT b) {
    return (RECT){min(a.x,b.x),min(a.y,b.y),max(a.x,b.x),max(a.y,b.y)};
}
static void error_text(const WCHAR *msg) {
    MessageBoxW(IsWindow(overlay)?overlay:mainWindow,msg,L"LightCapture",MB_ICONWARNING|MB_OK);
}

static void* read_setting(const WCHAR *name,DWORD type,void *dst,DWORD bytes) {
    DWORD size=bytes;
    LONG status=RegGetValueW(HKEY_CURRENT_USER, REGKEY,name,type,NULL,dst,&size);
    return status==ERROR_SUCCESS?dst:NULL;
}
static BOOL put_setting(const WCHAR *name,DWORD type,const void *src,DWORD bytes) {
    HKEY key;
    if(RegCreateKeyExW(HKEY_CURRENT_USER,REGKEY,0,NULL,0,KEY_SET_VALUE,NULL,&key,NULL)!=ERROR_SUCCESS) return FALSE;
    LONG status=RegSetValueExW(key,name,0,type,src,bytes);
    RegCloseKey(key);
    return status==ERROR_SUCCESS;
}
static void load_settings(void) {
    isZh=PRIMARYLANGID(GetUserDefaultUILanguage())==LANG_CHINESE;
    DWORD mode=1, packed=VK_F2;
    read_setting(L"SaveWithCopy",RRF_RT_REG_DWORD,&mode,sizeof mode);
    read_setting(L"Hotkey",RRF_RT_REG_DWORD,&packed,sizeof packed);
    saveWithCopy=mode!=0;
    hotKey=packed&0xffff;
    hotMods=packed>>16;
    if(!read_setting(L"Output",RRF_RT_REG_SZ,outputDir,sizeof outputDir)||!outputDir[0]){
        PWSTR path=NULL;
        if(SUCCEEDED(SHGetKnownFolderPath(&FOLDERID_Pictures,0,NULL,&path))) {
            StringCchPrintfW(outputDir,MAX_PATH,L"%ls\\LightCapture",path);
            CoTaskMemFree(path);
        }
    }
}
static BOOL output_named(WCHAR *buffer,size_t count,BOOL folderOnly,const WCHAR *subdir,const WCHAR *extension) {
    WCHAR dir[MAX_PATH];
    if(!outputDir[0]||FAILED(StringCchPrintfW(dir,MAX_PATH,L"%ls\\%ls",outputDir,subdir)))return FALSE;
    int r=SHCreateDirectoryExW(NULL,dir,NULL);
    if(r!=ERROR_SUCCESS&&r!=ERROR_ALREADY_EXISTS&&r!=ERROR_FILE_EXISTS)return FALSE;
    if(folderOnly)return SUCCEEDED(StringCchCopyW(buffer,count,dir));
    SYSTEMTIME t;
    GetLocalTime(&t);
    return SUCCEEDED(StringCchPrintfW(buffer,count,L"%ls\\LightCapture-%04u%02u%02u-%02u%02u%02u-%03u.%ls",
      dir,t.wYear,t.wMonth,t.wDay,t.wHour,t.wMinute,t.wSecond,t.wMilliseconds,extension));
}
static BOOL output_path(WCHAR *b,size_t n,BOOL folder){return output_named(b,n,folder,L"Screenshots",L"png");}
static BOOL image_allocate(Image *d,int w,int h) {
    if(w<1||h<1||(int64_t)w*h>MAX_PIXELS)return FALSE;
    ZeroMemory(d,sizeof(*d));
    d->info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
    d->info.bmiHeader.biWidth=w;
    d->info.bmiHeader.biHeight=-h;
    d->info.bmiHeader.biPlanes=1;
    d->info.bmiHeader.biBitCount=32;
    d->info.bmiHeader.biCompression=BI_RGB;
    d->bitmap=CreateDIBSection(NULL,&d->info,DIB_RGB_COLORS,&d->pixels,NULL,0);
    d->width=w;d->height=h;
    return d->bitmap!=NULL;
}
static void image_free(Image *d) {
    if(d->bitmap)DeleteObject(d->bitmap);
    ZeroMemory(d,sizeof(*d));
}
static HRESULT write_png(const Image *d,const WCHAR *path) {
    IWICImagingFactory *wic=NULL;
    IWICStream *stream=NULL;
    IWICBitmapEncoder *encoder=NULL;
    IWICBitmapFrameEncode *frame=NULL;
    WICPixelFormatGUID format=GUID_WICPixelFormat24bppBGR;
    HRESULT hr=CoCreateInstance(&CLSID_WICImagingFactory,NULL,CLSCTX_INPROC_SERVER,&IID_IWICImagingFactory,(void**)&wic);
    if(SUCCEEDED(hr))hr=wic->lpVtbl->CreateStream(wic,&stream);
    if(SUCCEEDED(hr))hr=stream->lpVtbl->InitializeFromFilename(stream,path,GENERIC_WRITE);
    if(SUCCEEDED(hr))hr=wic->lpVtbl->CreateEncoder(wic,&GUID_ContainerFormatPng,NULL,&encoder);
    if(SUCCEEDED(hr))hr=encoder->lpVtbl->Initialize(encoder,(IStream*)stream,WICBitmapEncoderNoCache);
    if(SUCCEEDED(hr))hr=encoder->lpVtbl->CreateNewFrame(encoder,&frame,NULL);
    if(SUCCEEDED(hr))hr=frame->lpVtbl->Initialize(frame,NULL);
    if(SUCCEEDED(hr))hr=frame->lpVtbl->SetSize(frame,d->width,d->height);
    if(SUCCEEDED(hr))hr=frame->lpVtbl->SetPixelFormat(frame,&format);
    if(SUCCEEDED(hr)&&!IsEqualGUID(&format,&GUID_WICPixelFormat24bppBGR))hr=WINCODEC_ERR_UNSUPPORTEDPIXELFORMAT;
    if(SUCCEEDED(hr)){
        int stride=d->width*3;
        BYTE *row=malloc(stride);
        if(!row)hr=E_OUTOFMEMORY;
        for(int y=0;row&&y<d->height&&SUCCEEDED(hr);y++){
            const BYTE *source=(const BYTE*)d->pixels+(size_t)y*d->width*4;
            for(int x=0;x<d->width;x++)memcpy(row+x*3,source+x*4,3);
            hr=frame->lpVtbl->WritePixels(frame,1,stride,stride,row);
        }
        free(row);
    }
    if(SUCCEEDED(hr))hr=frame->lpVtbl->Commit(frame);
    if(SUCCEEDED(hr))hr=encoder->lpVtbl->Commit(encoder);
    if(frame)frame->lpVtbl->Release(frame);
    if(encoder)encoder->lpVtbl->Release(encoder);
    if(stream)stream->lpVtbl->Release(stream);
    if(wic)wic->lpVtbl->Release(wic);
    return hr;
}
static BOOL write_png_atomic(const Image *d,const WCHAR *target){
    WCHAR dir[MAX_PATH], partial[MAX_PATH];
    if(FAILED(StringCchCopyW(dir,MAX_PATH,target)))return FALSE;
    WCHAR *last=wcsrchr(dir,L'\\');
    if(!last)return FALSE;
    *last=0;
    if(!GetTempFileNameW(dir,L"lcs",0,partial))return FALSE;
    BOOL ok=SUCCEEDED(write_png(d,partial))&&MoveFileExW(partial,target,MOVEFILE_WRITE_THROUGH);
    if(!ok)DeleteFileW(partial);
    return ok;
}
static BOOL copy_dib(const Image *d) {
    size_t stride=(size_t)d->width*4, size=stride*d->height;
    HGLOBAL data=GlobalAlloc(GMEM_MOVEABLE,sizeof(BITMAPINFOHEADER)+size);
    if(!data)return FALSE;
    BYTE *locked=GlobalLock(data);
    if(!locked){GlobalFree(data);return FALSE;}
    BITMAPINFOHEADER header=d->info.bmiHeader;
    header.biHeight=d->height; // bottom-up CF_DIB for broad target app compatibility
    header.biSizeImage=(DWORD)size;
    memcpy(locked,&header,sizeof header);
    for(int y=0;y<d->height;y++)memcpy(locked+sizeof header+y*stride,
        (BYTE*)d->pixels+(d->height-1-y)*stride,stride);
    GlobalUnlock(data);
    BOOL ok=FALSE;
    if(OpenClipboard(mainWindow)) {
        ok=EmptyClipboard()&&SetClipboardData(CF_DIB,data);
        CloseClipboard();
    }
    if(!ok)GlobalFree(data);
    return ok;
}
static BOOL CALLBACK on_window(HWND hwnd,LPARAM unused) {
    (void)unused;
    if(candidateCount==MAX_CANDIDATES)return FALSE;
    if(hwnd==mainWindow||!IsWindowVisible(hwnd)||IsIconic(hwnd)||hwnd==GetShellWindow())return TRUE;
    DWORD cloaked=0;
    if(SUCCEEDED(DwmGetWindowAttribute(hwnd,DWMWA_CLOAKED,&cloaked,sizeof cloaked))&&cloaked)return TRUE;
    LONG_PTR ex=GetWindowLongPtrW(hwnd,GWL_EXSTYLE);
    if(ex&WS_EX_TRANSPARENT)return TRUE;
    WCHAR name[80];
    if(!GetClassNameW(hwnd,name,80))return TRUE;
    if(!wcscmp(name,L"Progman")||!wcscmp(name,L"WorkerW")||!wcscmp(name,L"Shell_TrayWnd")||
       !wcscmp(name,L"Shell_SecondaryTrayWnd")||!wcscmp(name,L"tooltips_class32"))return TRUE;
    RECT r, clipped;
    if(FAILED(DwmGetWindowAttribute(hwnd,DWMWA_EXTENDED_FRAME_BOUNDS,&r,sizeof r))&&!GetWindowRect(hwnd,&r))return TRUE;
    if(width(r)<28||height(r)<20||!IntersectRect(&clipped,&r,&virtualScreen))return TRUE;
    LONG_PTR style=GetWindowLongPtrW(hwnd,GWL_STYLE);
    BOOL popup=(ex&WS_EX_TOOLWINDOW)||((style&WS_POPUP)&&!(style&WS_CAPTION));
    // A transparent-looking full desktop/container should not swallow all ordinary windows.
    if(popup&&(int64_t)width(clipped)*height(clipped)*100 >= (int64_t)width(virtualScreen)*height(virtualScreen)*96)return TRUE;
    OffsetRect(&clipped,-virtualScreen.left,-virtualScreen.top);
    candidates[candidateCount++]=(Candidate){clipped,popup};
    return TRUE;
}
static RECT find_hover(POINT p) {
    for(size_t i=0;i<candidateCount;i++)if(PtInRect(&candidates[i].area,p))return candidates[i].area;
    return (RECT){0};
}
static BOOL freeze_screen(void) {
    virtualScreen.left=GetSystemMetrics(SM_XVIRTUALSCREEN);
    virtualScreen.top=GetSystemMetrics(SM_YVIRTUALSCREEN);
    virtualScreen.right=virtualScreen.left+GetSystemMetrics(SM_CXVIRTUALSCREEN);
    virtualScreen.bottom=virtualScreen.top+GetSystemMetrics(SM_CYVIRTUALSCREEN);
    if((int64_t)width(virtualScreen)*height(virtualScreen)>MAX_PIXELS){
        POINT cursor;
        GetCursorPos(&cursor);
        MONITORINFO info={.cbSize=sizeof info};
        if(GetMonitorInfoW(MonitorFromPoint(cursor,MONITOR_DEFAULTTONEAREST),&info)){virtualScreen=info.rcMonitor;}
    }
    candidateCount=0;
    EnumWindows(on_window,0);
    if(!image_allocate(&frozen,width(virtualScreen),height(virtualScreen)))return FALSE;
    HDC screen=GetDC(NULL);
    if(screen) {
        frozenDc=CreateCompatibleDC(screen);
        if(frozenDc)frozenOld=SelectObject(frozenDc,frozen.bitmap);
    }
    BOOL ok=screen&&frozenDc&&frozenOld&&frozenOld!=HGDI_ERROR&&BitBlt(frozenDc,0,0,frozen.width,frozen.height,screen,virtualScreen.left,virtualScreen.top,SRCCOPY|CAPTUREBLT);
    if(screen)ReleaseDC(NULL,screen);
    return ok;
}
static void release_freeze(void) {
    if(frozenDc){if(frozenOld&&frozenOld!=HGDI_ERROR)SelectObject(frozenDc,frozenOld);DeleteDC(frozenDc);}
    frozenDc=NULL;frozenOld=NULL;
    image_free(&frozen);
    selecting=dragged=annotating=FALSE;
    tool=NONE;hover=selection=toolbar=(RECT){0};
}
static void finish_capture(BOOL copy,BOOL save) {
    RECT clipped,bounds={0,0,frozen.width,frozen.height};
    if(!IntersectRect(&clipped,&selection,&bounds))return;
    Image crop;
    if(!image_allocate(&crop,width(clipped),height(clipped))){error_text(tr(L"无法创建截图。",L"Could not allocate the screenshot."));return;}
    GdiFlush();
    for(int y=0;y<crop.height;y++)memcpy((BYTE*)crop.pixels+(size_t)y*crop.width*4,
      (BYTE*)frozen.pixels+((size_t)(clipped.top+y)*frozen.width+clipped.left)*4,
      (size_t)crop.width*4);
    BOOL c=!copy||copy_dib(&crop);
    WCHAR path[MAX_PATH]={0};
    BOOL s=!save||(output_path(path,MAX_PATH,FALSE)&&write_png_atomic(&crop,path));
    image_free(&crop);
    DestroyWindow(overlay);
    if(!c||!s)error_text(!c&&!s?tr(L"无法复制或保存截图。",L"Could not copy or save the screenshot."):
      !c?tr(L"无法访问剪贴板。",L"Could not access the clipboard."):tr(L"无法写入截图目录，请检查保存路径。",L"Could not save the screenshot. Check the output folder."));
}

static HWND textBox;
static POINT textOrigin;
static WNDPROC textBase;
static const WCHAR *keys[] = {L"F1",L"F2",L"Ctrl+A"};
static const unsigned keyCodes[]={VK_F1,VK_F2,'A'}, keyModifiers[]={0,0,MOD_CONTROL};
static const unsigned actionCount=9;
static const WCHAR *labels[][2]={
    {L"画笔",L"Pen"},{L"箭头",L"Arrow"},{L"矩形",L"Box"},{L"文字",L"Text"},
    {L"复制",L"Copy"},{L"保存",L"Save"},{L"长截图",L"Long shot"},{L"录屏",L"Record"},{L"取消",L"Cancel"}
};

static HBRUSH fill(COLORREF c){return CreateSolidBrush(c);}
static void paint_fill(HDC dc,RECT r,COLORREF color){HBRUSH b=fill(color);FillRect(dc,&r,b);DeleteObject(b);}
static void paint_frame(HDC dc,RECT r,COLORREF color){HBRUSH b=fill(color);FrameRect(dc,&r,b);DeleteObject(b);}
static void dim_rect(HDC dc,HDC dark,RECT r){
    if(has_area(r)){
        BLENDFUNCTION blend={AC_SRC_OVER,0,137,0};
        AlphaBlend(dc,r.left,r.top,width(r),height(r),dark,0,0,1,1,blend);
    }
}
static void draw_ink(HDC dc,int action,POINT a,POINT b){
    HPEN pen=CreatePen(PS_SOLID,3,ink);
    HGDIOBJ prior=SelectObject(dc,pen);
    if(action==BOX){
        HGDIOBJ oldBrush=SelectObject(dc,GetStockObject(NULL_BRUSH));
        RECT r=rect_from(a,b);
        Rectangle(dc,r.left,r.top,r.right,r.bottom);
        SelectObject(dc,oldBrush);
    }else{
        MoveToEx(dc,a.x,a.y,NULL);LineTo(dc,b.x,b.y);
        if(action==ARROW){
            double dx=b.x-a.x,dy=b.y-a.y,len=sqrt(dx*dx+dy*dy);
            if(len>3){
                double scale=min(15.0,len/2);
                dx/=len;dy/=len;
                MoveToEx(dc,b.x,b.y,NULL);LineTo(dc,b.x+(int)(-dx*scale-dy*scale/2),b.y+(int)(-dy*scale+dx*scale/2));
                MoveToEx(dc,b.x,b.y,NULL);LineTo(dc,b.x+(int)(-dx*scale+dy*scale/2),b.y+(int)(-dy*scale-dx*scale/2));
            }
        }
    }
    SelectObject(dc,prior);DeleteObject(pen);
}
static void commit_text(void){
    if(!textBox)return;
    WCHAR buffer[512]={0};
    GetWindowTextW(textBox,buffer,512);
    DestroyWindow(textBox);
    textBox=NULL;
    if(buffer[0]){
        int index=SaveDC(frozenDc);
        if(index){
            IntersectClipRect(frozenDc,selection.left,selection.top,selection.right,selection.bottom);
            SelectObject(frozenDc,font);SetBkMode(frozenDc,TRANSPARENT);SetTextColor(frozenDc,ink);
            TextOutW(frozenDc,textOrigin.x,textOrigin.y,buffer,(int)wcslen(buffer));
            RestoreDC(frozenDc,index);
        }
    }
    if(overlay){SetFocus(overlay);InvalidateRect(overlay,NULL,FALSE);}
}
static LRESULT CALLBACK edit_proc(HWND w,UINT m,WPARAM wp,LPARAM lp){
    if(m==WM_GETDLGCODE)return DLGC_WANTALLKEYS;
    if(m==WM_KEYDOWN&&(wp==VK_RETURN||wp==VK_ESCAPE)){
        if(wp==VK_ESCAPE){DestroyWindow(w);textBox=NULL;SetFocus(overlay);}
        else commit_text();
        return 0;
    }
    return CallWindowProcW(textBase,w,m,wp,lp);
}
static void begin_text(POINT p){
    commit_text();
    textOrigin=p;
    int avail=selection.right-p.x;
    if(avail<16)return;
    textBox=CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",NULL,WS_CHILD|WS_VISIBLE|ES_AUTOHSCROLL,
        p.x,p.y,min(220,avail),25,overlay,NULL,instance,NULL);
    if(!textBox)return;
    SendMessageW(textBox,WM_SETFONT,(WPARAM)font,TRUE);
    SendMessageW(textBox,EM_SETLIMITTEXT,511,0);
    textBase=(WNDPROC)SetWindowLongPtrW(textBox,GWLP_WNDPROC,(LONG_PTR)edit_proc);
    SetFocus(textBox);
}
static void layout_toolbar(void){
    toolbar=(RECT){0};
    for(unsigned i=0;i<actionCount;i++)actions[i]=(RECT){0};
    if(!has_area(selection)||(selecting&&!annotating))return;
    POINT fromScreen={selection.left+virtualScreen.left,selection.bottom+virtualScreen.top-1};
    MONITORINFO mi={.cbSize=sizeof mi};
    GetMonitorInfoW(MonitorFromPoint(fromScreen,MONITOR_DEFAULTTONEAREST),&mi);
    RECT usable=mi.rcMonitor;
    OffsetRect(&usable,-virtualScreen.left,-virtualScreen.top);
    int w=min(576,width(usable)-16), h=36, pill=width(usable)>560?7:4;
    if(w<150)return;
    int x=max(usable.left+8,min(selection.left,usable.right-8-w));
    int y=selection.bottom+7;
    if(y+h>usable.bottom-6)y=selection.top-h-7;
    if(y<usable.top+6)y=usable.top+6;
    toolbar=(RECT){x,y,x+w,y+h};
    for(unsigned i=0;i<actionCount;i++){
        int l=x+pill+(w-2*pill)*(int)i/(int)actionCount;
        int r=x+pill+(w-2*pill)*(int)(i+1)/(int)actionCount;
        actions[i]=(RECT){l,y+4,r,y+h-4};
    }
}
static void draw_overlay(HWND w){
    PAINTSTRUCT ps;
    HDC dc=BeginPaint(w,&ps);
    if(!frozenDc){EndPaint(w,&ps);return;}
    BitBlt(dc,ps.rcPaint.left,ps.rcPaint.top,width(ps.rcPaint),height(ps.rcPaint),frozenDc,ps.rcPaint.left,ps.rcPaint.top,SRCCOPY);
    RECT chosen=has_area(selection)?selection:hover;
    if(!has_area(chosen))chosen=(RECT){0};
    HDC dark=CreateCompatibleDC(dc);
    if(dark){
        HBITMAP shade=CreateCompatibleBitmap(dc,1,1);
        if(shade){
            HGDIOBJ backup=SelectObject(dark,shade);
            SetPixel(dark,0,0,RGB(12,15,20));
            dim_rect(dc,dark,(RECT){0,0,frozen.width,chosen.top});
            dim_rect(dc,dark,(RECT){0,chosen.bottom,frozen.width,frozen.height});
            dim_rect(dc,dark,(RECT){0,chosen.top,chosen.left,chosen.bottom});
            dim_rect(dc,dark,(RECT){chosen.right,chosen.top,frozen.width,chosen.bottom});
            SelectObject(dark,backup);DeleteObject(shade);
        }
        DeleteDC(dark);
    }
    if(annotating&&(tool==ARROW||tool==BOX)){
        int s=SaveDC(dc);
        if(s){IntersectClipRect(dc,selection.left,selection.top,selection.right,selection.bottom);
        draw_ink(dc,tool,anchor,current);RestoreDC(dc,s);}
    }
    if(has_area(chosen)){
        paint_frame(dc,chosen,accent);
        InflateRect(&chosen,-1,-1);
        if(has_area(chosen))paint_frame(dc,chosen,accent);
    }
    layout_toolbar();
    HGDIOBJ origFont=SelectObject(dc,font);
    SetBkMode(dc,TRANSPARENT);SetTextColor(dc,RGB(245,248,252));
    if(has_area(toolbar)){
        paint_fill(dc,toolbar,RGB(28,34,43));paint_frame(dc,toolbar,RGB(75,93,110));
        for(unsigned i=0;i<actionCount;i++){
            if(i<4&&tool==(int)i+1)paint_fill(dc,actions[i],RGB(48,88,120));
            RECT area=actions[i];
            DrawTextW(dc,tr(labels[i][0],labels[i][1]),-1,&area,DT_CENTER|DT_VCENTER|DT_SINGLELINE|DT_NOPREFIX);
        }
        const int n=37;
        RECT hint={toolbar.left,toolbar.bottom+4,toolbar.right,toolbar.bottom+4+n};
        if(hint.bottom>frozen.height){hint.bottom=toolbar.top-4;hint.top=hint.bottom-n;}
        if(hint.top>=0){
            paint_fill(dc,hint,RGB(28,34,43));
            DrawTextW(dc,tr(L"长截图：点长截图或按 L。滚动原页面；Enter 保存，Esc 取消。",
                L"Long: click Long or press L. Scroll · Enter save · Esc cancel"),
                -1,&hint,DT_CENTER|DT_VCENTER|DT_SINGLELINE|DT_NOPREFIX|DT_END_ELLIPSIS);
        }
    }else if(!selecting){
        WCHAR const *hint=tr(L"点击窗口或拖动选区 · Enter 确认 · Esc 取消 · F 全屏",L"Click or drag · Enter confirm · Esc cancel · F full display");
        POINT cursor;
        GetCursorPos(&cursor);
        MONITORINFO info={.cbSize=sizeof info};
        GetMonitorInfoW(MonitorFromPoint(cursor,MONITOR_DEFAULTTONEAREST),&info);
        RECT r=info.rcMonitor;
        OffsetRect(&r,-virtualScreen.left,-virtualScreen.top);
        r=(RECT){r.left+18,r.top+18,min(r.left+472,r.right-18),r.top+51};
        if(has_area(r)){
            paint_fill(dc,r,RGB(28,34,43));DrawTextW(dc,hint,-1,&r,DT_CENTER|DT_VCENTER|DT_SINGLELINE|DT_NOPREFIX);
        }
    }
    SelectObject(dc,origFont);
    EndPaint(w,&ps);
}
static void start_long(RECT r);
static void start_recording(RECT r);
static void stop_recording(void);
static int videoEdge=1920, videoFps=30;
static BOOL videoSystem=TRUE, videoMic=FALSE;
static HWND captureButton, recControl;
static void selected_action(void (*action)(RECT)){
    if(!has_area(selection))selection=hover;
    if(has_area(selection)){
        RECT r=selection;
        OffsetRect(&r,virtualScreen.left,virtualScreen.top);
        action(r);
    }
}
static void confirm_overlay(BOOL copy,BOOL save){
    commit_text();
    if(!has_area(selection))selection=hover;
    if(has_area(selection))finish_capture(copy,save);
}
static POINT mouse_at(LPARAM lp){
    POINT p={GET_X_LPARAM(lp),GET_Y_LPARAM(lp)};
    p.x=max(0,min(p.x,frozen.width));
    p.y=max(0,min(p.y,frozen.height));
    return p;
}
static LRESULT CALLBACK overlay_proc(HWND w,UINT m,WPARAM wp,LPARAM lp) {
    switch(m){
    case WM_PAINT:draw_overlay(w);return 0;
    case WM_ERASEBKGND:return 1;
    case WM_SETCURSOR:SetCursor(LoadCursor(NULL,IDC_CROSS));return TRUE;
    case WM_KEYDOWN:
        if(wp==VK_ESCAPE){DestroyWindow(w);return 0;}
        if(wp==VK_RETURN){confirm_overlay(TRUE,saveWithCopy);return 0;}
        if(wp=='R'&&!selecting&&!annotating){selected_action(start_recording);return 0;}
        if(wp=='L'&&!selecting&&!annotating){selected_action(start_long);return 0;}
        if(wp=='F'&&!selecting&&!annotating){
            POINT p;
            GetCursorPos(&p);
            MONITORINFO mi={.cbSize=sizeof mi};
            RECT r,f={0,0,frozen.width,frozen.height};
            GetMonitorInfoW(MonitorFromPoint(p,MONITOR_DEFAULTTONEAREST),&mi);r=mi.rcMonitor;
            OffsetRect(&r,-virtualScreen.left,-virtualScreen.top);IntersectRect(&selection,&r,&f);
            InvalidateRect(w,NULL,FALSE);return 0;
        }break;
    case WM_MOUSEMOVE:{
        POINT p=mouse_at(lp);
        current=p;
        if(annotating){
            if(tool==PEN){
                int s=SaveDC(frozenDc);
                if(s){IntersectClipRect(frozenDc,selection.left,selection.top,selection.right,selection.bottom);
                    draw_ink(frozenDc,tool,lastInk,p);RestoreDC(frozenDc,s);}
                lastInk=p;
            }
        } else if(selecting){
            if(abs(p.x-anchor.x)>3||abs(p.y-anchor.y)>3)dragged=TRUE;
            if(dragged)selection=rect_from(anchor,p);
        } else if(!has_area(selection))hover=find_hover(p);
        InvalidateRect(w,NULL,FALSE);
        return 0;}
    case WM_LBUTTONDOWN:{
        POINT p=mouse_at(lp);
        commit_text();
        if(has_area(toolbar)&&PtInRect(&toolbar,p)){
            for(unsigned i=0;i<actionCount;i++)if(PtInRect(&actions[i],p)){
                if(i<4)tool=tool==(int)i+1?NONE:(int)i+1;
                else if(i==4)confirm_overlay(TRUE,FALSE);
                else if(i==5)confirm_overlay(FALSE,TRUE);
                else if(i==6)selected_action(start_long);
                else if(i==7)selected_action(start_recording);
                else if(i==8)DestroyWindow(w);
                if(IsWindow(w))InvalidateRect(w,NULL,FALSE);
                break;
            }
            return 0;
        }
        if(tool&&PtInRect(&selection,p)){
            if(tool==TEXT)begin_text(p);
            else{anchor=current=lastInk=p;annotating=TRUE;SetCapture(w);}
            return 0;
        }
        tool=NONE;
        anchor=current=p;selecting=TRUE;dragged=FALSE;
        selection=(RECT){0};hover=find_hover(p);SetCapture(w);
        InvalidateRect(w,NULL,FALSE);
        return 0;}
    case WM_LBUTTONUP:{
        POINT p=mouse_at(lp);
        if(annotating){
            if(tool!=PEN){
                int s=SaveDC(frozenDc);
                if(s){IntersectClipRect(frozenDc,selection.left,selection.top,selection.right,selection.bottom);
                    draw_ink(frozenDc,tool,anchor,p);RestoreDC(frozenDc,s);}
            }
            annotating=FALSE;
            ReleaseCapture();
        }else if(selecting){
            selecting=FALSE;
            if(dragged)selection=rect_from(anchor,p);
            else selection=find_hover(p);
            if(width(selection)<2||height(selection)<2)selection=(RECT){0};
            ReleaseCapture();
        }
        InvalidateRect(w,NULL,FALSE);return 0;}
    case WM_CAPTURECHANGED:
        if(selecting){selecting=FALSE;selection=(RECT){0};}
        annotating=FALSE;
        InvalidateRect(w,NULL,FALSE);return 0;
    case WM_DESTROY:
        textBox=NULL;overlay=NULL;release_freeze();return 0;
    }
    return DefWindowProcW(w,m,wp,lp);
}
static void finish_long(BOOL save);
static void begin_capture(void){
    lc_hide_support();
    if(lc_video_active()){stop_recording();return;}
    if(IsWindow(longControl)){finish_long(TRUE);return;}
    if(IsWindow(overlay)){DestroyWindow(overlay);return;}
    preOverlayFocus=GetForegroundWindow();
    if(!freeze_screen()){
        release_freeze();error_text(tr(L"无法获取屏幕图像。",L"Could not freeze the screen."));return;
    }
    POINT p;
    GetCursorPos(&p);
    p.x-=virtualScreen.left;p.y-=virtualScreen.top;
    hover=find_hover(p);
    HWND w=CreateWindowExW(WS_EX_TOOLWINDOW|WS_EX_TOPMOST,OCLS,NULL,WS_POPUP,
        virtualScreen.left,virtualScreen.top,frozen.width,frozen.height,NULL,NULL,instance,NULL);
    if(!w){release_freeze();error_text(tr(L"无法打开选区。",L"Could not open the selection."));return;}
    overlay=w;
    ShowWindow(w,SW_SHOW);
    SetForegroundWindow(w);
    SetFocus(w);
    UpdateWindow(w);
}

static HWND hotChooser, modeCheck, folderLabel, keyStatus;
static BOOL hotRegistered, hotPaused;
static int hot_index(void){
    for(unsigned i=0;i<sizeof keys/sizeof keys[0];i++)if(hotKey==keyCodes[i]&&hotMods==keyModifiers[i])return (int)i;
    return 1;
}
static BOOL bind_hotkey(unsigned mods,unsigned key) {
    return RegisterHotKey(mainWindow,HOTKEY,mods|MOD_NOREPEAT,key);
}
static void key_status(void) {
    if(keyStatus) SetWindowTextW(keyStatus,hotPaused?tr(L"快捷键已暂停",L"Shortcut paused"):
      hotRegistered?tr(L"快捷键已启用",L"Shortcut active"):tr(L"快捷键不可用，请换一个",L"Shortcut unavailable; choose another"));
}
static void change_hotkey(void) {
    LRESULT chosen=SendMessageW(hotChooser,CB_GETCURSEL,0,0);
    if(chosen==CB_ERR||(unsigned)chosen>=sizeof keys/sizeof keys[0])return;
    unsigned oldKey=hotKey,oldMods=hotMods;
    BOOL previous=hotRegistered;
    if(previous&&oldKey==keyCodes[chosen]&&oldMods==keyModifiers[chosen])return;
    if(previous)UnregisterHotKey(mainWindow,HOTKEY);
    hotRegistered=bind_hotkey(keyModifiers[chosen],keyCodes[chosen]);
    if(!hotRegistered){
        hotRegistered=previous&&bind_hotkey(oldMods,oldKey);
        SendMessageW(hotChooser,CB_SETCURSEL,hot_index(),0);
        key_status();
        error_text(tr(L"这个快捷键当前不可用，未修改原设置。",L"That shortcut is unavailable; the previous setting was retained."));
        return;
    }
    unsigned packed=(keyModifiers[chosen]<<16)|keyCodes[chosen];
    if(!put_setting(L"Hotkey",REG_DWORD,&packed,sizeof packed)){
        UnregisterHotKey(mainWindow,HOTKEY);
        hotRegistered=previous&&bind_hotkey(oldMods,oldKey);
        SendMessageW(hotChooser,CB_SETCURSEL,hot_index(),0);
        key_status();
        error_text(tr(L"无法保存快捷键设置。",L"Could not save the shortcut setting."));
        return;
    }
    hotMods=keyModifiers[chosen];
    hotKey=keyCodes[chosen];
    hotPaused=FALSE;
    key_status();
}
static BOOL login_enabled(void){
    WCHAR value[MAX_PATH+40]={0}, expected[MAX_PATH+40];
    DWORD size=sizeof value;
    if(FAILED(StringCchPrintfW(expected,MAX_PATH+40,L"\"%ls\" --background",exe)))return FALSE;
    return RegGetValueW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",
      L"LightCapture",RRF_RT_REG_SZ,NULL,value,&size)==ERROR_SUCCESS&&!wcscmp(expected,value);
}
static BOOL change_login(BOOL state) {
    HKEY key;
    if(RegOpenKeyExW(HKEY_CURRENT_USER,L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",0,KEY_SET_VALUE,&key)!=ERROR_SUCCESS)return FALSE;
    LONG status;
    WCHAR command[MAX_PATH+40];
    if(state){
        if(FAILED(StringCchPrintfW(command,MAX_PATH+40,L"\"%ls\" --background",exe))){RegCloseKey(key);return FALSE;}
        status=RegSetValueExW(key,L"LightCapture",0,REG_SZ,(const BYTE*)command,(DWORD)((wcslen(command)+1)*sizeof(WCHAR)));
    }else{
        status=RegDeleteValueW(key,L"LightCapture");
        if(status==ERROR_FILE_NOT_FOUND)status=ERROR_SUCCESS;
    }
    RegCloseKey(key);
    return status==ERROR_SUCCESS;
}
static void choose_dir(void){
    IFileOpenDialog *dialog=NULL;
    IShellItem *item=NULL;
    PWSTR directory=NULL;
    HRESULT hr=CoCreateInstance(&CLSID_FileOpenDialog,NULL,CLSCTX_INPROC_SERVER,&IID_IFileOpenDialog,(void**)&dialog);
    DWORD options=0;
    if(SUCCEEDED(hr))hr=dialog->lpVtbl->GetOptions(dialog,&options);
    if(SUCCEEDED(hr))hr=dialog->lpVtbl->SetOptions(dialog,options|FOS_PICKFOLDERS|FOS_FORCEFILESYSTEM);
    if(SUCCEEDED(hr))hr=dialog->lpVtbl->Show(dialog,mainWindow);
    if(SUCCEEDED(hr))hr=dialog->lpVtbl->GetResult(dialog,&item);
    if(SUCCEEDED(hr))hr=item->lpVtbl->GetDisplayName(item,SIGDN_FILESYSPATH,&directory);
    if(SUCCEEDED(hr)){
        size_t chars=wcslen(directory);
        if(chars>MAX_PATH-80||!put_setting(L"Output",REG_SZ,directory,(DWORD)((chars+1)*sizeof(WCHAR))))hr=E_FAIL;
        else {StringCchCopyW(outputDir,MAX_PATH,directory);SetWindowTextW(folderLabel,outputDir);}
    }
    if(directory)CoTaskMemFree(directory);
    if(item)item->lpVtbl->Release(item);
    if(dialog)dialog->lpVtbl->Release(dialog);
    if(FAILED(hr)&&hr!=HRESULT_FROM_WIN32(ERROR_CANCELLED))error_text(tr(L"无法设置该保存位置。",L"Could not set the output folder."));
}
static HWND control(HWND parent,const WCHAR *cls,const WCHAR *title,DWORD style,int x,int y,int w,int h,int id){
    unsigned dpi=GetDpiForWindow(parent);
    if(!dpi)dpi=96;
    HWND handle=CreateWindowExW(0,cls,title,WS_VISIBLE|WS_CHILD|style,MulDiv(x,dpi,96),MulDiv(y,dpi,96),
                MulDiv(w,dpi,96),MulDiv(h,dpi,96),parent,(HMENU)(INT_PTR)id,instance,NULL);
    if(handle) SendMessageW(handle,WM_SETFONT,(WPARAM)font,TRUE);
    return handle;
}
static LRESULT CALLBACK main_proc(HWND w,UINT m,WPARAM wp,LPARAM lp) {
    enum { SETTINGS_PAUSE=18, SETTINGS_GITHUB=19, SETTINGS_X=20, SETTINGS_VIDEO_EDGE=21, SETTINGS_VIDEO_FPS=22, SETTINGS_VIDEO_SYSTEM=23, SETTINGS_VIDEO_MIC=24, SETTINGS_SUPPORT=25 };
    switch(m){
    case WM_CREATE:
        control(w,L"STATIC",tr(L"轻截  ·  LightCapture",L"LightCapture"),0,20,20,350,24,0);
        control(w,L"STATIC",tr(L"原生、轻量的截图与录屏工具",L"Native, lightweight screen capture"),0,20,48,440,20,0);
        captureButton=control(w,L"BUTTON",tr(L"开始截图",L"Start capture"),WS_TABSTOP|BS_PUSHBUTTON,20,83,146,32,SETTINGS_CAPTURE);
        control(w,L"STATIC",tr(L"全局快捷键",L"Global shortcut"),0,20,137,140,25,0);
        hotChooser=control(w,L"COMBOBOX",L"",WS_TABSTOP|CBS_DROPDOWNLIST,170,131,88,120,SETTINGS_KEY);
        for(unsigned i=0;i<sizeof keys/sizeof keys[0];i++)SendMessageW(hotChooser,CB_ADDSTRING,0,(LPARAM)keys[i]);
        SendMessageW(hotChooser,CB_SETCURSEL,hot_index(),0);
        control(w,L"BUTTON",tr(L"应用",L"Apply"),WS_TABSTOP|BS_PUSHBUTTON,268,130,69,29,SETTINGS_APPLY_KEY);
        control(w,L"BUTTON",tr(L"暂停 / 恢复",L"Pause / Resume"),WS_TABSTOP|BS_PUSHBUTTON,347,130,105,29,SETTINGS_PAUSE);
        keyStatus=control(w,L"STATIC",L"",0,20,172,390,20,0);
        modeCheck=control(w,L"BUTTON",tr(L"Enter 复制时同时保存（关闭则仅复制）",L"Enter copies and saves (off: copy only)"),
          WS_TABSTOP|BS_AUTOCHECKBOX,20,207,430,23,SETTINGS_SAVE);
        SendMessageW(modeCheck,BM_SETCHECK,saveWithCopy?BST_CHECKED:BST_UNCHECKED,0);
        HWND loginButton=control(w,L"BUTTON",tr(L"登录后隐藏启动（不弹主窗口）",L"Start hidden when signing in"),
             WS_TABSTOP|BS_AUTOCHECKBOX,20,241,430,23,SETTINGS_LOGIN);
        SendMessageW(loginButton,BM_SETCHECK,login_enabled()?BST_CHECKED:BST_UNCHECKED,0);
        control(w,L"STATIC",tr(L"保存位置",L"Output folder"),0,20,285,122,22,0);
        folderLabel=control(w,L"STATIC",outputDir,SS_PATHELLIPSIS|SS_NOPREFIX,20,313,430,20,0);
        control(w,L"BUTTON",tr(L"选择目录…",L"Choose folder…"),WS_TABSTOP|BS_PUSHBUTTON,20,347,145,30,SETTINGS_CHOOSE);
        control(w,L"BUTTON",tr(L"打开目录",L"Open folder"),WS_TABSTOP|BS_PUSHBUTTON,175,347,128,30,SETTINGS_OPEN);
        control(w,L"STATIC",tr(L"录屏",L"Screen recording"),0,20,408,120,23,0);
        HWND edge=control(w,L"COMBOBOX",L"",WS_TABSTOP|CBS_DROPDOWNLIST,154,403,144,120,SETTINGS_VIDEO_EDGE);
        SendMessageW(edge,CB_ADDSTRING,0,(LPARAM)L"1920 px");
        SendMessageW(edge,CB_ADDSTRING,0,(LPARAM)L"3840 px");
        SendMessageW(edge,CB_SETCURSEL,videoEdge==3840,0);
        HWND fps=control(w,L"COMBOBOX",L"",WS_TABSTOP|CBS_DROPDOWNLIST,309,403,143,120,SETTINGS_VIDEO_FPS);
        SendMessageW(fps,CB_ADDSTRING,0,(LPARAM)L"24 fps");
        SendMessageW(fps,CB_ADDSTRING,0,(LPARAM)L"30 fps");
        SendMessageW(fps,CB_ADDSTRING,0,(LPARAM)L"60 fps");
        SendMessageW(fps,CB_SETCURSEL,videoFps==24?0:videoFps==60?2:1,0);
        HWND sys=control(w,L"BUTTON",tr(L"录系统声音",L"System audio"),WS_TABSTOP|BS_AUTOCHECKBOX,20,447,180,23,SETTINGS_VIDEO_SYSTEM);
        HWND mic=control(w,L"BUTTON",tr(L"录麦克风",L"Microphone"),WS_TABSTOP|BS_AUTOCHECKBOX,215,447,205,23,SETTINGS_VIDEO_MIC);
        SendMessageW(sys,BM_SETCHECK,videoSystem?BST_CHECKED:BST_UNCHECKED,0);
        SendMessageW(mic,BM_SETCHECK,videoMic?BST_CHECKED:BST_UNCHECKED,0);
        control(w,L"BUTTON",L"GitHub",WS_TABSTOP|BS_PUSHBUTTON,20,500,95,31,SETTINGS_GITHUB);
        control(w,L"BUTTON",L"X",WS_TABSTOP|BS_PUSHBUTTON,125,500,58,31,SETTINGS_X);
        control(w,L"BUTTON",tr(L"打赏作者",L"Support author"),WS_TABSTOP|BS_PUSHBUTTON,193,500,103,31,SETTINGS_SUPPORT);
        control(w,L"BUTTON",tr(L"退出轻截",L"Quit LightCapture"),WS_TABSTOP|BS_PUSHBUTTON,305,500,147,31,SETTINGS_QUIT);
        return 0;
    case WM_COMMAND:
        switch(LOWORD(wp)){
        case SETTINGS_CAPTURE:begin_capture();break;
        case SETTINGS_VIDEO_EDGE:
        case SETTINGS_VIDEO_FPS:
            if(HIWORD(wp)==CBN_SELCHANGE){
                BOOL edge=LOWORD(wp)==SETTINGS_VIDEO_EDGE;
                LRESULT ix=SendMessageW((HWND)lp,CB_GETCURSEL,0,0);
                if(ix!=CB_ERR){
                    int *pref=edge?&videoEdge:&videoFps;
                    DWORD v=edge?(ix==1?3840:1920):(ix==0?24:ix==2?60:30);
                    if(put_setting(edge?L"VideoEdge":L"VideoFps",REG_DWORD,&v,sizeof v))*pref=(int)v;
                    else SendMessageW((HWND)lp,CB_SETCURSEL,edge?*pref==3840:*pref==24?0:*pref==60?2:1,0);
                }
            }
            break;
        case SETTINGS_VIDEO_SYSTEM:
        case SETTINGS_VIDEO_MIC:{
            BOOL sys=LOWORD(wp)==SETTINGS_VIDEO_SYSTEM;
            DWORD now=SendMessageW((HWND)lp,BM_GETCHECK,0,0)==BST_CHECKED;
            BOOL *pref=sys?&videoSystem:&videoMic;
            if(put_setting(sys?L"VideoSystem":L"VideoMic",REG_DWORD,&now,sizeof now))*pref=(BOOL)now;
            else SendMessageW((HWND)lp,BM_SETCHECK,*pref?BST_CHECKED:BST_UNCHECKED,0);
            break;}
        case SETTINGS_SAVE:{
            DWORD mode=SendMessageW(modeCheck,BM_GETCHECK,0,0)==BST_CHECKED;
            if(put_setting(L"SaveWithCopy",REG_DWORD,&mode,sizeof mode))saveWithCopy=mode;
            else {SendMessageW(modeCheck,BM_SETCHECK,saveWithCopy?BST_CHECKED:BST_UNCHECKED,0);error_text(tr(L"无法保存该设置。",L"Could not save this setting."));}
            break;}
        case SETTINGS_APPLY_KEY:change_hotkey();break;
        case SETTINGS_PAUSE:
            if(hotRegistered){UnregisterHotKey(w,HOTKEY);hotRegistered=FALSE;hotPaused=TRUE;}
            else {hotRegistered=bind_hotkey(hotMods,hotKey);hotPaused=FALSE;}
            key_status();break;
        case SETTINGS_LOGIN:{
            HWND controlHandle=(HWND)lp;
            BOOL checked=SendMessageW(controlHandle,BM_GETCHECK,0,0)==BST_CHECKED;
            if(!change_login(checked)){
                SendMessageW(controlHandle,BM_SETCHECK,checked?BST_UNCHECKED:BST_CHECKED,0);
                error_text(tr(L"无法更改登录启动设置。",L"Could not change startup settings."));
            }
            break;}
        case SETTINGS_CHOOSE:choose_dir();break;
        case SETTINGS_OPEN:{
            WCHAR path[MAX_PATH]={0};
            if(!output_path(path,MAX_PATH,TRUE)||(intptr_t)ShellExecuteW(w,L"open",path,NULL,NULL,SW_SHOWNORMAL)<=32)
                error_text(tr(L"无法打开截图目录。",L"Could not open the screenshots folder."));
            break;}
        case SETTINGS_SUPPORT:lc_show_support(w,isZh);break;
        case SETTINGS_GITHUB:ShellExecuteW(w,L"open",L"https://github.com/Jerryb0t",NULL,NULL,SW_SHOWNORMAL);break;
        case SETTINGS_X:ShellExecuteW(w,L"open",L"https://x.com/Jerryb0t",NULL,NULL,SW_SHOWNORMAL);break;
        case SETTINGS_QUIT:
            lc_hide_support();
            if(lc_video_active())stop_recording();
            if(IsWindow(longControl))finish_long(FALSE);
            if(IsWindow(overlay))DestroyWindow(overlay);
            DestroyWindow(w);break;
        }return 0;
    case WM_TIMER:
        if(wp==2&&lc_video_finished())stop_recording();
        return 0;
    case WM_HOTKEY:if(wp==HOTKEY)begin_capture();return 0;
    case WM_CLOSE:lc_hide_support();ShowWindow(w,SW_HIDE);return 0;
    case REOPEN:
        ShowWindow(w,IsIconic(w)?SW_RESTORE:SW_SHOW);
        SetForegroundWindow(w);return 0;
    case WM_DESTROY:
        if(hotRegistered)UnregisterHotKey(w,HOTKEY);
        PostQuitMessage(0);return 0;
    }
    return DefWindowProcW(w,m,wp,lp);
}
int WINAPI wWinMain(HINSTANCE h,HINSTANCE unused,PWSTR cmd,int show) {
    (void)unused;(void)show;
    instance=h;
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    HANDLE one=CreateMutexW(NULL,FALSE,IDENTITY);
    if(!one)return 1;
    if(GetLastError()==ERROR_ALREADY_EXISTS){
        BOOL opened=FALSE;
        for(int i=0;i<25&&!opened;i++){
            HWND other=FindWindowW(WCLS,NULL);
            if(other){
                DWORD owner=0;
                GetWindowThreadProcessId(other,&owner);
                if(owner)AllowSetForegroundWindow(owner);
                PostMessageW(other,REOPEN,0,0);opened=TRUE;
            }else Sleep(40);
        }
        CloseHandle(one);
        return opened?0:1;
    }
    HRESULT com=CoInitializeEx(NULL,COINIT_APARTMENTTHREADED|COINIT_DISABLE_OLE1DDE);
    if(FAILED(com)){CloseHandle(one);return 1;}
    GetModuleFileNameW(NULL,exe,MAX_PATH);
    load_settings();
    DWORD stored=0;
    if(read_setting(L"VideoFps",RRF_RT_REG_DWORD,&stored,sizeof stored)&&(stored==24||stored==30||stored==60))videoFps=(int)stored;
    if(read_setting(L"VideoEdge",RRF_RT_REG_DWORD,&stored,sizeof stored)&&(stored==1920||stored==3840))videoEdge=(int)stored;
    if(read_setting(L"VideoSystem",RRF_RT_REG_DWORD,&stored,sizeof stored))videoSystem=stored!=0;
    if(read_setting(L"VideoMic",RRF_RT_REG_DWORD,&stored,sizeof stored))videoMic=stored!=0;
    font=CreateFontW(-MulDiv(14,GetDpiForSystem(),96),0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,
      OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,CLEARTYPE_QUALITY,DEFAULT_PITCH,L"Segoe UI");
    if(!font)font=(HFONT)GetStockObject(DEFAULT_GUI_FONT);
    HICON icon=LoadIconW(instance,MAKEINTRESOURCEW(101));
    WNDCLASSEXW mainClass={.cbSize=sizeof(mainClass),.lpfnWndProc=main_proc,.hInstance=h,.hIcon=icon,
        .hCursor=LoadCursor(NULL,IDC_ARROW),.hbrBackground=(HBRUSH)(COLOR_WINDOW+1),.lpszClassName=WCLS,.hIconSm=icon};
    WNDCLASSEXW overlayClass={.cbSize=sizeof(overlayClass),.lpfnWndProc=overlay_proc,.hInstance=h,
        .hCursor=LoadCursor(NULL,IDC_CROSS),.lpszClassName=OCLS};
    if(!RegisterClassExW(&mainClass)||!RegisterClassExW(&overlayClass))goto shutdown;
    DWORD style=WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX;
    RECT size={0,0,MulDiv(472,GetDpiForSystem(),96),MulDiv(555,GetDpiForSystem(),96)};
    AdjustWindowRectExForDpi(&size,style,FALSE,WS_EX_APPWINDOW,GetDpiForSystem());
    mainWindow=CreateWindowExW(WS_EX_APPWINDOW,WCLS,tr(L"轻截",L"LightCapture"),style,CW_USEDEFAULT,CW_USEDEFAULT,
      width(size),height(size),NULL,NULL,h,NULL);
    if(!mainWindow)goto shutdown;
    hotRegistered=bind_hotkey(hotMods,hotKey);
    key_status();
    if(wcscmp(cmd,L"--background")!=0)ShowWindow(mainWindow,SW_SHOW);
    MSG m;
    while(GetMessageW(&m,NULL,0,0)>0){
        if(IsWindowVisible(mainWindow)&&GetAncestor(m.hwnd,GA_ROOT)==mainWindow&&IsDialogMessageW(mainWindow,&m))continue;
        TranslateMessage(&m);DispatchMessageW(&m);
    }
shutdown:
    DeleteObject(font);
    CoUninitialize();
    CloseHandle(one);
    return mainWindow?0:1;
}

static void *longStitch;
static Image longFrame;
static RECT longRegion;
static HWND longOutline[4];
static BOOL longEnterHotkey,longEscHotkey,longAtLimit,longSaving,longSawUnmatchedFrame;
static const WCHAR longClass[]=L"LightCaptureWindows.LongControl.v1";
static const WCHAR longOutlineClass[]=L"LightCaptureWindows.LongOutline.v1";
extern void *lc_stitch_new(void);
extern void lc_stitch_free(void *);
extern int lc_stitch_add(void *,const uint8_t *,int,int);
extern const uint8_t *lc_stitch_view(void *,int *,int *);

static BOOL acquire_live(Image *d,RECT region){
    HDC screen=GetDC(NULL);
    if(!screen)return FALSE;
    HDC scratch=CreateCompatibleDC(screen);
    HGDIOBJ old=scratch?SelectObject(scratch,d->bitmap):NULL;
    BOOL ok=old&&old!=HGDI_ERROR&&BitBlt(scratch,0,0,d->width,d->height,
        screen,region.left,region.top,SRCCOPY|CAPTUREBLT);
    if(old&&old!=HGDI_ERROR)SelectObject(scratch,old);
    if(scratch)DeleteDC(scratch);
    ReleaseDC(NULL,screen);
    GdiFlush();
    return ok;
}
static BOOL long_sample(void){
    if(!longStitch||!longFrame.bitmap)return FALSE;
    // Borders are wholly outside the crop, even if the OS cannot exclude them.
    if(!acquire_live(&longFrame,longRegion))return FALSE;
    int result=lc_stitch_add(longStitch,(const uint8_t*)longFrame.pixels,longFrame.width,longFrame.height);
    if(result==3)longSawUnmatchedFrame=TRUE;
    if(result==5){longAtLimit=TRUE;KillTimer(longControl,LONG_TIMER);}
    return result>=0&&result<=3;
}
static void unbind_long_keys(HWND w){
    if(longEnterHotkey)UnregisterHotKey(w,LONG_SAVE_HOTKEY);
    if(longEscHotkey)UnregisterHotKey(w,LONG_CANCEL_HOTKEY);
    longEnterHotkey=longEscHotkey=FALSE;
}
static BOOL bind_long_keys(HWND w){
    longEnterHotkey=RegisterHotKey(w,LONG_SAVE_HOTKEY,MOD_NOREPEAT,VK_RETURN);
    longEscHotkey=RegisterHotKey(w,LONG_CANCEL_HOTKEY,MOD_NOREPEAT,VK_ESCAPE);
    return longEnterHotkey&&longEscHotkey;
}
static void clear_long(void){
    for(unsigned i=0;i<4;i++){
        if(IsWindow(longOutline[i]))DestroyWindow(longOutline[i]);
        longOutline[i]=NULL;
    }
    if(longStitch)lc_stitch_free(longStitch);
    longStitch=NULL;longAtLimit=longSaving=longSawUnmatchedFrame=FALSE;
    image_free(&longFrame);
}
static void finish_long(BOOL save){
    if(!IsWindow(longControl)||longSaving)return;
    BOOL ok=TRUE,savedSingleWithUnmatched=FALSE;
    if(save){
        // Include the last visible position even if Enter beat the sampler.
        if(!longAtLimit)long_sample();
        Image out={0};
        out.pixels=(void*)lc_stitch_view(longStitch,&out.width,&out.height);
        WCHAR path[MAX_PATH]={0};
        ok=out.pixels&&output_named(path,MAX_PATH,FALSE,L"Long Screenshots",L"png")&&write_png_atomic(&out,path);
        if(!ok){
            // Don't consume the dialog's keyboard or sample it into a screenshot.
            longSaving=TRUE;
            KillTimer(longControl,LONG_TIMER);
            unbind_long_keys(longControl);
            error_text(tr(L"长截图保存失败。可更改目录后重试，当前内容不会丢失。",L"Could not save long screenshot. Change the folder and retry; capture retained."));
            longSaving=FALSE;
            if(!bind_long_keys(longControl)){
                DestroyWindow(longControl);
                error_text(tr(L"回车或 Esc 无法重新注册，已退出长截图。",L"Enter or Esc became unavailable, so long capture ended."));
            }else longAtLimit=TRUE; // Retain the already captured image unchanged for retry.
            return;
        }
        savedSingleWithUnmatched=longSawUnmatchedFrame&&out.height==longFrame.height;
    }
    DestroyWindow(longControl);
    if(savedSingleWithUnmatched)
        error_text(tr(L"没有找到可拼接的重叠内容，仅保存了第一屏。可以重新框选，放慢向下滚动。",
            L"No matching overlap was found. Only the first screen was saved. Try again and scroll down more slowly."));
}
static LRESULT CALLBACK long_proc(HWND w,UINT m,WPARAM wp,LPARAM lp){
    switch(m){
    case WM_HOTKEY:
        if(wp==LONG_SAVE_HOTKEY&&longEnterHotkey)finish_long(TRUE);
        else if(wp==LONG_CANCEL_HOTKEY&&longEscHotkey)finish_long(FALSE);
        return 0;
    case WM_TIMER:
        if(wp==LONG_TIMER)long_sample();
        return 0;
    case WM_CLOSE:finish_long(FALSE);return 0;
    case WM_DESTROY:
        KillTimer(w,LONG_TIMER);
        unbind_long_keys(w);
        longControl=NULL;clear_long();return 0;
    }
    return DefWindowProcW(w,m,wp,lp);
}
static LRESULT CALLBACK long_outline_proc(HWND w,UINT m,WPARAM wp,LPARAM lp){
    if(m==WM_NCHITTEST)return HTTRANSPARENT;
    if(m==WM_MOUSEACTIVATE)return MA_NOACTIVATE;
    if(m==WM_ERASEBKGND)return 1;
    if(m==WM_PAINT){
        PAINTSTRUCT ps;HDC dc=BeginPaint(w,&ps);
        paint_fill(dc,ps.rcPaint,accent);
        EndPaint(w,&ps);return 0;
    }
    return DefWindowProcW(w,m,wp,lp);
}
static void show_long_outline(RECT r,RECT desktop){
    LcOutlineRect strips[4];
    unsigned count=lc_outline_strips((LcOutlineRect){r.left,r.top,r.right,r.bottom},
        (LcOutlineRect){desktop.left,desktop.top,desktop.right,desktop.bottom},strips);
    WNDCLASSEXW cls={.cbSize=sizeof cls,.lpfnWndProc=long_outline_proc,.hInstance=instance,.lpszClassName=longOutlineClass};
    if(!RegisterClassExW(&cls)&&GetLastError()!=ERROR_CLASS_ALREADY_EXISTS)return;
    for(unsigned i=0;i<count;i++){
        LcOutlineRect a=strips[i];
        HWND w=CreateWindowExW(WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW|WS_EX_TOPMOST,
             longOutlineClass,NULL,WS_POPUP,a.left,a.top,a.right-a.left,a.bottom-a.top,NULL,NULL,instance,NULL);
        if(!w)continue;
        if(!SetLayeredWindowAttributes(w,0,255,LWA_ALPHA)){DestroyWindow(w);continue;}
        longOutline[i]=w;
        SetWindowDisplayAffinity(w,WDA_EXCLUDEFROMCAPTURE);
        ShowWindow(w,SW_SHOWNOACTIVATE);
    }
}
static void start_long(RECT r){
    if(width(r)<80||height(r)<100){
        error_text(tr(L"请至少选择 80 × 100 像素的内容区域。",L"Select a region of at least 80 × 100 pixels."));return;
    }
    WNDCLASSEXW c={.cbSize=sizeof(c),.lpfnWndProc=long_proc,.hInstance=instance,.lpszClassName=longClass};
    if(!RegisterClassExW(&c)&&GetLastError()!=ERROR_CLASS_ALREADY_EXISTS){
        error_text(tr(L"无法启动长截图。",L"Could not start long capture."));return;
    }
    longControl=CreateWindowExW(WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW,longClass,NULL,
      WS_POPUP,0,0,0,0,NULL,NULL,instance,NULL);
    if(!longControl||!bind_long_keys(longControl)||!SetTimer(longControl,LONG_TIMER,LONG_SAMPLE_MS,NULL)){
        if(IsWindow(longControl))DestroyWindow(longControl);
        error_text(tr(L"无法启用长截图按键。请关闭占用 Enter 或 Esc 的工具后重试。",
            L"Could not reserve the capture controls. Free Enter and Esc, then retry."));
        return;
    }
    // The controller is hidden for the entire session; only the crop outline is visible.
    longRegion=r;
    longStitch=lc_stitch_new();
    if(!longStitch||!image_allocate(&longFrame,width(r),height(r))){
        DestroyWindow(longControl);error_text(tr(L"无法开始长截图。",L"Could not start the long screenshot."));return;
    }
    RECT desktop=virtualScreen;
    // Leave the real page uncovered and give it back native focus. We don't
    // forward wheel events: precision touchpad gestures go through Windows to
    // the actual underlying application, just like when LightCapture is idle.
    DestroyWindow(overlay);
    POINT center={r.left+width(r)/2,r.top+height(r)/2};
    HWND target=GetAncestor(WindowFromPoint(center),GA_ROOT);
    if(!IsWindow(target)||target==mainWindow||target==GetDesktopWindow()||target==GetShellWindow()||IsIconic(target))
        target=preOverlayFocus;
    if(IsWindow(target)&&target!=mainWindow&&target!=GetDesktopWindow()&&target!=GetShellWindow()&&!IsIconic(target))
        SetForegroundWindow(target);
    DwmFlush();
    if(!long_sample()){
        DestroyWindow(longControl);error_text(tr(L"无法开始长截图。",L"Could not start the long screenshot."));return;
    }
    show_long_outline(r,desktop);
}

static const WCHAR recordClass[]=L"LightCaptureWindows.RecordingControl.v1";
static void stop_recording(void){
    if(!lc_video_active())return;
    KillTimer(mainWindow,2);
    WCHAR why[1024]={0};
    BOOL ok=lc_video_stop(why,1024);
    if(IsWindow(recControl))DestroyWindow(recControl);
    recControl=NULL;
    SetWindowTextW(captureButton,tr(L"开始截图",L"Start capture"));
    if(!ok)error_text(why[0]?why:tr(L"无法保存录屏。",L"Could not save the recording."));
}
static LRESULT CALLBACK rec_proc(HWND w,UINT m,WPARAM wp,LPARAM lp){
    switch(m){
    case WM_CREATE:
        control(w,L"BUTTON",tr(L"停止并保存录屏",L"Stop and save recording"),WS_TABSTOP|BS_PUSHBUTTON,8,8,172,30,1);
        return 0;
    case WM_COMMAND:if(LOWORD(wp)==1)stop_recording();return 0;
    case WM_CLOSE:stop_recording();return 0;
    case WM_DESTROY:recControl=NULL;return 0;
    }
    return DefWindowProcW(w,m,wp,lp);
}
static void start_recording(RECT r){
    if(width(r)<16||height(r)<16){
        error_text(tr(L"录屏区域太小。",L"The recording region is too small."));return;
    }
    WCHAR path[MAX_PATH]={0}, why[1024]={0};
    if(!output_named(path,MAX_PATH,FALSE,L"Recordings",L"mp4")){
        error_text(tr(L"无法创建录屏目录。",L"Could not create the recordings folder."));return;
    }
    if(IsWindow(overlay))DestroyWindow(overlay);
    if(IsWindowVisible(mainWindow))ShowWindow(mainWindow,SW_HIDE);
    DwmFlush();
    if(!lc_video_start(r,videoEdge,videoFps,videoSystem,videoMic,path,why,1024)){
        error_text(why[0]?why:tr(L"无法开始录屏。",L"Could not start the recording."));return;
    }
    SetWindowTextW(captureButton,tr(L"停止并保存录屏",L"Stop and save recording"));
    SetTimer(mainWindow,2,500,NULL);
    WNDCLASSEXW c={.cbSize=sizeof(c),.lpfnWndProc=rec_proc,.hInstance=instance,
      .hCursor=LoadCursor(NULL,IDC_ARROW),.hbrBackground=(HBRUSH)(COLOR_WINDOW+1),.lpszClassName=recordClass};
    if(!RegisterClassExW(&c)&&GetLastError()!=ERROR_CLASS_ALREADY_EXISTS)return;
    MONITORINFO mi={.cbSize=sizeof mi};
    GetMonitorInfoW(MonitorFromRect(&r,MONITOR_DEFAULTTONEAREST),&mi);
    int w=MulDiv(190,GetDpiForSystem(),96),h=MulDiv(75,GetDpiForSystem(),96);
    RECT area=mi.rcWork;
    POINT positions[]={{r.right+6,r.top},{r.left-w-6,r.top},{r.left,r.bottom+6},{r.left,r.top-h-6}};
    RECT hit;
    int xpos=area.right-w,ypos=area.top;
    BOOL outside=FALSE;
    for(unsigned i=0;i<sizeof positions/sizeof positions[0];i++){
        int x=max(area.left,min(positions[i].x,area.right-w));
        int y=max(area.top,min(positions[i].y,area.bottom-h));
        if(!IntersectRect(&hit,&r,&(RECT){x,y,x+w,y+h})){xpos=x;ypos=y;outside=TRUE;break;}
    }
    recControl=CreateWindowExW(WS_EX_TOOLWINDOW|WS_EX_TOPMOST|WS_EX_NOACTIVATE,recordClass,
      tr(L"轻截 · 录屏",L"LightCapture · Recording"),WS_CAPTION|WS_SYSMENU|WS_POPUP,xpos,ypos,w,h,NULL,NULL,instance,NULL);
    if(recControl){
        SetWindowDisplayAffinity(recControl,WDA_EXCLUDEFROMCAPTURE);
        if(outside)ShowWindow(recControl,SW_SHOWNOACTIVATE);
        // The full-screen case never displays this control even on OSes that report
        // exclusion support, avoiding synthetic black boxes in the desktop capture.
    }
}
