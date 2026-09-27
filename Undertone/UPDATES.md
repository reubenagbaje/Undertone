# Signed updates

Undertone 1.22 embeds Sparkle 2.10.0. Its public Ed25519 key is in Info.plist. The private key is stored only in the development Mac's login Keychain under account `dev.reuben.Undertone`. Never include it in the repository or app. Keep a secure backup separately before changing Macs.

The update feed URL is `https://raw.githubusercontent.com/reubenagbaje/Undertone/main/appcast.xml`. Both the appcast and archive must be signed. Automatic checks are opt-in; automatic download/installation has its own toggle. Existing 1.21 installations need to install 1.22 manually once because they do not contain Sparkle.

Release v1.24 uses the signed feed at the repository root and the unmodified Mac ZIP attached to GitHub release `Update` (app version 1.24). Enable automatic checks in General → Updates; automatic download/installation is a separate preference. Version 1.21 and older require a manual update first.

Do not edit signed feeds or rebuild a ZIP after signing. An update must keep the same bundle identifier and public key and increase CFBundleVersion. Verify the feed and archive signatures before publishing, then test Check for Updates from an older installed build.

For future updates, increment CFBundleVersion, build and sign the app, zip it with `ditto`, then use Sparkle's official `generate_appcast` tool with `--account dev.reuben.Undertone --download-url-prefix https://github.com/reubenagbaje/Undertone/releases/download/VERSION/ OUTPUT_DIRECTORY`. Keep only intended release archives in that directory. Verify signatures with the official `sign_update --verify` tool before publishing. The official tools are available in the Sparkle 2.10.0 distribution; the project vendors only the runtime framework and licence.

The current distribution is ad-hoc signed, not notarized. Use Developer ID signing and notarization for a public production release. A local signature check is not an end-to-end update-installation test.

Local ad-hoc builds must use `ENABLE_HARDENED_RUNTIME=NO`: macOS library validation cannot match Team IDs for ad-hoc app/framework signatures. Keep hardened runtime enabled for Developer ID distribution and sign embedded code with that identity. Version 1.22.1 fixes this launch failure.
