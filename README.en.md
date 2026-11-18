# LightCapture

English | [简体中文](README.md)

A lightweight, native macOS tool for screenshots and screen recording. Built with Swift, AppKit, and ScreenCaptureKit. Capture uses OS frameworks without an account. Only update checks and explicitly requested updates contact GitHub.

[简体中文](README.md)

**Current source: 0.2.8 (Apple silicon, macOS 15+). A public macOS package and signed update feed are not yet published; source validation does not imply a working public one-click update.**

**0.2.3 idle physical memory footprint: about 29 MB.** On a 16 GB M5 MacBook Air (macOS 27.2.1), the app was hidden and sampled at 30, 60 and 90 seconds. RSS was about 101 MB and is a different metric. Recording memory was not measured.

In 0.2.8, the settings window is created on demand rather than during background login startup. The red close button releases the window without disabling capture or recording-stop shortcuts.

## Using LightCapture

- Press **Control+A** to select a region or snap to a window. The selection toolbar switches between screenshots, scrolling capture, and recording. **Enter** copies and saves a screenshot by default; settings can make it copy-only.
- Annotate screenshots with a pen, arrow, rectangle, or text. Full-screen screenshots are also available.
- Switch to Scrolling Capture, click the highlighted window or drag out a region, then scroll down on the original page with two fingers. Enter saves; Esc cancels. During capture, only an input-transparent, nonactivating thin border remains, with no floating control window. If Enter/Escape cannot register, the selection stays visible with an explanation and capture does not begin. Revisiting captured content does not extend the image again. No injected scrolling or Accessibility permission is required. Window snapping tries to include stationary top and bottom bands only once. If animated or repetitive content prevents a reliable stitch, drag a region that excludes fixed page controls.
- Finishing samples one final frame. On a capture timeout, sampling ends and the editor retains the captured portion for review and explicit saving. If the system request never returns, restart the app rather than stacking capture tasks.
- Record a full display or a region. Select resolution and a target frame rate independently: 24, 30 (default), or 60 fps. The target is a maximum, not guaranteed; output depends on display refresh, motion, and hardware.
- Choose system audio and microphone separately. On a fresh configuration, system audio is on and the microphone is off. Existing choices are preserved. The app asks for microphone permission only when you start a recording with it enabled. When both inputs are enabled, it mixes them into one playback track without re-encoding video.
- Press the same shortcut to stop and save. The control panel stays outside the recording area when possible and hides when there is no room.
- Closing the main window hides LightCapture from the Dock and removes its application menu, but the global shortcut keeps working. While idle, double-click the app in Finder or on the desktop to reopen settings. To quit completely, reopen it and use **Quit LightCapture**.
- Login launch is optional and starts in the background. LightCapture does not register itself as a login item unless you turn it on.
- Choose where screenshots, scrolling captures, and recordings are saved. LightCapture prefers iCloud Drive when available and otherwise uses your local Pictures folder. Temporary recordings stay local until export finishes.

The app supports Simplified Chinese and English in one build. It follows the system language. To choose English just for LightCapture, open **System Settings → General → Language & Region → Applications**, add LightCapture, choose **English**, then quit and reopen the app. Changing the interface language does not move existing files.

Two separate footer entries keep things simple: **👋 Follow the Author** contains only the [GitHub](https://github.com/Jerryb0t) and [X](https://x.com/Jerryb0t) profile links; **☕ Support the Author** contains only optional support methods. Popovers and images are created on demand and released after dismissal, with no additional persistent timers or network requests. No unmeasured memory savings are claimed. Optional WeChat Pay, Alipay, and OKX Pay QR codes appear only after an explicit selection, one at a time. Support is voluntary: verify the recipient in your own payment app before paying. LightCapture never initiates or processes payments, confirms receipt, or contacts payment services.

## Frozen screenshot selection

LightCapture takes a one-shot screen snapshot and window-order metadata before showing selection overlays. Version 0.2.1 fills missing snap candidates from the screen capture API while preserving the primary window order where available. Version 0.2.2 excludes elevated display-covering container windows and routes pointer movement within the selection window so ordinary windows and small popups can both be targeted. Confirmation and annotation crop those original pixels instead of recapturing a menu that may have closed. Visible popup windows can snap when system metadata supports them, and manual selection remains available. Protected content, popups that disappear before prefetch, and some special windows may still be unavailable; not every popup is guaranteed to work.

Preview references are released on cancel or confirmation. The total snapshot budget is 24 million pixels. If multiple displays exceed it, only the display under the pointer is frozen, with an explanatory hint. Move the pointer and start again for another display. Regional crops copy out compact pixels. This budget is not a measured process-memory figure; a stalled system screenshot API can delay release of an old request's resources. Recording and scrolling capture stay live. If freezing fails when starting either live mode, ordinary screenshots are disabled for that selection rather than silently recaptured.

Synthetic pixel, Retina, window-layer, lifecycle, selection and bilingual layout tests pass. This frozen-selection update has not received an actual on-screen popup end-to-end validation.

## Check for updates

Choose **Check for Updates** at the bottom of the main window for a manual check. **Check at launch** is optional and off by default. When enabled, it checks this project's GitHub Releases API at launch or reopen, at most once per 24 hours. There is no persistent timer or background polling; when disabled, no automatic checks occur. This option does not install updates. The source integrates signed Sparkle updates, but the official ZIP and signed appcast are not yet published. Public one-click updating is not currently available. Publication requires separate update-key signing and verification; there is no automatic download or installation. Versions 0.2.2 and earlier have no in-app installer.

## Build from source

Requires **Apple silicon (arm64)**, **macOS 15 or later**, and the Apple Xcode Command Line Tools with a compatible macOS SDK.

```sh
./build.sh
open build/轻截.app
```

The default build is signed ad hoc, not a Developer ID–notarized distribution. Set `APP_OUTPUT` to change the output path, `BUNDLE_ID` to use a different identifier, or `SIGN_IDENTITY` to use your own signing identity. Do not commit build outputs. macOS requires Screen Recording permission on first use and may ask again after moving or re-signing an app.

## Tests

```sh
./test.sh
./test.sh --video  # optional synthetic MP4 encoding regression
./test.sh --qr     # optional local QR rendering/decode check
```

The tests use synthetic data, internal UI events, and test doubles. They do not capture the screen, send global keyboard or mouse events, or change macOS login settings. The optional video test requires access to the system video encoder. The optional QR test reports exit 77 when the local Vision decoder is unavailable; that is not a pass. It does not print payment payloads or initiate payments. These tests are not a substitute for real-device testing on different macOS versions and multi-display setups.

## License

LightCapture source and its original app icon are available under the [MIT License](LICENSE).

X and GitHub marks are their owners’ trademarks, not MIT-licensed assets. See [brand notices](Artwork/AuthorLinks/NOTICE.txt). The author has approved public distribution of the three receive-only QR images; see [QR notices](Artwork/SupportQR/NOTICE.txt). Original screenshots and private sidecar data are not included.

Optional synthetic recording integration: `./test.sh --recording-av` encodes generated moving frames and tones at 24/30/60 fps, verifies single-track mixing with unchanged compressed video packets/timestamps, and checks independent audio toggles. It does not access the screen or microphone. It requires working local H.264/AAC codecs and exits nonzero if unavailable.

## Windows preview

[Windows x64 unsigned preview](https://github.com/Jerryb0t/LightCapture/tree/windows-preview/Windows) is maintained on a separate preview branch; its features and validation differ from macOS.
