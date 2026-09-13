#!/bin/bash
# Builds a Universal (arm64 + x86_64) "Calendar Bar.app" into ./dist
#
#   ./build-app.sh          release universal build
#   ./build-app.sh debug    faster, host-arch-only build
#   ./build-app.sh --run    build, then (re)launch the app
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="release"
RUN=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    debug)   CONFIG="debug" ;;
    release) CONFIG="release" ;;
    --run|-r) RUN=1 ;;
    # Move the built app to /Applications and leave no second copy behind: two registered
    # bundles with the same name show up twice in Launchpad/Spotlight.
    --install|-i) INSTALL=1 ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

APP_NAME="Calendar Bar"
EXECUTABLE="CalendarBar"
DIST="dist"
APP="$DIST/$APP_NAME.app"

DEPLOY_TARGET="13.0"
# Package.swift is swift-tools-version:5.9, so SwiftPM compiles in Swift 5 language mode.
# The direct-swiftc path below must match it or main.swift's top-level code and the
# `nonisolated override init()` in AppDelegate stop compiling.
SWIFT_LANG_VERSION="5"

# SwiftPM's own `--arch arm64 --arch x86_64` needs xcbuild from a full Xcode install.
# When only the Command Line Tools are present we build each slice and lipo them together.
has_full_xcode() {
  local dir
  dir="$(xcode-select -p 2>/dev/null || true)"
  [ -x "$dir/../SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild" ] \
    || [ -x "/Library/Developer/SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild" ]
}

# A partially-updated Command Line Tools install can ship an SDK newer than the bundled
# compiler can parse (the default SDK then fails on the stdlib's own .swiftinterface), and
# can leave SwiftPM's binaries linked against a stale framework. Both are worked around:
# the SDK is probed for one the compiler accepts, and the build falls back to invoking
# swiftc directly — this target is a single module with no external dependencies.
probe_sdk() {
  local sdk="$1" tmp status
  tmp="$(mktemp -d)"
  printf 'print(1)\n' > "$tmp/probe.swift"
  swiftc -sdk "$sdk" -target "$(uname -m)-apple-macos${DEPLOY_TARGET}" \
    -swift-version "$SWIFT_LANG_VERSION" -o "$tmp/probe" "$tmp/probe.swift" >/dev/null 2>&1
  status=$?
  rm -rf "$tmp"
  return $status
}

pick_sdk() {
  local sdk_dir candidate
  sdk_dir="$(xcode-select -p 2>/dev/null)/SDKs"
  for candidate in "$(xcrun --show-sdk-path 2>/dev/null || true)" \
                   "$sdk_dir/MacOSX.sdk" \
                   $(ls -d "$sdk_dir"/MacOSX*.sdk 2>/dev/null | sort -rV); do
    [ -n "$candidate" ] && [ -d "$candidate" ] || continue
    if probe_sdk "$candidate"; then echo "$candidate"; return 0; fi
  done
  return 1
}

# True only when SwiftPM can actually load the manifest; a broken install aborts here.
# Run in a subshell so the shell's own "Abort trap" notice can be redirected too.
swiftpm_works() {
  ( swift build -c release --show-bin-path >/dev/null 2>&1 ) 2>/dev/null
}

swiftc_slice() {
  local arch="$1" out="$2" mode="$3"
  mkdir -p "$out"
  local opts=(-O -wmo)
  [ "$mode" = "debug" ] && opts=(-Onone -g)
  # shellcheck disable=SC2046
  swiftc -sdk "$SDK" -target "${arch}-apple-macos${DEPLOY_TARGET}" \
    -swift-version "$SWIFT_LANG_VERSION" "${opts[@]}" \
    -o "$out/$EXECUTABLE" $(find Sources/CalendarBar -name '*.swift' | sort) >&2
  echo "$out/$EXECUTABLE"
}

build_slice() {
  local arch="$1"
  swift build -c release --scratch-path ".build/$arch" \
    -Xswiftc -target -Xswiftc "${arch}-apple-macos${DEPLOY_TARGET}" >&2
  swift build -c release --scratch-path ".build/$arch" \
    -Xswiftc -target -Xswiftc "${arch}-apple-macos${DEPLOY_TARGET}" --show-bin-path
}

echo "==> Building ($CONFIG)"
if swiftpm_works; then
  USE_SPM=1
else
  USE_SPM=0
  SDK="$(pick_sdk)" || { echo "    !! no macOS SDK this compiler can use; reinstall the Command Line Tools"; exit 1; }
  echo "    SwiftPM unavailable (broken toolchain install); compiling with swiftc directly"
  echo "    SDK: $SDK"
fi

if [ "$CONFIG" = "debug" ]; then
  if [ "$USE_SPM" = "1" ]; then
    swift build -c debug
    BIN="$(swift build -c debug --show-bin-path)/$EXECUTABLE"
  else
    BIN="$(swiftc_slice "$(uname -m)" ".build/direct/debug" debug)"
  fi
elif [ "$USE_SPM" = "1" ] && has_full_xcode; then
  echo "    using Xcode toolchain for a universal build"
  swift build -c release --arch arm64 --arch x86_64
  BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$EXECUTABLE"
else
  echo "    building arm64 + x86_64 slices separately"
  if [ "$USE_SPM" = "1" ]; then
    ARM_BIN="$(build_slice arm64)/$EXECUTABLE"
    X86_BIN="$(build_slice x86_64)/$EXECUTABLE"
  else
    ARM_BIN="$(swiftc_slice arm64 ".build/direct/arm64" release)"
    X86_BIN="$(swiftc_slice x86_64 ".build/direct/x86_64" release)"
  fi
  mkdir -p .build/universal
  BIN=".build/universal/$EXECUTABLE"
  lipo -create -output "$BIN" "$ARM_BIN" "$X86_BIN"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# Credentials: baked in for convenience during development. Remove this block if you
# would rather keep the .env next to the app or in ~/.config/calendarbar/.env.
if [ -f .env ]; then
  cp .env "$APP/Contents/Resources/credentials.env"
  echo "    embedded .env -> Contents/Resources/credentials.env"
else
  echo "    !! no .env found; set GOOGLE_CLIENT_ID/GOOGLE_CLIENT_SECRET or edit AppConfig.swift"
fi

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 \
  && echo "    ad-hoc signed" \
  || echo "    !! codesign failed; the app still runs but macOS may re-prompt for Keychain access"

echo "==> Architectures"
lipo -archs "$APP/Contents/MacOS/$EXECUTABLE" | sed 's/^/    /'

echo "==> Done: $APP"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
TARGET="$APP"

if [ "$INSTALL" = "1" ]; then
  echo "==> Installing to /Applications"
  pkill -f "$APP_NAME.app/Contents/MacOS/$EXECUTABLE" 2>/dev/null || true
  sleep 0.4
  rm -rf "/Applications/$APP_NAME.app"
  ditto "$APP" "/Applications/$APP_NAME.app"
  # Drop the build copy so only one bundle of this name stays registered.
  [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$APP" 2>/dev/null || true
  rm -rf "$APP"
  TARGET="/Applications/$APP_NAME.app"
  echo "    installed: $TARGET"
fi

if [ "$RUN" = "1" ]; then
  echo "==> Launching"
  pkill -f "$APP_NAME.app/Contents/MacOS/$EXECUTABLE" 2>/dev/null || true
  sleep 0.4
  open "$TARGET"
fi
