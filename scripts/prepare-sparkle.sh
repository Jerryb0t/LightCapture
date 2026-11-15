#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
version=2.10.1
checksum=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
root="$PWD/build/vendor/Sparkle-$version"
if [[ ! -f "$root/.verified-$checksum" ]]; then
 mkdir -p "$root"
 archive="$PWD/build/vendor/Sparkle-$version.tar.xz"
 curl --fail --location --proto '=https' --tlsv1.2 "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" -o "$archive"
 echo "$checksum  $archive" | shasum -a 256 -c
 tar -xf "$archive" -C "$root"
 codesign --verify --deep --strict "$root/Sparkle.framework"
 touch "$root/.verified-$checksum"
fi
printf '%s\n' "$root"
