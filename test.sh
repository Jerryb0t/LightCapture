#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/tests
sources=(Sources/*.swift)
sources=(${sources:#Sources/main.swift})
for name in Stitcher Editor ResourceLifecycle SelectionInteraction ScreenshotDelivery SessionSampler LongFrameProcessor DeadlineRequest RecordingFrameRouter RecordingControlPlacement RecordingControls LoginBackground AppVisibility AuthorLinks FrozenCapture CaptureDiagnostics; do
  xcrun swiftc -module-cache-path build/ModuleCache -swift-version 5 -O $sources "Tests/${name}Tests.swift" -o "build/tests/$name" -framework AppKit -framework ScreenCaptureKit -framework AVFoundation -framework Carbon
  "build/tests/$name"
done
if [[ "${1:-}" == "--video" ]]; then
  xcrun swiftc -module-cache-path build/ModuleCache -swift-version 5 -O $sources Tests/ExplicitWriterSyntheticTests.swift -o build/tests/ExplicitWriterSynthetic -framework AppKit -framework ScreenCaptureKit -framework AVFoundation -framework Carbon
  build/tests/ExplicitWriterSynthetic
fi

# Layout in both languages without opening application windows or changing preferences.
resource_bundle="$PWD/build/tests/LocalizationResources.bundle"
mkdir -p "$resource_bundle/Contents/Resources"
cp -R Resources/*.lproj "$resource_bundle/Contents/Resources/"
printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.lightcapture.resources</string></dict></plist>' > "$resource_bundle/Contents/Info.plist"
xcrun swiftc -module-cache-path build/ModuleCache -swift-version 5 -O $sources Tests/LocalizationTests.swift -o build/tests/Localization -framework AppKit -framework ScreenCaptureKit -framework AVFoundation -framework Carbon
build/tests/Localization "$resource_bundle" en
build/tests/Localization "$resource_bundle" zh-Hans

if [[ "${1:-}" == "--qr" ]]; then
  xcrun swiftc -module-cache-path build/ModuleCache -swift-version 5 -O $sources Tests/SupportQRTests.swift -o build/tests/SupportQR -framework AppKit -framework ScreenCaptureKit -framework AVFoundation -framework Carbon
  build/tests/SupportQR
fi
