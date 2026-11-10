#!/bin/sh
# Cuts a release: build, notarize, publish the small update through Sparkle, and (with --full)
# build the self-contained installer that carries the model.
#
#   Tools/release.sh 0.2.0 [--full] [--model <file.gguf>] [--installer-only] [--dry-run]
#
#   --full            also build Undertow-<version>-Full.dmg with a model sealed inside
#   --model <file>    which model from the Models folder goes in it (default: Gemma 4 E2B)
#   --installer-only  build and notarize, publish nothing (no Sparkle update, no tag)
#
# Uses the notarytool keychain profile "AC_PASSWORD" (shared with other projects). To create one:
#   xcrun notarytool store-credentials AC_PASSWORD --key <AuthKey.p8> --key-id <ID> --issuer <ISSUER>
set -eu
cd "$(dirname "$0")/.."
VERSION="${1:?usage: Tools/release.sh <version> [--full] [--dry-run]}"
FULL=no; DRY=no; ONLY=no; MODELFILE=gemma-4-E2B-it-Q4_0.gguf; PREV=
for a in "$@"; do
  [ "$PREV" = "--model" ] && MODELFILE="$a"
  [ "$a" = "--full" ] && FULL=yes
  [ "$a" = "--dry-run" ] && DRY=yes
  [ "$a" = "--installer-only" ] && { ONLY=yes; FULL=yes; }
  PREV="$a"
done
BUILD=$(git rev-list --count HEAD)
OWNER=jcannon23
SPARKLE=build/dd/SourcePackages/artifacts/sparkle/Sparkle/bin
IDENTITY="Developer ID Application"
PROFILE=AC_PASSWORD
# /usr/local/bin/gh on this Mac is an Intel binary that cannot run; prefer the Homebrew one.
GH=/opt/homebrew/bin/gh; [ -x "$GH" ] || GH=gh
MODEL="$HOME/Library/Application Support/Undertow/Models/$MODELFILE"

[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first."; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || { echo "No notary profile '$PROFILE' (see the top of this script)."; exit 1; }

xcodegen generate >/dev/null
xcodebuild -project Undertow.xcodeproj -scheme Undertow -configuration Release -derivedDataPath build/dd \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" build | grep -E " error|BUILD" || true
APP=build/dd/Build/Products/Release/Undertow.app

# Distribution signing, inside out: Sparkle's helpers, the framework, then the app. Xcode's own
# pass leaves helpers with their upstream signature, no secure timestamp, and a debug entitlement
# on the app; the notary service rejects all three.
sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SP/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
sign "$SP/Autoupdate"
sign "$SP/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p build/release build/staging
ZIP="build/release/Undertow-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"   # the stapled app is what ships

if [ "$FULL" = yes ]; then
  # Same app, with the model sealed inside it. Too big for GitHub; hand it over directly.
  [ -f "$MODEL" ] || { echo "Model not found: $MODEL"; exit 1; }
  rm -rf build/staging
  mkdir -p build/staging
  ditto "$APP" build/staging/Undertow.app
  mkdir -p build/staging/Undertow.app/Contents/Resources/Models
  cp -c "$MODEL" build/staging/Undertow.app/Contents/Resources/Models/
  sign build/staging/Undertow.app
  ln -sf /Applications build/staging/Applications
  DMG="build/Undertow-$VERSION-Full.dmg"
  hdiutil create -volname "Undertow" -srcfolder build/staging -ov -format UDZO "$DMG" >/dev/null
  codesign --sign "$IDENTITY" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "Full installer: $DMG"
fi

if [ "$ONLY" = yes ]; then echo "Installer only: published nothing."; exit 0; fi

# Update feed: lives in the public releases repo next to the downloads.
[ -d build/releases-repo ] || "$GH" repo clone "$OWNER/undertow-releases" build/releases-repo
git -C build/releases-repo pull -q
[ -f build/releases-repo/appcast.xml ] && cp build/releases-repo/appcast.xml build/release/
"$SPARKLE/generate_appcast" --account undertow \
  --download-url-prefix "https://github.com/$OWNER/undertow-releases/releases/download/v$VERSION/" build/release
cp build/release/appcast.xml build/releases-repo/appcast.xml

if [ "$DRY" = yes ]; then echo "Dry run: built $ZIP and appcast, published nothing."; exit 0; fi
"$GH" release create "v$VERSION" "$ZIP" --repo "$OWNER/undertow-releases" --title "Undertow $VERSION" --notes "Undertow $VERSION"
git -C build/releases-repo add appcast.xml
git -C build/releases-repo commit -qm "Undertow $VERSION"
git -C build/releases-repo push -q
git tag "v$VERSION" && git push -q origin "v$VERSION"
echo "Released $VERSION (build $BUILD)."
