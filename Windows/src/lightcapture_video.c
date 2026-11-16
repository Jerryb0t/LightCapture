#define COBJMACROS
#include "lightcapture_video.h"
#include "lc_nv12.h"
#include <objbase.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define RATE 48000
#define TICKS 10000000
#define AUDIO_SLICE 480
#define AUDIO_RING_FRAMES (RATE * 2)
#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif
#define CHECK(e) do { result=(e); if (FAILED(result)) goto done; } while (0)
#define RELEASE(t,p) do { if (p) { t##_Release(p); (p)=NULL; } } while (0)

typedef struct {
    IAudioClient *client;
    IAudioCaptureClient *capture;
    int running;
    int64_t next;
} Audio;

typedef struct {
    HANDLE thread, stop, ready;
    RECT region;
    int max_edge, fps, system_audio, mic;
    const wchar_t *stage;
    wchar_t *destination, *destination_stage;
    HRESULT start_status, status;
    BOOL staged_playable;
    const wchar_t *action;
} Run;

static Run *run;

/* Values from Windows SDK audioclient.h and mmdeviceapi.h. Keep private copies
 * so MinGW targets without the corresponding UUID import symbols also link. */
static const GUID LC_MmdevClass={0xbcde0395,0xe52f,0x467c,{0x8e,0x3d,0xc4,0x57,0x92,0x91,0x69,0x2e}};
static const GUID LC_MmdevEnumerator={0xa95664d2,0x9614,0x4f35,{0xa7,0x46,0xde,0x8d,0xb6,0x36,0x17,0xe6}};
static const GUID LC_AudioClient={0x1cb9ad4c,0xdbfa,0x4c32,{0xb1,0x78,0xc2,0xf5,0x68,0xa7,0x03,0xb2}};
static const GUID LC_AudioCaptureClient={0xc8adbd64,0xe71e,0x48a0,{0xa4,0xde,0x18,0x5c,0x39,0x5c,0xd3,0x17}};

static void error_text(wchar_t *out, size_t cap, const wchar_t *action, HRESULT hr)
{
    if (!out || !cap) return;
    if (SUCCEEDED(hr)) { out[0]=0; return; }
    _snwprintf(out, cap-1, L"%ls (0x%08lX)", action, (unsigned long)(uint32_t)hr);
    out[cap-1]=0;
}

static HRESULT audio_open(Audio *a, IMMDeviceEnumerator *devices, BOOL loopback)
{
    HRESULT result;
    IMMDevice *device=NULL;
    WAVEFORMATEX pcm={0};
    pcm.wFormatTag=WAVE_FORMAT_PCM;
    pcm.nChannels=2;
    pcm.nSamplesPerSec=RATE;
    pcm.wBitsPerSample=16;
    pcm.nBlockAlign=4;
    pcm.nAvgBytesPerSec=RATE*4;
    CHECK(IMMDeviceEnumerator_GetDefaultAudioEndpoint(devices,loopback ? eRender : eCapture,eConsole,&device));
    CHECK(IMMDevice_Activate(device,&LC_AudioClient,CLSCTX_INPROC_SERVER,NULL,(void **)&a->client));
    CHECK(IAudioClient_Initialize(a->client,AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY |
        (loopback ? AUDCLNT_STREAMFLAGS_LOOPBACK : 0),2000000,0,&pcm,NULL));
    CHECK(IAudioClient_GetService(a->client,&LC_AudioCaptureClient,(void **)&a->capture));
done:
    RELEASE(IMMDevice,device);
    return result;
}

static HRESULT audio_begin(Audio *a)
{
    if (!a->client) return S_OK;
    HRESULT hr=IAudioClient_Start(a->client);
    a->running=SUCCEEDED(hr);
    return hr;
}

static void audio_close(Audio *a)
{
    if (a->running) IAudioClient_Stop(a->client);
    RELEASE(IAudioCaptureClient,a->capture);
    RELEASE(IAudioClient,a->client);
}

static int64_t qpc_time(int64_t frequency)
{
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    return (now.QuadPart/frequency)*TICKS + (now.QuadPart%frequency)*TICKS/frequency;
}

/* A fixed-size accumulator on one QPC timeline; the two endpoint packets can
 * arrive in different orders. Timestamp error uses a local continuity estimate. */
static HRESULT audio_pull(Audio *a, int32_t *ring, int64_t first, int64_t start, int64_t now)
{
    if (!a->capture) return S_OK;
    for (int packet=0;packet<256;packet++) {
        UINT32 waiting=0,count=0;
        DWORD flags=0;
        BYTE *data=NULL;
        UINT64 time=0;
        HRESULT hr=IAudioCaptureClient_GetNextPacketSize(a->capture,&waiting);
        if (FAILED(hr) || !waiting) return hr;
        hr=IAudioCaptureClient_GetBuffer(a->capture,&data,&count,&flags,NULL,&time);
        if (FAILED(hr)) return hr;
        if (hr==AUDCLNT_S_BUFFER_EMPTY || !count) return S_OK;
        int64_t at;
        if ((flags&AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) || !time) {
            at=a->next ? a->next : (now-start)*RATE/TICKS-(int64_t)count;
        } else {
            at=((int64_t)time-start)*RATE/TICKS;
            /* Snap small scheduling/resampler jitter, not real gaps. */
            if (a->next && at-a->next < RATE/200 && at-a->next > -RATE/200) at=a->next;
        }
        a->next=at+count;
        if (!(flags&AUDCLNT_BUFFERFLAGS_SILENT) && data) {
            const int16_t *s=(const int16_t *)data;
            for (UINT32 i=0;i<count;i++) {
                int64_t pos=at+i;
                if (pos < first || pos-first >= AUDIO_RING_FRAMES) continue;
                size_t index=(size_t)(pos%AUDIO_RING_FRAMES)*2;
                ring[index]+=s[2*i];
                ring[index+1]+=s[2*i+1];
            }
        }
        hr=IAudioCaptureClient_ReleaseBuffer(a->capture,count);
        if (FAILED(hr)) return hr;
    }
    return S_OK;
}

static HRESULT stream_video(IMFSinkWriter *writer, int w, int h, int fps, DWORD *index)
{
    IMFMediaType *out=NULL,*in=NULL;
    HRESULT result;
    const GUID *size=&MF_MT_FRAME_SIZE,*fr=&MF_MT_FRAME_RATE,*ar=&MF_MT_PIXEL_ASPECT_RATIO;
    const UINT64 wh=((UINT64)(uint32_t)w<<32)|(UINT32)h;
    const UINT64 rate=((UINT64)(uint32_t)fps<<32)|1;
    const UINT64 square=((UINT64)1<<32)|1;
    DWORD bitrate=(DWORD)((uint64_t)w*h*fps/7);
    if (bitrate<1000000) bitrate=1000000;
    if (bitrate>40000000) bitrate=40000000;

    CHECK(MFCreateMediaType(&out));
    CHECK(IMFMediaType_SetGUID(out,&MF_MT_MAJOR_TYPE,&MFMediaType_Video));
    CHECK(IMFMediaType_SetGUID(out,&MF_MT_SUBTYPE,&MFVideoFormat_H264));
    CHECK(IMFMediaType_SetUINT32(out,&MF_MT_AVG_BITRATE,bitrate));
    CHECK(IMFMediaType_SetUINT32(out,&MF_MT_INTERLACE_MODE,MFVideoInterlace_Progressive));
    CHECK(IMFMediaType_SetUINT64(out,size,wh));
    CHECK(IMFMediaType_SetUINT64(out,fr,rate));
    CHECK(IMFMediaType_SetUINT64(out,ar,square));
    CHECK(IMFMediaType_SetUINT32(out,&MF_MT_YUV_MATRIX,MFVideoTransferMatrix_BT709));
    CHECK(IMFMediaType_SetUINT32(out,&MF_MT_VIDEO_NOMINAL_RANGE,MFNominalRange_16_235));
    CHECK(IMFSinkWriter_AddStream(writer,out,index));

    CHECK(MFCreateMediaType(&in));
    CHECK(IMFMediaType_SetGUID(in,&MF_MT_MAJOR_TYPE,&MFMediaType_Video));
    CHECK(IMFMediaType_SetGUID(in,&MF_MT_SUBTYPE,&MFVideoFormat_NV12));
    CHECK(IMFMediaType_SetUINT32(in,&MF_MT_DEFAULT_STRIDE,(UINT32)w));
    CHECK(IMFMediaType_SetUINT32(in,&MF_MT_YUV_MATRIX,MFVideoTransferMatrix_BT709));
    CHECK(IMFMediaType_SetUINT32(in,&MF_MT_VIDEO_NOMINAL_RANGE,MFNominalRange_16_235));
    CHECK(IMFMediaType_SetUINT32(in,&MF_MT_INTERLACE_MODE,MFVideoInterlace_Progressive));
    CHECK(IMFMediaType_SetUINT64(in,size,wh));
    CHECK(IMFMediaType_SetUINT64(in,fr,rate));
    CHECK(IMFMediaType_SetUINT64(in,ar,square));
    CHECK(IMFSinkWriter_SetInputMediaType(writer,*index,in,NULL));
done:
    RELEASE(IMFMediaType,in);
    RELEASE(IMFMediaType,out);
    return result;
}

static HRESULT stream_audio(IMFSinkWriter *writer, DWORD *index)
{
    IMFMediaType *out=NULL,*in=NULL;
    HRESULT result;
    CHECK(MFCreateMediaType(&out));
    CHECK(IMFMediaType_SetGUID(out,&MF_MT_MAJOR_TYPE,&MFMediaType_Audio));
    CHECK(IMFMediaType_SetGUID(out,&MF_MT_SUBTYPE,&MFAudioFormat_AAC));
    CHECK(IMFMediaType_SetUINT32(out,&MF_MT_AUDIO_NUM_CHANNELS,2));
    CHECK(IMFMediaType_SetUINT32(out,&MF_MT_AUDIO_SAMPLES_PER_SECOND,RATE));
    CHECK(IMFMediaType_SetUINT32(out,&MF_MT_AUDIO_BITS_PER_SAMPLE,16));
    CHECK(IMFMediaType_SetUINT32(out,&MF_MT_AUDIO_AVG_BYTES_PER_SECOND,16000));
    CHECK(IMFMediaType_SetUINT32(out,&MF_MT_AAC_PAYLOAD_TYPE,0));
    CHECK(IMFMediaType_SetUINT32(out,&MF_MT_AAC_AUDIO_PROFILE_LEVEL_INDICATION,0x29));
    CHECK(IMFSinkWriter_AddStream(writer,out,index));
    CHECK(MFCreateMediaType(&in));
    CHECK(IMFMediaType_SetGUID(in,&MF_MT_MAJOR_TYPE,&MFMediaType_Audio));
    CHECK(IMFMediaType_SetGUID(in,&MF_MT_SUBTYPE,&MFAudioFormat_PCM));
    CHECK(IMFMediaType_SetUINT32(in,&MF_MT_AUDIO_NUM_CHANNELS,2));
    CHECK(IMFMediaType_SetUINT32(in,&MF_MT_AUDIO_SAMPLES_PER_SECOND,RATE));
    CHECK(IMFMediaType_SetUINT32(in,&MF_MT_AUDIO_BITS_PER_SAMPLE,16));
    CHECK(IMFMediaType_SetUINT32(in,&MF_MT_AUDIO_BLOCK_ALIGNMENT,4));
    CHECK(IMFMediaType_SetUINT32(in,&MF_MT_AUDIO_AVG_BYTES_PER_SECOND,RATE*4));
    CHECK(IMFSinkWriter_SetInputMediaType(writer,*index,in,NULL));
done:
    RELEASE(IMFMediaType,in);
    RELEASE(IMFMediaType,out);
    return result;
}

static HRESULT sample(IMFSinkWriter *writer,DWORD index,const void *data,DWORD bytes,
                      LONGLONG time,LONGLONG duration,int w,int h)
{
    IMFMediaBuffer *buffer=NULL;
    IMFSample *s=NULL;
    BYTE *dest=NULL;
    HRESULT result;
    CHECK(MFCreateMemoryBuffer(bytes,&buffer));
    CHECK(IMFMediaBuffer_Lock(buffer,&dest,NULL,NULL));
    if (w) lc_bgra_to_nv12(data,dest,w,h);
    else memcpy(dest,data,bytes);
    CHECK(IMFMediaBuffer_Unlock(buffer));
    CHECK(IMFMediaBuffer_SetCurrentLength(buffer,bytes));
    CHECK(MFCreateSample(&s));
    CHECK(IMFSample_AddBuffer(s,buffer));
    CHECK(IMFSample_SetSampleTime(s,time));
    CHECK(IMFSample_SetSampleDuration(s,duration));
    CHECK(IMFSinkWriter_WriteSample(writer,index,s));
done:
    RELEASE(IMFSample,s);
    RELEASE(IMFMediaBuffer,buffer);
    return result;
}

static HRESULT audio_flush(IMFSinkWriter *writer,DWORD idx,int32_t *ring,int64_t *first,
                           int64_t through)
{
    int16_t samples[AUDIO_SLICE*2];
    while (through>*first) {
        int64_t start=*first, remaining=through-start;
        int n=(int)(remaining>AUDIO_SLICE ? AUDIO_SLICE : remaining);
        for (int i=0;i<n;i++) {
            size_t at=(size_t)((start+i)%AUDIO_RING_FRAMES)*2;
            for (int c=0;c<2;c++) {
                int32_t v=ring[at+c];
                samples[2*i+c]=v > INT16_MAX ? INT16_MAX : v < INT16_MIN ? INT16_MIN : (int16_t)v;
                ring[at+c]=0;
            }
        }
        HRESULT hr=sample(writer,idx,samples,(DWORD)n*4,start*TICKS/RATE,
                           (start+n)*TICKS/RATE-start*TICKS/RATE,0,0);
        if (FAILED(hr)) return hr;
        *first+=n;
    }
    return S_OK;
}

static HRESULT capture_video_frame(HDC desktop,HDC dest,RECT r,int w,int h)
{
    const int iw=r.right-r.left,ih=r.bottom-r.top;
    BOOL ok;
    if (iw==w && ih==h) ok=BitBlt(dest,0,0,w,h,desktop,r.left,r.top,SRCCOPY|CAPTUREBLT);
    else ok=StretchBlt(dest,0,0,w,h,desktop,r.left,r.top,iw,ih,SRCCOPY|CAPTUREBLT);
    if (!ok || !GdiFlush()) return E_FAIL;
    return S_OK;
}

static DWORD WINAPI record(void *arg)
{
    Run *v=(Run *)arg;
    BOOL com=FALSE,mf=FALSE,announced=FALSE;
    BOOL sound=v->system_audio || v->mic;
    HDC desktop=NULL,image=NULL;
    HBITMAP bitmap=NULL;
    HGDIOBJ previous=NULL;
    void *pixels=NULL;
    IMFAttributes *attrs=NULL;
    IMFSinkWriter *writer=NULL;
    IMMDeviceEnumerator *devices=NULL;
    Audio system={0},microphone={0};
    int32_t *ring=NULL;
    DWORD vid=0,aud=0;
    HANDLE ticker=NULL;
    LARGE_INTEGER f;
    HRESULT result;
    int64_t t0=0,first_audio=0,frame=0;
    const int iw=v->region.right-v->region.left,ih=v->region.bottom-v->region.top;
    const int edge=iw>ih ? iw : ih;
    int w=iw,h=ih;
    if (edge>v->max_edge) {
        w=(int)((int64_t)iw*v->max_edge/edge);
        h=(int)((int64_t)ih*v->max_edge/edge);
    }
    w&=~1;
    h&=~1;
    v->action=L"Invalid recording size";
    CHECK(w>=16 && h>=16 ? S_OK : E_INVALIDARG);

    v->action=L"Initialize Windows Media Foundation";
    CHECK(CoInitializeEx(NULL,COINIT_MULTITHREADED));
    com=TRUE;
    CHECK(MFStartup(MF_VERSION,MFSTARTUP_LITE));
    mf=TRUE;
    if (sound) {
        v->action=L"Open audio endpoints";
        CHECK(CoCreateInstance(&LC_MmdevClass,NULL,CLSCTX_INPROC_SERVER,
                               &LC_MmdevEnumerator,(void **)&devices));
        if (v->system_audio) {
            v->action=L"Open system audio loopback";
            CHECK(audio_open(&system,devices,TRUE));
        }
        if (v->mic) {
            v->action=L"Open microphone";
            CHECK(audio_open(&microphone,devices,FALSE));
        }
        ring=calloc(AUDIO_RING_FRAMES*2,sizeof(*ring));
        CHECK(ring ? S_OK : E_OUTOFMEMORY);
    }
    v->action=L"Open desktop capture";
    desktop=GetDC(NULL);
    CHECK(desktop ? S_OK : E_FAIL);
    image=CreateCompatibleDC(desktop);
    CHECK(image ? S_OK : E_OUTOFMEMORY);
    BITMAPINFO bmi={0};
    bmi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth=w;
    bmi.bmiHeader.biHeight=h; /* GDI bottom-up input; converter writes top-down NV12. */
    bmi.bmiHeader.biPlanes=1;
    bmi.bmiHeader.biBitCount=32;
    bmi.bmiHeader.biCompression=BI_RGB;
    bitmap=CreateDIBSection(desktop,&bmi,DIB_RGB_COLORS,&pixels,NULL,0);
    CHECK(bitmap && pixels ? S_OK : E_OUTOFMEMORY);
    previous=SelectObject(image,bitmap);
    CHECK(previous && previous!=HGDI_ERROR ? S_OK : E_FAIL);
    SetStretchBltMode(image,COLORONCOLOR);

    v->action=L"Create H.264 / MP4 writer";
    CHECK(MFCreateAttributes(&attrs,1));
    CHECK(IMFAttributes_SetUINT32(attrs,&MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS,TRUE));
    CHECK(MFCreateSinkWriterFromURL(v->stage,NULL,attrs,&writer));
    CHECK(stream_video(writer,w,h,v->fps,&vid));
    if (sound) {
        v->action=L"Configure AAC audio";
        CHECK(stream_audio(writer,&aud));
    }
    v->action=L"Start MP4 encoder";
    CHECK(IMFSinkWriter_BeginWriting(writer));
    CHECK(QueryPerformanceFrequency(&f) && f.QuadPart > 0 ? S_OK : E_FAIL);
    t0=qpc_time(f.QuadPart);
    if (v->system_audio) {
        v->action=L"Start system audio";
        CHECK(audio_begin(&system));
    }
    if (v->mic) {
        v->action=L"Start microphone";
        CHECK(audio_begin(&microphone));
    }
    v->action=L"Encode the first screen frame";
    CHECK(capture_video_frame(desktop,image,v->region,w,h));
    CHECK(sample(writer,vid,pixels,(DWORD)w*h*3/2,0,TICKS/v->fps,w,h));
    frame=1;
    v->start_status=S_OK;
    announced=TRUE;
    SetEvent(v->ready);

    /* High-resolution wakeups only while recording, without changing global
     * timer resolution. Unsupported systems use a short timed wait. */
    ticker=CreateWaitableTimerExW(NULL,NULL,CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
                                  TIMER_MODIFY_STATE|SYNCHRONIZE);
    if (ticker) {
        LARGE_INTEGER due;
        due.QuadPart=-40000; /* 4 ms in 100ns units */
        if (!SetWaitableTimer(ticker,&due,4,NULL,NULL,FALSE)) {
            CloseHandle(ticker);
            ticker=NULL;
        }
    }
    HANDLE events[2]={v->stop,ticker};
    /* Fixed QPC schedule, not a Windows timer tick count. If capture falls
     * behind, keep timestamps moving instead of dumping stale duplicates. */
    for (;;) {
        DWORD wait=ticker ? WaitForMultipleObjects(2,events,FALSE,INFINITE) :
                            WaitForSingleObject(v->stop,1);
        CHECK(wait!=WAIT_FAILED ? S_OK : HRESULT_FROM_WIN32(GetLastError()));
        int64_t now=qpc_time(f.QuadPart);
        int64_t elapsed=now-t0;
        if (sound) {
            v->action=L"Read recording audio";
            CHECK(audio_pull(&system,ring,first_audio,t0,now));
            CHECK(audio_pull(&microphone,ring,first_audio,t0,now));
            int64_t audio_now=elapsed*RATE/TICKS;
            /* 50 ms packet interleave allowance before committing silence. */
            int64_t through=wait==WAIT_OBJECT_0 ? audio_now : audio_now-RATE/20;
            if (through>first_audio &&
                (wait==WAIT_OBJECT_0 || through-first_audio>=AUDIO_SLICE)) {
                if (wait!=WAIT_OBJECT_0) through-= (through-first_audio)%AUDIO_SLICE;
                v->action=L"Encode AAC audio";
                CHECK(audio_flush(writer,aud,ring,&first_audio,through));
            }
        }
        if (wait==WAIT_OBJECT_0) break;
        int64_t ts=frame*TICKS/v->fps;
        if (elapsed>=ts) {
            int64_t expected=elapsed*v->fps/TICKS;
            if (expected>frame+1) {
                frame=expected;
                ts=frame*TICKS/v->fps;
            }
            v->action=L"Capture the desktop frame";
            CHECK(capture_video_frame(desktop,image,v->region,w,h));
            v->action=L"Encode the desktop frame";
            CHECK(sample(writer,vid,pixels,(DWORD)w*h*3/2,ts,(frame+1)*TICKS/v->fps-ts,w,h));
            frame++;
        }
    }
    if (system.running) { IAudioClient_Stop(system.client); system.running=FALSE; }
    if (microphone.running) { IAudioClient_Stop(microphone.client); microphone.running=FALSE; }
    v->action=L"Finalize the MP4 file";
    CHECK(IMFSinkWriter_Finalize(writer));
    RELEASE(IMFSinkWriter,writer);
    v->staged_playable=TRUE;
    v->action=L"Move recording to the selected folder";
    if (!MoveFileExW(v->stage,v->destination,MOVEFILE_WRITE_THROUGH)) {
        DWORD move_err=GetLastError();
        CHECK(move_err==ERROR_NOT_SAME_DEVICE ? S_OK : HRESULT_FROM_WIN32(move_err));
        /* Copy only once recording is finalized. A unique in-folder staging
           copy ensures the real final name never points to an unfinished MP4. */
        if (!CopyFileW(v->stage,v->destination_stage,TRUE)) {
            move_err=GetLastError();
            if (move_err!=ERROR_FILE_EXISTS && move_err!=ERROR_ALREADY_EXISTS)
                DeleteFileW(v->destination_stage);
            CHECK(HRESULT_FROM_WIN32(move_err));
        }
        BOOL moved=MoveFileExW(v->destination_stage,v->destination,MOVEFILE_WRITE_THROUGH);
        move_err=moved ? 0 : GetLastError();
        if (!moved) DeleteFileW(v->destination_stage);
        CHECK(moved ? S_OK : HRESULT_FROM_WIN32(move_err));
        DeleteFileW(v->stage);
    }
    v->staged_playable=FALSE;
done:
    if (ticker) { CancelWaitableTimer(ticker); CloseHandle(ticker); }
    RELEASE(IMFSinkWriter,writer);
    RELEASE(IMFAttributes,attrs);
    audio_close(&microphone);
    audio_close(&system);
    RELEASE(IMMDeviceEnumerator,devices);
    if (previous && previous!=HGDI_ERROR) SelectObject(image,previous);
    if (bitmap) DeleteObject(bitmap);
    if (image) DeleteDC(image);
    if (desktop) ReleaseDC(NULL,desktop);
    free(ring);
    if (mf) MFShutdown();
    if (com) CoUninitialize();
    if (FAILED(result) && !v->staged_playable) DeleteFileW(v->stage);
    v->status=result;
    if (!announced) { v->start_status=result; SetEvent(v->ready); }
    return 0;
}

static void reclaim(Run *v)
{
    if (v->thread) CloseHandle(v->thread);
    if (v->ready) CloseHandle(v->ready);
    if (v->stop) CloseHandle(v->stop);
    free((void *)v->stage);
    free(v->destination_stage);
    free(v->destination);
    free(v);
}

int lc_video_start(RECT region,int max_edge,int fps,int system_audio,int mic,
                   const wchar_t *final_path,wchar_t *err,size_t cap)
{
    if (run || !final_path || !*final_path || (fps!=24 && fps!=30 && fps!=60) ||
        (max_edge!=1920 && max_edge!=3840) ||
        (int64_t)region.right-region.left<16 || (int64_t)region.bottom-region.top<16 ||
        (int64_t)region.right-region.left>32768 || (int64_t)region.bottom-region.top>32768) {
        error_text(err,cap,L"Invalid or active recording request",E_INVALIDARG);
        return 0;
    }
    const size_t n=wcslen(final_path);
    if (n>32700 || n<5 || _wcsicmp(final_path+n-4,L".mp4") ||
        GetFileAttributesW(final_path)!=INVALID_FILE_ATTRIBUTES) {
        error_text(err,cap,L"Choose a new .mp4 destination",E_INVALIDARG);
        return 0;
    }
    Run *v=calloc(1,sizeof(*v));
    wchar_t *temp=NULL;
    GUID id;
    wchar_t guid[40], temp_dir[MAX_PATH+1];
    DWORD temp_count;
    HRESULT result;
    const wchar_t *action=L"Allocate recording state";
    CHECK(v ? S_OK : E_OUTOFMEMORY);
    v->region=region;
    v->fps=fps;
    v->max_edge=max_edge;
    v->system_audio=system_audio;
    v->mic=mic;
    v->destination=malloc((n+1)*sizeof(wchar_t));
    v->destination_stage=malloc((n+64)*sizeof(wchar_t));
    action=L"Locate the local recording staging folder";
    temp_count=GetTempPathW((DWORD)(sizeof(temp_dir)/sizeof(*temp_dir)),temp_dir);
    CHECK(temp_count>0 && temp_count<MAX_PATH ? S_OK : E_FAIL);
    const size_t temp_cap=temp_count+64;
    temp=malloc(temp_cap*sizeof(wchar_t));
    v->stage=temp;
    action=L"Allocate recording paths";
    CHECK(v->destination && v->destination_stage && temp ? S_OK : E_OUTOFMEMORY);
    memcpy(v->destination,final_path,(n+1)*sizeof(wchar_t));
    CHECK(CoCreateGuid(&id));
    CHECK(StringFromGUID2(&id,guid,40) ? S_OK : E_FAIL);
    _snwprintf(temp,temp_cap,L"%lsLightCapture-%ls.mp4",temp_dir,guid);
    temp[temp_cap-1]=0;
    _snwprintf(v->destination_stage,n+64,L"%ls.%ls.partial.mp4",final_path,guid);
    v->destination_stage[n+63]=0;
    action=L"Start recording worker";
    v->ready=CreateEventW(NULL,TRUE,FALSE,NULL);
    v->stop=CreateEventW(NULL,TRUE,FALSE,NULL);
    CHECK(v->ready && v->stop ? S_OK : E_FAIL);
    v->thread=CreateThread(NULL,0,record,v,0,NULL);
    CHECK(v->thread ? S_OK : HRESULT_FROM_WIN32(GetLastError()));
    HANDLE events[2]={v->ready,v->thread};
    DWORD wait=WaitForMultipleObjects(2,events,FALSE,INFINITE);
    if (wait!=WAIT_OBJECT_0 && wait!=WAIT_OBJECT_0+1) {
        SetEvent(v->stop);
        WaitForSingleObject(v->thread,INFINITE);
        result=E_FAIL;
        goto done;
    }
    if (wait!=WAIT_OBJECT_0 || FAILED(v->start_status)) {
        WaitForSingleObject(v->thread,INFINITE);
        action=v->action;
        result=FAILED(v->status) ? v->status : E_FAIL;
        goto done;
    }
    run=v;
    error_text(err,cap,L"",S_OK);
    return 1;
done:
    error_text(err,cap,action,result);
    if (v) reclaim(v);
    return 0;
}

int lc_video_stop(wchar_t *err,size_t cap)
{
    if (!run) {
        error_text(err,cap,L"No recording is active",E_UNEXPECTED);
        return 0;
    }
    Run *v=run;
    SetEvent(v->stop);
    DWORD wait=WaitForSingleObject(v->thread,INFINITE);
    if (wait!=WAIT_OBJECT_0) {
        error_text(err,cap,L"Wait for recording to finish",E_FAIL);
        return 0;
    }
    run=NULL;
    HRESULT status=v->status;
    error_text(err,cap,v->action,status);
    if (FAILED(status) && v->staged_playable && err && cap>1) {
        _snwprintf(err,cap-1,L"Save failed (0x%08lX). MP4 retained at: %ls",
                   (unsigned long)(uint32_t)status,v->stage);
        err[cap-1]=0;
    }
    reclaim(v);
    return SUCCEEDED(status);
}

int lc_video_active(void) { return run!=NULL; }
int lc_video_finished(void)
{
    return run && WaitForSingleObject(run->thread,0)==WAIT_OBJECT_0;
}
