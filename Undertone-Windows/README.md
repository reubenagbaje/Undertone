# Undertone for Windows — preview

A native C# / WPF port targeting Windows 10 build 19041 or later and Windows 11. This is a build-verified preview, not a claim of tested feature or pixel parity with macOS. No Windows PC was available for runtime testing.

Extract the entire Windows-x64 ZIP to a folder and launch `Undertone.exe`. The package includes .NET; keep the DLLs beside the executable. A tray icon offers Player, Settings, Presentation and Quit. Hover over the island to expand. Ctrl+Alt+P toggles presentation mode; Ctrl+, opens Settings when the window has focus.

## Included

- Windows media-session discovery, Spotify preference, artwork, title/artist, playback status, progress, play/pause, previous, next, seeking and shuffle where the source supports them.
- Floating black island / top-edge notch, hover delay, animated expansion, horizontal wheel/trackpad swipe threshold and reversed direction option.
- Optional local reactive **system-output** waveform, timers with pause/resume/restart, real file-drag shelf, HTTPS downloads, volume and supported built-in display brightness.
- Spotify authorization-code PKCE, encrypted refresh token storage using Windows DPAPI, automatic token refresh, likes and queue. Register `http://127.0.0.1:43821/callback/` in your Spotify Developer app, enter the Client ID in Settings, then connect. No client secret is needed.
- Saved preferences, display selection, white outline, reduced motion, presentation mode, and suspension of capture on lock/suspend.

## Differences that remain

The preview does not include the macOS lock-screen overlay, Liquid Glass, haptics, per-process audio isolation, synced lyrics, AirPods/battery notices, in-app audio output switching, or automatic Windows installation updates. It uses Windows fonts and controls, so exact visual/behaviour parity is not yet verified. Spotify Web API capabilities depend on Spotify permissions/account restrictions. Audio analysis uses NAudio WASAPI output loopback, not Spotify-only capture. Windows output selection opens the system Sound settings. A native Windows test pass is required before treating this as a production release.

## Build

Install the .NET 10 SDK, then:

```powershell
dotnet publish Undertone.Windows.csproj -c Release -r win-x64 --self-contained true -o publish
```

An ARM64 build can use `-r win-arm64`. Dependencies are pinned through `packages.lock.json`. NAudio is MIT licensed; .NET and Windows SDK dependencies retain their upstream notices.

## Test on Windows before general release

1. Open Spotify and verify metadata, artwork, each transport button, seeking and shuffle.
2. Play silence/music and enable audio; verify bars follow audio and stop when disabled.
3. Drag a file onto the island; verify Files opens only during a real drag, then drag it back out.
4. Pause/resume a timer, sleep across its deadline, and verify exactly one completion sound.
5. Check 100%, 150%, 200% scaling, multiple monitors, unplugging a display, and reduced motion.
6. Verify volume, supported brightness, session lock/unlock and presentation hide/restore.
7. Connect Spotify, test likes/queue, and restart the app to verify token refresh.

Made by Reuben Agbaje.
