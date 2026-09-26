# Connect Undertone to Spotify Liked Songs and Up Next

1. Open your app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
2. In its settings, add this exact redirect URI and save:

   `http://127.0.0.1:43821/callback`

3. Check that the Spotify account you will use is allowed under the app's Users Management settings. Spotify currently requires the owner of a Development Mode app to have Premium.
4. Open Undertone's **…** settings and find **Spotify Liked Songs**. Paste your **Client ID**. Do not paste the client secret.
5. Click **Connect Liked Songs**. In the browser, sign in with the same account used by the Spotify desktop app and approve reading/updating saved songs and reading playback/queue information.
6. Return to Undertone. Play a Spotify track. The heart fills if it is already in Liked Songs. Click to like/unlike it in Spotify.

The normal desktop playback connection remains separate: use **Connect Spotify** in the player, or **Reconnect** in settings, to read the playing song. You can continue to use playback and the visualiser without connecting Liked Songs.

## What to expect

- Sign-in uses Authorization Code with PKCE (S256), so there is no client secret in the app.
- The local callback listens only on `127.0.0.1:43821` while you sign in, checks a random state value, and closes when finished/cancelled or after five minutes.
- Requested scopes are `user-library-read`, `user-library-modify`, `user-read-playback-state`, and `user-read-currently-playing`. Existing users reconnect once in v1.22 to approve queue access; refresh tokens then keep the connection available.
- Tokens are stored in macOS Keychain, not in the source files or preferences. The public Client ID is saved in preferences.
- The heart displays success only after Spotify confirms the write. Failed saves keep the prior state and show an error in settings.
- Saved state is checked on track changes and at most every 30 seconds for the same track. **Refresh heart** requests an immediate refresh.
- A song change during a save cannot apply the result to the new song. Repeated heart presses are disabled while saving.
- Local audio files, ads and non-track items cannot be added to Spotify Liked Songs through this control.
- Old Undertone local bookmarks are not uploaded or treated as Spotify likes.

## Troubleshooting

**Redirect URI mismatch:** copy the exact URI above. Spotify does not allow `localhost`; use `127.0.0.1` including the port and path shown.

**403 / refused access:** check the Developer app's user allowlist, the owner's Premium subscription, and reconnect to grant the library and playback-reading scopes. Sign in can succeed for an account that is not allowed to make API requests.

**Cannot open callback:** another process may be using port 43821. Close another Undertone sign-in attempt and try again.

**Rate limit:** wait for the delay in the message; Undertone respects Retry-After and does not repeatedly resend writes.

**Keychain prompt after updating:** a locally ad-hoc signed development build can have a new code identity after recompilation. Allow the updated app to access its Spotify Keychain item or reconnect. A stable Developer ID signing identity is preferable for ongoing distribution.

**Wrong Spotify account:** disconnect under Liked Songs and sign in with the account currently used by the desktop app. The library account is the one selected in the browser.

**Disconnect:** this removes locally stored tokens and clears the heart. To revoke server-side consent too, remove the Developer app under your Spotify account's connected-apps page.

## Verified versus pending

Builds and deterministic mocked-network tests pass. The test suite never contacts Spotify or changes a real library. Live sign-in and a real save/unlike need your Client ID and browser consent. A round-trip manual check is: save a previously unliked song using Undertone; verify it appears in Spotify Liked Songs; then click the heart again and verify removal. Also check that a like made in Spotify appears after Refresh heart.

Official references checked September 2026:

- [PKCE authorization](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow)
- [Redirect URI rules](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri)
- [Development Mode requirements](https://developer.spotify.com/documentation/web-api/concepts/quota-modes)
- [Save library items](https://developer.spotify.com/documentation/web-api/reference/save-library-items)
- [Remove library items](https://developer.spotify.com/documentation/web-api/reference/remove-library-items)
- [Check saved items](https://developer.spotify.com/documentation/web-api/reference/check-library-contains)

## Explicit song labels

Undertone 1.8 also reads the current track’s explicit flag from Spotify’s catalog using the same connection. No extra sign-in scopes are needed. An unavailable flag leaves the badge hidden; Liked Songs remains independent.
