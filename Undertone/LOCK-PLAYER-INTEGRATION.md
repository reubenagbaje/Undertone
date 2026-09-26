# Now Playing module and native Settings

Version 1.20 includes a separate General / Modules / Appearance Settings window, automatic Spotify connection, and an experimental lock-screen-style player.

## What works and what macOS restricts

The desktop preview is an interactive SwiftUI player with artwork, local Spotify audio visualization, transport controls, seeking, Spotify volume, an artwork-derived ambient palette and imported timed lyrics. Open **Settings → Modules → Preview Now Playing**.

The lock module is **experimental and off by default**. It observes `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked` through `DistributedNotificationCenter`; these names are not a documented Apple API contract. Version 1.20 sets the public `canBecomeVisibleWithoutLogin` window property, uses SkyLightWindow’s topmost window level and delegates the window to a private SkyLight Space at absolute level 400, and makes three bounded ordering attempts during the lock transition. It checks console-session ownership rather than treating every session-resigned notification as a user switch.

**The user confirmed lock-screen visibility with version 1.17. Compatibility remains macOS-dependent.** The visibility property permits login-window display but does not guarantee that this app's overlay appears in every secure session. Private SkyLight APIs are used through a runtime-loaded adapter based on MIT-licensed SkyLightWindow (see bundled ThirdPartyNotices.txt). No authentication plug-in or system security modification is used. This is for direct distribution; private APIs are unsupported by Apple. This cannot appear at FileVault's pre-boot login: Undertone must already be running in a logged-in session.

The compact glass panel has a tappable artwork thumbnail. Tapping expands the artwork with a spring transition; tapping the expanded artwork or collapse button returns to the compact panel. The desktop preview fills the display. While locked, the 370-point-wide player uses the same PlayerView as the desktop notch and sits slightly lower, above the authentication area. Expanded artwork fills the entire screen. Moving the pointer into the lower 22% collapses the artwork to reveal native authentication; that area stays click-through. The app never receives keyboard focus. Right-click the card for volume, artwork and hide actions. The panel never becomes key or main and accepts mouse input only in its media regions. Keyboard focus remains with the system. Pausing keeps an existing player visible; the close button dismisses it until the next lock.

`MPNowPlayingInfoCenter` publishes an app's own playback information; it is not used as a global reader. The module reuses Undertone's `SpotifyController`, avoiding private `MediaRemote` APIs. Playback from other apps is outside this module's current scope.

## Attachment points

The app has one shared instance of each playback service, owned by `IslandDelegate`. Both scenes observe those same instances:

```swift
@main struct UndertoneApp: App {
    @NSApplicationDelegateAdaptor(IslandDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsDashboard(
                state: delegate.state,
                spotify: delegate.spotify,
                audio: delegate.audio,
                lockPlayer: delegate.lockPlayer
            )
        }
    }
}
```

The actual app also retains its existing Player menu commands. The native Settings scene provides **⌘,** while Undertone is active. The notch's ellipsis and library-setup action use `SettingsRequestHandler` to call SwiftUI's `openSettings` on macOS 14+, with the macOS 13 settings-window action as fallback. The old popover has been removed.

Controller ownership and startup are wired into `IslandDelegate`:

```swift
let spotify = SpotifyController()
let audio = AudioCapture()
let state = IslandState()

lazy var lockPlayer = LockScreenPlayerController(
    spotify: spotify,
    audio: audio,
    notchRect: { [weak self] in
        guard let self else { return .zero }
        return CGRect(
            x: self.anchor.x - self.state.compactWidth / 2,
            y: self.anchor.y - self.state.compactHeight,
            width: self.state.compactWidth,
            height: self.state.compactHeight
        )
    }
)

// In applicationDidFinishLaunching, after creating the notch panel:
spotify.startAutomaticConnection()
lockPlayer.onSleepChanged = { [weak self] asleep in
    guard let self else { return }
    self.timer?.fireDate = asleep ? .distantFuture : Date()
    self.audio.setDisplaySleeping(asleep)
}
lockPlayer.start()
```

Termination calls `lockPlayer.shutdown()` and `spotify.shutdown()`, removing subscriptions, observers, windows and timers. The overlay never owns a second media engine or starts a separate capture stream.

## Preferences

| Key | Default | Purpose |
| --- | --- | --- |
| `enableLockScreenPlayer` | false | Opt into experimental lock overlay |
| `lockPlayerAmbientGlow` | true | Artwork-derived palette backdrop |
| `lockPlayerSyncedLyrics` | false | Show imported timestamped lyrics |
| `lockPlayerUnlockAnimation` | true | Spring shrink to the desktop notch |

The module switch is declared with `@AppStorage("enableLockScreenPlayer")`. Changes are observed while the app is running, and disabling the module dismisses a lock overlay.

## Lyrics

Use **Settings → Modules → Import lyrics for current song…** with a UTF-8 `.lrc` file you have permission to use. Imports support `[mm:ss]`, fractional timestamps, multiple timestamps per line and an optional millisecond `[offset:]` tag. Invalid timestamps are ignored. Files over 2 MB are rejected.

Imported lines are saved by Spotify track ID in `~/Library/Application Support/Undertone/Lyrics.json`. Seeking recomputes the active line from the current position, including backwards seeks. Spotify's public connection does not supply lyric text; no scraping service or fabricated lyrics are included.

## Reconnection

At launch, Undertone starts its Spotify observer and polling once. Spotify application launch/exit notifications trigger an immediate refresh. Temporary Apple Event failures use a 2–30 second bounded exponential retry delay. A denied Automation request (`-1743`) stops retries until **Retry connection** is selected after fixing permission. First-use Automation permission and the optional OAuth sign-in still need user approval.

Artwork, progress, transport and volume all use the existing Spotify controller. The volume control changes Spotify's application volume, not the system output volume. Audio capture retains its existing user-enabled preference and does not request recording permission just because the lock module is enabled.

## Sleep, sessions and displays

- Screen/system sleep removes the overlay, pauses the notch's pointer timer and Spotify polling, and stops capture while retaining the user's capture preference. Wake resumes eligible services.
- No continuous decorative animation loop is added. Waveform updates use the existing audio analysis; palette extraction samples artwork only when the image changes.
- Fast user switching dismisses the overlay and prevents presentation in an inactive session.
- The overlay uses `NSScreen.screens.first` (the primary display), not the screen containing whichever app currently has keyboard focus.
- Display changes discard stale window geometry and recreate an eligible overlay.
- Unlock shrinks to the notch's current global rectangle on the same display. If the notch is on a different display, the overlay dismisses instead of flying across screens.
- Reduce Motion dismisses without the shrink animation. Reduce Transparency uses an opaque card and disables the ambient backdrop.

## Validation

Run `./test.sh` for the existing audio/gesture/Spotify tests plus reconnect backoff, permission denial, LRC timestamp parsing/seeking and presentation policy tests, plus protected authentication-area and media hit-region geometry tests. The mocked tests never change a real Spotify account. Universal builds target Apple silicon and Intel.

Manual checks still required on the target Mac:

1. Open Settings with ⌘, and from the notch; confirm one native Settings window and all three tabs.
2. Open the desktop preview; tap the thumbnail to expand artwork, tap again to collapse, and check controls, seek, volume and imported lyrics.
3. Quit/reopen Spotify and confirm automatic reconnection after any initial permission approval.
4. Check display sleep/wake, monitor removal and fast user switching.
5. Opt into the experimental module, play Spotify and lock/unlock manually. Confirm visibility, mouse controls and unobstructed native password entry. A successful build or desktop preview does not establish secure-lock-screen compatibility. The user confirmed the SkyLight overlay appears on the lock screen. Version 1.20 changes only its layout and styling; check placement against the native password prompt on the target display.

## References

- [MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)
- [Display sleep notifications](https://developer.apple.com/documentation/appkit/nsworkspace/screensdidsleepnotification)

- [NSWindow.canBecomeVisibleWithoutLogin](https://developer.apple.com/documentation/appkit/nswindow/canbecomevisiblewithoutlogin)

Version 1.20: Settings → Modules → Liquid Glass player enables native glass on macOS 26+, with material fallback on older systems. Reduce Transparency keeps the card opaque. The fuller card has 24 extra points of vertical padding and sits 18 points above the reserved authentication area. Its thumbnail hides and the heading widens while full-screen artwork is expanded.

Version 1.21 enlarges and strengthens the shared transport icons and progress bar. Seeking updates the displayed position immediately, disables progress interpolation while dragging, and rejects polls started before or during a seek. The next fresh poll reconciles with Spotify, including after failed seeks.
