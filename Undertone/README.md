# Undertone 1.14

A native SwiftUI/AppKit notch music player for macOS 13+. Open `Undertone.xcodeproj` in Xcode 15+; no external dependencies. Optional Liked Songs integration uses your Spotify Developer app Client ID. The included universal app supports Apple Silicon and Intel and is locally ad-hoc signed, not notarized.

## Spotify Liked Songs setup

See [SPOTIFY-SETUP.md](SPOTIFY-SETUP.md) for the full walkthrough. Add `http://127.0.0.1:43821/callback` to your Spotify Developer app's redirect URIs, paste the Client ID into **… → Spotify Liked Songs**, and choose **Connect Liked Songs**. Use the same Spotify account as the desktop app. Do not enter a client secret.

The heart now reads Spotify's actual saved state, saves with PUT `/v1/me/library`, and unlikes with DELETE `/v1/me/library`. It fills only after Spotify confirms success. No existing bookmarks are automatically synced. Disconnect removes the local Keychain credentials; Spotify account app-access revocation is separate.

## Compact-only refinement in 1.14

The song-change caption is 14-point bold, up from 12-point semibold, with a proportionally larger explicit badge and a 36-point caption row. Short text stays centred; long text still scrolls.

Swipe symbols sharpen and fully reveal in the first half of travel. Finger tracking responds faster, and travel beyond the skip threshold continues to stretch the action edge with bounded elastic resistance. The release threshold itself is unchanged; reversing below it still cancels. The expanded player implementation, its animations and its text metrics are unchanged.

Regression tests cover early reveal, bounded overtravel, reversal after overtravel, both directions and existing audio/Spotify behaviours. Offscreen renders check the larger caption and compact gesture states; live animation equivalence has not been established.

## Reference swipe motion in 1.13

Re-examined the September 24, 19:40 recording. Skip symbols now emerge from the camera side and travel outward while sharpening into focus. The outgoing waveform drifts outward and blurs away. Gesture updates use a short interactive spring; release uses a separate, softer settling spring. The shell retains its hover width after release while the pointer remains over it, without permitting an accidental full expansion. The action edge stretches six points, matching the approximate scale of the reference rather than the exaggerated 1.12 value. Opening, preview and artwork springs now settle with less overshoot.

Spotify-only audio, glass appearance, shadow, outline, corner settings and transport controls remain available. Tests cover mirrored symbol travel across 61 positions, reversal/cancellation and existing regressions. Reference frames were inspected; identical live timing cannot be established without recording the app under equivalent trackpad input.

## Spotify audio and glass appearance in 1.12

Audio now includes only the Spotify desktop app and its helper bundle IDs. On macOS 14.2+ an inclusive Core Audio process tap replaces the global mix; a process monitor reattaches after Spotify launches or restarts. No Spotify process means a silent waiting state, never a fallback to all system audio. macOS 13–14.1 uses ScreenCaptureKit's application inclusion filter; reopen Spotify and restart capture if that older capture session loses its source. Spotify Connect playback on another device and the browser player are not local Spotify desktop audio.

Settings → Black to Liquid Glass enables a black camera region that fades smoothly into native Liquid Glass across the expanded player's middle, leaving glass at the bottom. macOS 26+ uses Apple's glassEffect; earlier releases use translucent material. Reduce Transparency keeps the background opaque. The optional appearance is saved and the compact notch remains black.

Opening, preview and artwork springs have more bounce; controls have a deeper press and stronger hover lift. Slightly larger artwork fills out the player. A soft shadow adds separation from the wallpaper, including around the compact notch. Gesture commitment and all transport/library controls retain their previous behaviour. Reduce Motion disables the decorative springs.

Validation covers the universal build, audio decoding/analysis, Spotify bundle allowlist, swipe/hover timing and Spotify API regressions. Offscreen SwiftUI renders check solid and glass-fade layouts (the live glass compositor requires an onscreen window); isolation against simultaneous live Spotify/browser playback still requires a listening session on the target Mac.

## Motion, hover and outline refinement in 1.11

Swipe stretch now reaches 14 points on the action side. Springs settle more gently across opening, closing, preview, artwork and control hover; scrolling captions refresh at 60 fps. Finger tracking remains direct and release thresholds are unchanged. Reduce Motion is respected.

Hover now includes the exact top edge of the display, remains available behind the camera during song previews, and reliably rearms after leaving following a swipe.

The optional outline follows the sides and lower edge, including the curved shoulders, with no horizontal top stroke. Settings → Idle top-corner curve adjusts the compact notch shoulders from 0 to 16 points and remembers the selection; Reset curve restores 6. Expanded-player corners retain their existing shape.

## Swipe and song-preview correction in 1.10

Swiping keeps the compact island at its hover size throughout the gesture. The action side extends by up to six points while the camera gap stays centred. Artwork blurs and dims continuously; the next/previous symbol slides and fades in with finger travel. Dragging back reverses the presentation and cancels the action when released below the threshold. Holding fingers still no longer cancels a phased trackpad gesture. Momentum never skips a second track, and swiping suppresses hover expansion until the pointer leaves.

The post-skip caption centres short artist/title text with an inline explicit badge when Spotify confirms it. Long captions retain their scrolling behaviour. The preview remains a shallow extension under the compact artwork/waveform row, with rounder lower corners.

Validation: universal Release build, audio/gesture/Spotify regression tests, continuous swipe presentation tests, and offscreen SwiftUI renders of the centred explicit preview and both swipe directions. Native trackpad timing still needs checking on the user's device; static renders do not establish frame-for-frame animation equivalence.

## Preview and motion refinement in 1.9

The skip preview is now a persistent caption layer revealed and clipped by the notch, instead of an inserted/removed text row. The preview widens only four points beyond the hovered notch, with a fixed top-row height during its three-second appearance. Its body proportions follow measured frames from 20.3–23.7 seconds of the recording. Its artist/title line begins scrolling after 0.9 seconds. New skips replace the caption and renew its lifetime; pausing does not instantly remove it. The caption remains mounted during retraction, avoiding a blank snap before the shell closes.

The transient preview cannot trigger full hover expansion by growing underneath the pointer. Click the centre to open deliberately, or wait for the preview to finish and hover normally. This preserves swipe ownership and cancellation.

Opening, closing, hover and preview now have separate, more damped timings. Compact covers stay mounted under their hover controls and change with a short blur/scale dissolve; the expanded cover turn is reduced to 22 degrees. Compact transport symbols crossfade in 140 ms, while finger-driven swipe feedback remains direct. Reduced Motion disables the geometric animation.

Tests cover preview lifetime, replacement, deadline renewal and dismissal alongside the existing swipe, audio, OAuth/library and explicit-metadata checks. Offscreen reference fixtures were used to inspect caption geometry; they are not included in the app.

## Interaction parity in 1.8

The expanded player now uses a measured 360 × 189-point body with 19-point top shoulders and 46-point lower corners. Artwork, metadata, progress, and transport controls have stable coordinates; wider physical camera housings scale the layout together rather than stretching individual gaps.

- **Reversible swipe:** motion previews the action while fingers remain down. A 60-point net horizontal displacement arms it; only release commits. Sliding back below that threshold cancels, including after crossing it. Both directions, reversed mapping, vertical rejection, cancellation, and inertial scrolling are covered by tests. The preview icon follows gesture progress on the action's side. Hover expansion stays suppressed for that interaction.
- **Compact controls:** hover artwork for play/pause; hover the waveform for next. The middle/camera area opens the full player after its dwell. Wings remain available for controls without opening the player over them.
- **Song preview:** a confirmed track change widens the compact island and adds a 32-point caption area for 3.5 seconds. The artist/title line scrolls with softened edges after a short pause. It retracts on expiry, full expansion, or stopped playback.
- **Scrolling metadata:** long song titles and artist names scroll at 24 points/second after 1.2 seconds; short text stays still. Reduced Motion keeps text static and the full text remains available to accessibility and tooltips.
- **Explicit badge:** an inline E badge appears only when Spotify's catalog reports the track as explicit. This uses the existing connected account and no additional OAuth scopes. Catalog results are cached; failures back off without breaking Liked Songs. Unknown/unavailable metadata does not invent a badge.

Verified with universal compilation, signal/gesture tests, mocked Spotify catalog/library requests (including track-change races), and offscreen layout renders. Automated checks do not establish identical physical trackpad feel; the recording does not expose its source timing or gesture thresholds.

Spotify metadata reference: [Get Track](https://developer.spotify.com/documentation/web-api/reference/get-track).

## Compact-player polish in 1.7

Refined against the second recording: the compact playing notch now has 6-point outward top shoulders and 10-point lower corners. The shoulders extend outside the existing content width, preserving the physical camera gap and room for the artwork. Hover now includes the exact top edge of the display, remains available behind the camera during song previews, and reliably rearms after leaving following a swipe.

The optional outline follows the same animated contour in every state.

Compact waveform bars are now 2.25 points wide (previously 4.5), within a 16-point footprint. Both waveform views use a restrained artwork-derived tint, calculated only when the cover changes; monochrome or unavailable artwork has a neutral fallback. Audio levels remain driven by system audio.

On a confirmed track change during compact playback, the artist and title briefly appear below the camera for 2.2 seconds, as in the recording. The label truncates long titles and dismisses when paused, when fully expanded, or after the timeout. It does not bypass hover delay or swipe ownership. Artwork, swipes, Spotify likes, haptics, idle hiding, and all settings remain available.

Validation: offscreen compact, hover, track-notice and expanded renders; geometric shoulder checks; universal Release build; signature verification; existing audio, hover, swipe and Spotify mock-network tests. Reference images used for visual checks are not bundled.

## Reference alignment in 1.6

Measured against the supplied recording: a 360-point body (388 points including the top shoulders), 14-point inward top curves, 52-point lower corners, 60-point artwork with a 22-point body inset, a lower and narrower 236-point transport row, a 7-point progress bar, padded minute labels, and four genuinely reactive bars using energy from all five analysis bands. The player can widen on larger physical notches to keep its contents out of the camera area.

Settings dots now appear only when hovering over their top-right target. Settings also open from right-click → Settings or Player → Player Settings (Command-comma). Every existing control and preference remains available. The neutral filled heart continues to represent Spotify's confirmed liked state.

Visual validation used an offscreen render with reference song/artwork fixtures; those fixtures are not included in the application and never connect to Spotify or capture audio. The live waveform and song metadata will naturally vary with playback.

## Visual refinement in 1.5

Refined against the supplied recording: a wider, low-profile player with concave top shoulders, continuous lower corners, 60-point artwork, bottom-aligned metadata, a bright slim seek bar, balanced double-arrow transport controls and neutral heart styling. The progress bar subtly grows on hover or dragging. Settings remain available from the small top-right ellipsis. Expansion uses a more damped spring, while cover turns and circular button feedback remain intact.

The physical camera width determines the minimum expanded width so artwork stays beside the camera; the visual proportions adapt to each display. All existing Spotify library integration, playback/seek/shuffle, reactive system audio, hover dwell, idle hiding, haptics, reversible swipes and optional outline remain available. No credentials or settings are reset by this release.

## Finishing touches in 1.4

Resting wings are 34 points each (previously 44), growing to 42 during the hover preview. The camera gap stays the physical notch width. When Spotify is paused, stopped, or disconnected, the resting island fades completely behind the notch, including its outline. A narrow, click-through activation strip just below the camera allows deliberate hover to reveal playback controls. An open player stays available while interacting or pinned, then hides after leaving it. Displays without a camera notch use the same top-centre activation area.

In **… → Settings**, enable **Thin white outline** for a subtle 0.75-point border on dark wallpapers, or **Reverse swipe direction** to swap next and restart/previous. Both preferences persist across launches. Swiping cancels both hover preview and full expansion until you leave and return. Reduced Motion disables the size springs.

## Smoother motion in 1.3

Coordinated, interruptible island springs; an explicit animated height for expansion; softer button/cover movement; and continuously interpolated cover rotation, opacity and scale. Reduced Motion remains supported. Swipe ownership remains unchanged.

## Earlier 1.2 changes

- Smaller expanded island: 326 points wide by approximately 181 points tall, with width adapted when needed to fit the physical camera housing. Smaller collapsed wings too.
- The smaller resting wings gently enlarge after 80 ms of hover, then fully expand after 500 ms. Hover must remain inside continuously. Passing across the notch does not open it. Haptics occur when it opens, on supported trackpads.
- Two-finger horizontal swipes over the island: left = next track; right = restart if more than three seconds into the song, otherwise previous track. Horizontal motion claims the interaction before the skip threshold; release beyond the threshold commits, and reversing back cancels. One command per gesture; inertial scrolling cannot skip again. Swiping collapses the island and blocks hover reopening until the pointer leaves.
- Circular hover highlights, a slight button lift, and springy press feedback. Disabled buttons do not highlight.
- Artwork nudges immediately on skip and flips/crossfades when the next downloaded cover arrives. Previous artwork remains visible during loading. Covers are cached. Reduced Motion suppresses spring/3D effects.
- A real five-band audio spectrum replaces the near-identical trailing loudness bars. Heights represent bass through treble, with fast attack and smooth release, never random animation.
- Audio-only Core Audio process tap on macOS 14.2+. This avoids enumerating screens/windows, which caused a TCC screen-capture denial in the previous live test. macOS 13–14.1 retain a ScreenCaptureKit fallback.
- Capture remembers your enabled setting, provides Restart audio, and reports received frames and peak signal. Disabled waveform controls are orange so an off visualiser is distinguishable from silence.

## Run

1. Quit earlier copies. Unzip `Undertone-Notch-v1.14-Mac.zip`, put Undertone.app in a stable location and open it. It appears around the notch during playback, without a Dock icon. While paused or disconnected, hover just beneath the camera to reveal it.
2. Hover over the middle of the notch (or just beneath the camera when hidden) for a moment and click Connect Spotify. The Spotify desktop app must be installed. Approve Automation permission if macOS requests it.
3. Click the small waveform or use **… → Enable Spotify audio**. If macOS requests system-audio recording access for this build, allow it. An older build's permission may not carry over after an ad-hoc signing change.
4. Play music on this Mac. Spotify Connect playing on another device has no local audio to visualize. Sounds from other apps also affect the bars.
5. Swipe over the island to change tracks. After a swipe, move away and return to enable hover expansion again. **… → Keep player expanded** pins it; a swipe deliberately collapses it even when pinned.

The heart reads and updates Spotify Liked Songs after browser sign-in. Without sign-in, clicking it opens connection settings. Old local bookmarks are left untouched and are not uploaded. Shuffle controls Spotify. Settings and Quit are under **…**. App menu **Player → Show Player** is a keyboard/accessibility alternative that pins the player open; Collapse Player unpins it.

## Audio troubleshooting

Open **…** while music is playing and read the capture status:

- **Audio frames received** increasing means the system is delivering decodable buffers. **Peak** is the largest displayed band level since capture started, retained after a sound ends.
- **Receiving Spotify audio only** means non-silent signal is being analyzed.
- **Receiving audio • currently silent** with Peak 0% means the received buffers are silent. Check that audio is playing locally and this exact copy has system-audio access. macOS may supply silent buffers when authorization is absent.
- **No audio buffers received** means capture is stalled. Try Restart audio, then quit/reopen if needed.
- An explicit error includes the failed operation or audio decoding issue.

Check **System Settings → Privacy & Security → Screen & System Audio Recording** (labels differ by macOS release). Newer macOS may list audio-only access separately. For Spotify, use **Automation → Undertone → Spotify**. Keep a single app copy in a stable location. Device/output changes or sleep/wake can require Restart audio. Do not reset unrelated applications' permissions.

## Build

Open `Undertone.xcodeproj`, select **Undertone → My Mac**, choose your signing team or Sign to Run Locally, and press Command-R. Tested with Xcode 26.6.

From this folder:

```sh
xcodebuild -project Undertone.xcodeproj -scheme Undertone \
  -configuration Release -derivedDataPath build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
open build/Build/Products/Release/Undertone.app
```

For distribution, sign with Developer ID and notarize. The provided local build is not notarized.

## Permissions and architecture

- `NSAppleEventsUsageDescription` and the hardened-runtime `com.apple.security.automation.apple-events` entitlement allow Spotify metadata/control. Scripting runs on a serial background queue with timeouts.
- `NSAudioCaptureUsageDescription` explains audio-only capture. On macOS 14.2+, a private, unmuted Core Audio global process tap feeds a private aggregate device. Stopping destroys both; the default output device is not changed. No display enumeration occurs on this path.
- `NSScreenCaptureUsageDescription` explains the macOS 13–14.1 fallback. ScreenCaptureKit uses a minimal 16×16 display stream with audio enabled. Screen buffers are immediately discarded, never rendered, recorded or uploaded. Its broader permission prompt is required by that older capture route.
- App Sandbox is disabled for this direct-distribution prototype; hardened runtime is enabled. No microphone or Accessibility permission is required. Trackpad gestures are local AppKit scroll events, not global input monitoring.
- Artwork is downloaded from Spotify's supplied HTTPS image URL. Optional Spotify library integration sends the current track URI and requested save/remove action to Spotify over HTTPS, using user-approved OAuth credentials stored in Keychain. No audio is saved or uploaded; no analytics.
- `UndertoneApp.swift`: panel placement, UI, animations, haptics and event routing. Real notch geometry comes from NSScreen safe-area/auxiliary top regions; a top-centre island is used on displays without a notch. The transparent canvas passes clicks through outside the visible island.
- `AudioCapture.swift`: audio-only tap plus ScreenCaptureKit fallback, PCM decoding, five-band FFT. Signed PCM channels are transformed independently to avoid stereo phase cancellation. Hann-windowed 1,024-frame transforms map 35–180, 180–700, 700–2,500, 2,500–7,000 and 7,000–22,000 Hz into five bands. Silent/no-buffer conditions settle toward zero.
- `SpotifyController.swift`: metadata, artwork cache, transport, seek, shuffle, animation feedback and library track selection. `SpotifyOAuth.swift` handles PKCE/loopback callback/Keychain; `SpotifyLibrary.swift` handles library reads, writes and refresh tokens.
- `HoverIntent.swift`: deterministic dwell and horizontal-swipe recognition, shared with tests.

## Tests and validation

```sh
./test.sh
```

Passing automated checks cover silence/dynamics, eight PCM layouts (Float32/64 and Int16/32, interleaved and planar) through real CMSampleBuffers, stereo phase cancellation, frequency-band separation, split buffers, silence decay, hover delay/cancellation, swipe thresholds/directions, one-command-per-swipe, momentum and vertical rejection. Universal Release compilation and code-signature verification pass. Additional mocked-network tests cover PKCE, OAuth callback/state validation, Spotify saved-state reads, save/remove success and failure, track-change races, disconnect, refresh-token rotation during cancellation, and rate-limit backoff. No real account is modified by these tests. Live Spotify OAuth/library operations remain unverified until you configure a Client ID and sign in.

Live observations: the earlier ScreenCaptureKit route reported a screen/window-capture permission denial. The updated audio-only route starts and receives audio buffers. The smaller expanded UI and diagnostics were inspected. Physical two-finger gestures, haptics, and a complete Spotify/audio playback test still need hands-on confirmation; synthetic signal tests do not establish that permissions and output routing work on every Mac. Exact physical-notch alignment, full-screen behavior, output-device changes, and Intel hardware also need device testing.

Manual acceptance: skim across the notch (stays closed); dwell (opens once); hover/press each enabled control (circle and bounce); skip (old cover transitions into the next); swipe repeatedly (one track per gesture, no expansion); move away/return (hover works again); pause music and move away (island fully hides); hover beneath camera (controls return); toggle white outline (fine border follows each size); reverse swipes (directions swap); Stop audio (capture ends); relaunch with capture enabled (resumes); verify both natural-scrolling settings and output-device changes.

## Apple references

- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
- [Scroll momentum phases](https://developer.apple.com/documentation/appkit/nsevent/momentumphase)
- [Scroll-direction inversion](https://developer.apple.com/documentation/appkit/nsevent/isdirectioninvertedfromdevice)
