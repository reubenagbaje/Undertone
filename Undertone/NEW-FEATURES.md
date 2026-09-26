# v1.24 — Rounded levels and persistent notch

Changing system volume, mute, or supported display brightness extends the notch to show the actual level, then retracts after 1.6 seconds. This works without music playing. The app samples device values every 180 ms while the display is awake; it does not intercept keys or suppress the standard macOS indicator. Unsupported output/display hardware cannot report a level. Holding a key keeps the level display visible while the value changes.

The queue button beside the heart expands the same notch downward into a scrollable Up Next list. All entries returned by Spotify are shown, with loading, empty, permission and retry states. Scroll gestures inside the queue do not skip tracks. Tap the queue button again to close it. Selecting a track plays it now, which may change Spotify’s remaining queue. Existing accounts may need one reconnection for queue scopes.

The old Controls / Up Next popover is removed. Sleep timer remains available in General settings. The existing Spotify volume context menu is retained. Lock-screen layout is unchanged.

Local builds use the v1.22.1 launch-signing fix. Signed updates are published through the repository’s root appcast.xml and GitHub Releases.

The level display has a 9-point bar, larger icons, wider side insets and additional bottom padding. Compact and level-display corners are rounder. Appearance → Always show notch keeps the idle notch visible when music is paused, including notchless displays.
