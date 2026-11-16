#define UNICODE
#define _UNICODE
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <wincodec.h>
#include <stdlib.h>
#include <stdint.h>

typedef struct {
    BOOL zh;
    BYTE *pixels;
    UINT width, height;
} SupportState;

static HWND support_window;
static const wchar_t support_class[] = L"LightCaptureWindows.Support.v1";
static const int first_channel=201;

static void release_picture(SupportState *s)
{
    if(!s)return;
    free(s->pixels);
    s->pixels=NULL;
    s->width=s->height=0;
}

static BOOL load_picture(SupportState *s, int id)
{
    HMODULE module=GetModuleHandleW(NULL);
    HRSRC found=FindResourceW(module,MAKEINTRESOURCEW(id),RT_RCDATA);
    HGLOBAL resource=found?LoadResource(module,found):NULL;
    BYTE *data=resource?(BYTE*)LockResource(resource):NULL;
    DWORD bytes=found?SizeofResource(module,found):0;
    if(!data||!bytes)return FALSE;

    IWICImagingFactory *factory=NULL;
    IWICBitmapDecoder *decoder=NULL;
    IWICBitmapFrameDecode *frame=NULL;
    IWICStream *stream=NULL;
    IWICFormatConverter *convert=NULL;
    UINT w=0,h=0;
    BYTE *pixels=NULL;
    HRESULT hr=CoCreateInstance(&CLSID_WICImagingFactory,NULL,CLSCTX_INPROC_SERVER,
                                 &IID_IWICImagingFactory,(void**)&factory);
    if(SUCCEEDED(hr))hr=IWICImagingFactory_CreateStream(factory,&stream);
    if(SUCCEEDED(hr))hr=IWICStream_InitializeFromMemory(stream,data,bytes);
    if(SUCCEEDED(hr))hr=IWICImagingFactory_CreateDecoderFromStream(factory,(IStream*)stream,NULL,WICDecodeMetadataCacheOnDemand,&decoder);
    if(SUCCEEDED(hr))hr=IWICBitmapDecoder_GetFrame(decoder,0,&frame);
    if(SUCCEEDED(hr))hr=IWICBitmapFrameDecode_GetSize(frame,&w,&h);
    if(SUCCEEDED(hr)&&(!w||w!=h||w>1024))hr=E_FAIL;
    if(SUCCEEDED(hr))hr=IWICImagingFactory_CreateFormatConverter(factory,&convert);
    if(SUCCEEDED(hr))hr=IWICFormatConverter_Initialize(convert,(IWICBitmapSource*)frame,&GUID_WICPixelFormat32bppBGR,
                                                       WICBitmapDitherTypeNone,NULL,0.0,WICBitmapPaletteTypeCustom);
    if(SUCCEEDED(hr)){
        pixels=malloc((size_t)w*h*4u);
        hr=pixels?IWICFormatConverter_CopyPixels(convert,NULL,w*4u,w*h*4u,pixels):E_OUTOFMEMORY;
    }
    if(convert)IWICFormatConverter_Release(convert);
    if(frame)IWICBitmapFrameDecode_Release(frame);
    if(decoder)IWICBitmapDecoder_Release(decoder);
    if(stream)IWICStream_Release(stream);
    if(factory)IWICImagingFactory_Release(factory);
    if(FAILED(hr)){free(pixels);return FALSE;}
    release_picture(s);
    s->pixels=pixels;
    s->width=w;
    s->height=h;
    return TRUE;
}

static int scale(HWND w,int logical)
{
    UINT dpi=GetDpiForWindow(w);
    return MulDiv(logical,dpi?dpi:96,96);
}

static void control(HWND w,const wchar_t *cls,const wchar_t *label,int x,int y,int width,int height,int command)
{
    HWND c=CreateWindowExW(0,cls,label,WS_VISIBLE|WS_CHILD|(command?(BS_PUSHBUTTON|WS_TABSTOP):SS_NOPREFIX),
                           scale(w,x),scale(w,y),scale(w,width),scale(w,height),w,
                           (HMENU)(INT_PTR)command,GetModuleHandleW(NULL),NULL);
    if(c)SendMessageW(c,WM_SETFONT,(WPARAM)GetStockObject(DEFAULT_GUI_FONT),TRUE);
}

static LRESULT CALLBACK support_proc(HWND w,UINT m,WPARAM wp,LPARAM lp)
{
    SupportState *s=(SupportState*)GetWindowLongPtrW(w,GWLP_USERDATA);
    switch(m){
        case WM_CREATE:{
            s=calloc(1,sizeof(*s));
            if(!s)return -1;
            s->zh=(BOOL)(INT_PTR)((CREATESTRUCTW*)lp)->lpCreateParams;
            SetWindowLongPtrW(w,GWLP_USERDATA,(LONG_PTR)s);
            control(w,L"STATIC",s->zh?L"打赏完全自愿。请在支付 App 内核对收款人。":
                    L"Support is optional. Verify the recipient in your payment app.",17,15,395,30,0);
            control(w,L"BUTTON",s->zh?L"微信支付":L"WeChat Pay",17,54,113,30,first_channel);
            control(w,L"BUTTON",s->zh?L"支付宝":L"Alipay",141,54,113,30,first_channel+1);
            control(w,L"BUTTON",L"OKX Pay",265,54,113,30,first_channel+2);
            control(w,L"BUTTON",s->zh?L"关闭":L"Close",150,372,109,30,IDCANCEL);
            return 0;
        }
        case WM_COMMAND:{
            int cmd=LOWORD(wp);
            if(cmd==IDCANCEL){DestroyWindow(w);return 0;}
            if(s&&cmd>=first_channel&&cmd<first_channel+3){
                if(!load_picture(s,cmd)){
                    release_picture(s);
                    MessageBoxW(w,s->zh?L"无法显示该收款码。":L"This QR code could not be displayed.",
                                L"LightCapture",MB_OK|MB_ICONWARNING);
                }
                InvalidateRect(w,NULL,TRUE);
                return 0;
            }
            break;
        }
        case WM_PAINT:{
            PAINTSTRUCT paint;
            HDC dc=BeginPaint(w,&paint);
            RECT rc;
            GetClientRect(w,&rc);
            int side=scale(w,250),x=(rc.right-side)/2,y=scale(w,101);
            if(s&&s->pixels){
                BITMAPINFO bi={0};
                bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
                bi.bmiHeader.biWidth=(LONG)s->width;
                bi.bmiHeader.biHeight=-(LONG)s->height;
                bi.bmiHeader.biPlanes=1;
                bi.bmiHeader.biBitCount=32;
                SetStretchBltMode(dc,COLORONCOLOR);
                StretchDIBits(dc,x,y,side,side,0,0,s->width,s->height,s->pixels,&bi,DIB_RGB_COLORS,SRCCOPY);
            }else if(s){
                RECT text={x,y+scale(w,70),x+side,y+side};
                SetBkMode(dc,TRANSPARENT);
                SelectObject(dc,GetStockObject(DEFAULT_GUI_FONT));
                DrawTextW(dc,s->zh?L"选择一个渠道后才显示收款码。":L"Select a method to show its QR code.",
                          -1,&text,DT_CENTER|DT_WORDBREAK|DT_NOPREFIX);
            }
            EndPaint(w,&paint);
            return 0;
        }
        case WM_CLOSE:DestroyWindow(w);return 0;
        case WM_NCDESTROY:
            release_picture(s);free(s);
            SetWindowLongPtrW(w,GWLP_USERDATA,0);
            if(w==support_window)support_window=NULL;
            break;
    }
    return DefWindowProcW(w,m,wp,lp);
}

void lc_show_support(HWND owner, BOOL zh)
{
    if(IsWindow(support_window)){
        ShowWindow(support_window,SW_SHOW);
        SetForegroundWindow(support_window);
        return;
    }
    HINSTANCE module=GetModuleHandleW(NULL);
    WNDCLASSW klass={0};
    klass.hInstance=module;
    klass.lpszClassName=support_class;
    klass.lpfnWndProc=support_proc;
    klass.hCursor=LoadCursorW(NULL,IDC_ARROW);
    klass.hIcon=LoadIconW(module,MAKEINTRESOURCEW(101));
    klass.hbrBackground=(HBRUSH)(COLOR_WINDOW+1);
    if(!RegisterClassW(&klass)&&GetLastError()!=ERROR_CLASS_ALREADY_EXISTS)return;
    DWORD style=WS_POPUP|WS_CAPTION|WS_SYSMENU;
    UINT dpi=GetDpiForWindow(owner);
    if(!dpi)dpi=96;
    RECT size={0,0,MulDiv(410,dpi,96),MulDiv(417,dpi,96)};
    AdjustWindowRectExForDpi(&size,style,FALSE,WS_EX_DLGMODALFRAME,dpi);
    RECT bounds={0};
    GetWindowRect(owner,&bounds);
    int width=size.right-size.left,height=size.bottom-size.top;
    support_window=CreateWindowExW(WS_EX_DLGMODALFRAME,support_class,zh?L"支持作者":L"Support the author",
                                   style,bounds.left+(bounds.right-bounds.left-width)/2,
                                   bounds.top+(bounds.bottom-bounds.top-height)/2,width,height,
                                   owner,NULL,module,(LPVOID)(INT_PTR)zh);
    if(support_window)ShowWindow(support_window,SW_SHOW);
}

void lc_hide_support(void)
{
    if(IsWindow(support_window))DestroyWindow(support_window);
}
