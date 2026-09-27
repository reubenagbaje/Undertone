#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build/tests
swiftc -module-cache-path build/ModuleCache Undertone/AudioCapture.swift Undertone/HoverIntent.swift Tests/main.swift -o build/tests/EnvelopeTests
build/tests/EnvelopeTests
swiftc -parse-as-library -module-cache-path build/ModuleCache Undertone/SpotifyOAuth.swift Undertone/SpotifyLibrary.swift Tests/SpotifyTests.swift -o build/tests/SpotifyTests
build/tests/SpotifyTests

swiftc -parse-as-library -module-cache-path build/ModuleCache Undertone/MediaModuleModels.swift Tests/MediaModuleTests.swift -o build/tests/MediaModuleTests
build/tests/MediaModuleTests

swiftc -parse-as-library -module-cache-path build/ModuleCache -framework JavaScriptCore Tests/BrowserAdapterTests.swift -o build/tests/BrowserAdapterTests
build/tests/BrowserAdapterTests
