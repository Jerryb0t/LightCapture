#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${ZIG:=zig}"
target="${TARGET:-x86_64-windows-gnu}"
mkdir -p build
"$ZIG" cc -target "$target" -O2 -Wall -Wextra -Werror -c src/main.c -o build/main.o
"$ZIG" cc -target "$target" -O2 -Wall -Wextra -Werror -c src/lightcapture_video.c -o build/video.o
"$ZIG" c++ -target "$target" -O2 -std=c++17 -Wall -Wextra -Werror -c src/stitch_bridge.cpp -o build/stitch.o
"$ZIG" cc -target "$target" -O2 -Wall -Wextra -Werror -c src/support.c -o build/support.o
"$ZIG" rc /fo build/icon.res icon.rc
"$ZIG" c++ -target "$target" -O2 -s -municode -Wl,--subsystem,windows build/main.o build/video.o build/stitch.o build/support.o build/icon.res \
  -ldwmapi -lgdi32 -luser32 -lmsimg32 -lole32 -lshell32 -ladvapi32 -lwindowscodecs -lmfplat -lmfreadwrite -lmfuuid -luuid \
  -o build/LightCapture.exe
