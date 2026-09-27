# v1.25 — Dynamic Island

Appearance → Display style offers Notch and Dynamic Island. Dynamic Island floats below the menu bar and camera notch, with a continuously rounded shell, compact artwork and waveform, and the existing hover, swipe, playback, queue and level-display behaviour.

Adjust Distance below menu bar from 8 to 80 points. Preferences persist and update without restarting. Always show notch or island keeps the compact shape visible while idle. Normal notch mode remains the default; the lock-screen player is unchanged.

Validation: universal Release build, existing regression suite, and rendered compact/expanded level layouts. Real hover, swipe, multi-monitor placement and animations still need an on-device check.

General → Volume indicator → Replace macOS volume popup filters only volume media keys after Accessibility permission is granted. Undertone adjusts supported CoreAudio outputs and presents its own level indicator. Other keys, unsupported outputs and Option-modified system actions pass through. The filter is removed on lock or quit. This option is off by default and does not suppress brightness or Control Centre popups. Click Allow Accessibility, grant permission in macOS, then Retry. Live suppression requires testing after that user-controlled permission step.
