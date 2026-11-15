# LightCapture

English | [简体中文](README.md)

A lightweight, native macOS tool for screenshots and screen recording. Built with Swift, AppKit, and ScreenCaptureKit. No account, server, or third-party runtime dependencies.

[简体中文](README.md)

## Using LightCapture

- Press **Control+A** to select a region or snap to a window. The selection toolbar switches between screenshots, scrolling capture, and recording. **Enter** copies and saves a screenshot by default; settings can make it copy-only.
- Annotate screenshots with a pen, arrow, rectangle, or text. Full-screen screenshots are also available.
- For a scrolling screenshot, scroll the page yourself and let LightCapture stitch the frames together. You can also append a frame manually. Fixed headers, animation, and complex pages may not stitch cleanly.
- Record the full display or a region, optionally including system audio but not microphone input. Press the same shortcut again to stop and save. The control panel stays outside the recording area when possible and hides when there is no room.
- Closing the main window hides LightCapture from the Dock and removes its application menu, but the global shortcut keeps working. Double-click the app in Finder or on the desktop to reopen settings. To quit completely, reopen it and use **Quit LightCapture**.
- Login launch is optional and starts in the background. LightCapture does not register itself as a login item unless you turn it on.
- Choose where screenshots, scrolling captures, and recordings are saved. LightCapture prefers iCloud Drive when available and otherwise uses your local Pictures folder. Temporary recordings stay local until export finishes.

The app supports Simplified Chinese and English in one build. It follows the system language. To choose English just for LightCapture, open **System Settings → General → Language & Region → Applications**, add LightCapture, choose **English**, then quit and reopen the app. Changing the interface language does not move existing files.

The **Support the Author** section links to Jerryb0t on [GitHub](https://github.com/Jerryb0t) and [X](https://x.com/Jerryb0t). Optional WeChat Pay, Alipay, and OKX Pay QR codes appear only after an explicit selection, one at a time. Support is voluntary: verify the recipient in your own payment app before paying. LightCapture never initiates or processes payments, confirms receipt, or contacts payment services.

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
