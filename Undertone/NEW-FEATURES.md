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

## v1.26.1 — Optional modules and updater repair

Timers, downloads, the file shelf and audio output switching are now individually opt-in in Settings → Modules. Disabled tools disappear from the player. Disabling timers/downloads cancels their active task; disabling the shelf removes references without deleting files. Charging and headphone notices remain optional.

Settings and Tools now share dark surfaces, rounded pill controls and consistent typography. Core Spotify playback remains available without enabling extra modules.

Fixed Sparkle startup: signed feeds require `SUVerifyUpdateBeforeExtraction` as well as `SURequireSignedFeed`. Both are enabled. Settings now exposes update status/errors. Versions with the broken startup configuration need one manual installation of this repair; a feed change alone cannot start their updater. Automatic checks remain an explicit Settings preference.

## v1.27 — Live timer and file drag reveal

Enable Timers in Settings → Modules, then start one from Tools → Activities. The compact notch shows an orange countdown and progress symbol, with room reserved for the physical camera. Hover to expand its pause/resume and cancel controls. A completed timer remains visible with a restart action. Music opens the regular player without cancelling the timer. Timers continue by deadline while the display sleeps; paused timers preserve their remaining time. They do not survive quitting the app.

Visual reference: [Apple's Dynamic Island Live Activities guide](https://support.apple.com/guide/iphone/view-live-activities-in-the-dynamic-island-iph28f50d10d/ios) and [compact/expanded timer reference](https://mobilelaby.net/images/2022/09/dynmic-island-timer-widget.jpg). No reference assets are bundled.

When File Shelf is enabled, dragging a local file over the notch opens Tools → Files before drop, including from the hidden idle activation area. Disabled shelf and presentation mode do not trigger the drawer. Moving away without dropping follows the normal collapse delay after the drag ends. Files are added only after a drop.

Version 1.27 is build 32, newer than the repaired v1.26.1 (31), for testing Sparkle updates. Versions before v1.26.1 still require the one-time manual updater repair.
