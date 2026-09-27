# v1.26 — Activities and everyday tools

Open the four-square Tools button near the top-right of the expanded player.

- Activities: countdown timers with completion sound, explicit HTTPS downloads with a save dialog, cancel button and real byte progress where the server reports a size. These are Undertone downloads, not a monitor of Safari/Chrome downloads. Downloads and timers stop on quit; activities pause their UI while the display sleeps.
- Battery charging notices: enable in Settings → Modules. Changes use macOS power-source data.
- AirPods/Beats: opt-in connection notices for paired devices. Battery percentages appear only if macOS exposes a matching power source; otherwise the panel says Battery unavailable. No pairing or connection is forced.
- Files: drop up to 20 local files on the island; drag them out to another app. Remove/Clear affects only the shelf, not original files. The shelf lasts for the app session.
- Sound: switch the default macOS output among available output devices. Hardware can refuse changes; errors are shown.
- Players: choose Spotify, Apple Music, Safari or Chrome in General. Apple Music uses its desktop scripting API. Browser mode needs Automation access and the browser’s JavaScript from Apple Events option. It controls HTML audio/video in the active tab; cross-origin frames, some DRM players and native browser players are unsupported. Browser next/previous/shuffle and Spotify-only likes/queue are disabled. Browser waveform capture may include other tabs; Safari helper audio may not be exposed for isolated capture on every macOS version.
- Display: select a monitor in Modules; Dynamic Island remembers a vertical gap per selected display. Missing monitors fall back. Compact, Comfortable and Minimal presets change size; animation intensity ranges from still to playful. macOS Reduce Motion takes precedence.
- Presentation mode: hides desktop and lock-screen overlays until disabled. Toggle in Modules or with ⌘⌥P (when global shortcuts are enabled). Show Player also restores the desktop overlay.
- Brightness popup replacement: General → Volume indicator → Replace macOS brightness popup. Grant Accessibility access and Retry, as with volume. Supported brightness key presses adjust the display and show only Undertone’s indicator. Unsupported hardware or failed writes pass through to macOS. Option-modified keys retain the system action. This does not change system-wide security settings or suppress unrelated popups.

Validation: universal Release build and regression suite, including selected-player capture filtering and download URL validation. Live Accessibility interception, output switching, Bluetooth, real download transfers, Apple Music/browser playback and multi-monitor layout require on-device testing. Browser developer permissions are never enabled automatically. The release remains ad-hoc signed and not notarized.
