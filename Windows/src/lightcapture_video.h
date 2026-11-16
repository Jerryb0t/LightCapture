#ifndef LIGHTCAPTURE_VIDEO_H
#define LIGHTCAPTURE_VIDEO_H
#include <windows.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* UI-thread API. The rectangle is physical desktop pixels; negative coordinates
 * are valid on secondary monitors. The destination folder must already exist.
 * Only explicit opt-in opens the microphone. */
int lc_video_start(RECT region, int max_edge, int fps, int system_audio, int mic,
                   const wchar_t *final_path, wchar_t *error, size_t error_count);
/* Finalizes the writer, then atomically switches from staging to destination.
 * Can block while the Windows encoder flushes. Never overwrites a user file. */
int lc_video_stop(wchar_t *error, size_t error_count);
int lc_video_active(void);
/* If an asynchronous error occurs, reap via lc_video_stop before restarting. */
int lc_video_finished(void);
#ifdef __cplusplus
}
#endif
#endif
