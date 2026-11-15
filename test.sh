#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/tests
sources=(Sources/*.swift)
sources=(${sources:#Sources/main.swift})
for name in Stitcher Editor ResourceLifecycle SelectionInteraction ScreenshotDelivery SessionSampler LongFrameProcessor DeadlineRequest RecordingFrameRouter RecordingControlPlacement RecordingControls LoginBackground CaptureDiagnostics; do
  xcrun swiftc -module-cache-path build/ModuleCache -swift-version 5 -O $sources "Tests/${name}Tests.swift" -o "build/tests/$name" -framework AppKit -framework ScreenCaptureKit -framework AVFoundation -framework Carbon
  "build/tests/$name"
done
if [[ "${1:-}" == "--video" ]]; then
  xcrun swiftc -module-cache-path build/ModuleCache -swift-version 5 -O $sources Tests/ExplicitWriterSyntheticTests.swift -o build/tests/ExplicitWriterSynthetic -framework AppKit -framework ScreenCaptureKit -framework AVFoundation -framework Carbon
  build/tests/ExplicitWriterSynthetic
fi
