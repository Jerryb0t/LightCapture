#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Werror -I src tests/test_vertical_stitch.cpp -o "$d/stitch"
"$d/stitch"
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -I src tests/nv12_test.c -o "$d/nv12"
"$d/nv12"
