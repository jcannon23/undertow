# Undertow

Inline next-word prediction for every Mac app. Grey text at the caret; Tab takes a word.
Everything runs on the Mac with a local Gemma model (llama.cpp); nothing typed leaves it.

## Keys

| Key | Does |
|---|---|
| Tab | take the next word |
| Shift-Tab | take the whole suggestion |
| Option-Tab, then 1-3 | other words that fit |
| Esc | dismiss |

## Build

Needs Xcode, XcodeGen and CMake (`brew install xcodegen cmake`), Apple Silicon.

    Tools/build-llama.sh     # once: fetch and build llama.cpp
    Tools/install.sh         # build, install to /Applications, relaunch

Models live in `~/Library/Application Support/Undertow/Models` (download from the app's
settings, or use the full installer, which carries one).

## Release

    Tools/release.sh 0.2.0          # notarized update, published through Sparkle
    Tools/release.sh 0.2.0 --full   # also builds Undertow-0.2.0-Full.dmg with the model inside

Updates are served from the public `undertow-releases` repo. The Sparkle signing key is in the
login keychain under the account `undertow`; without it no update can be signed, so back it up
(`generate_keys --account undertow -x <file>`).

## Layout

- `Sources/Engine`: llama.cpp wrapper (cache reuse, prefix-constrained decoding, personal language model) and prompt.
- `Sources/App`: field reader (Accessibility), key tap, ghost overlay, coordinator, learning store, settings.
- `Tools/bench`: simulated typist; the number the engine is tuned against.
- `Tools/icon`: draws the app icon and menu-bar glyph.

## Diagnostics

    defaults write app.undertow.Undertow debugLog -bool YES   # then relaunch

writes `~/Library/Logs/Undertow.log`. It records typed text: turn it off and delete the log after.
