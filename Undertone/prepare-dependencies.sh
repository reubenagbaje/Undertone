#!/bin/sh
set -eu
cd "$(dirname "$0")"
printf '%s\n' '78685fc1c5673032e163bbb8471dc7720c6c7d0c6d6ac1a4b7d4dcc43eacd3b1  Vendor/Sparkle-runtime.zip' | shasum -a 256 -c -
ditto -x -k Vendor/Sparkle-runtime.zip Vendor
printf '%s\n' 'Sparkle 2.10.0 is ready. Open Undertone.xcodeproj to build.'
