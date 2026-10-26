#!/bin/bash
set -euo pipefail

utility_root="$SRCROOT/Packages/AnchorUtilities"
utility_sources="$utility_root/Sources/AnchorUtilities"
utility_contents="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH"
utility_output="$DERIVED_FILE_DIR/AnchorUtilitiesSupport"
utility_helper_id="$PRODUCT_BUNDLE_IDENTIFIER.fan-control"
utility_variant=ANCHOR_UTILITIES_RELEASE
if [[ "$CONFIGURATION" == "Debug" ]]; then
    utility_variant=ANCHOR_UTILITIES_DEVELOPMENT
fi
mkdir -p "$utility_output" "$utility_contents/Library/LaunchServices" \
    "$utility_contents/Library/LaunchDaemons" "$utility_contents/Frameworks"

xcrun swiftc -O -target arm64-apple-macos14.0 -sdk "$SDKROOT" -D "$utility_variant" \
    "$utility_sources/Services/FanControl/FanControlSupport.swift" \
    "$utility_sources/Services/FanControl/FanControlXPC.swift" \
    "$utility_sources/Services/SystemMonitor/SMCClient.swift" \
    "$utility_sources/Services/Metrics/TemperatureSensorSelector.swift" \
    "$utility_sources/Services/FanControl/FanControlHardware.swift" \
    "$utility_root/Support/FanControlHelper/main.swift" \
    -o "$utility_output/$utility_helper_id"
"$utility_output/$utility_helper_id" --selftest
cp "$utility_output/$utility_helper_id" "$utility_contents/Library/LaunchServices/"

xcrun swiftc -O -target arm64-apple-macos14.0 -sdk "$SDKROOT" -emit-library \
    -module-name AnchorUtilitiesNowPlaying \
    "$utility_root/Support/NowPlayingAdapter/NowPlayingAdapter.swift" \
    "$utility_root/Support/NowPlayingAdapter/NowPlayingQueue.swift" \
    "$utility_root/Support/NowPlayingAdapter/NowPlayingSelection.swift" \
    "$utility_sources/Services/Notch/NotchPlaybackSource.swift" \
    "$utility_sources/Services/Notch/NotchPlaybackCommand.swift" \
    -o "$utility_contents/Frameworks/libAnchorUtilitiesNowPlaying.dylib"

/usr/bin/python3 - "$utility_contents/Library/LaunchDaemons/$utility_helper_id.plist" "$utility_helper_id" <<'PY'
import plistlib, sys
path, identifier = sys.argv[1:]
with open(path, 'wb') as target:
    plistlib.dump({
        'Label': identifier,
        'BundleProgram': 'Contents/Library/LaunchServices/' + identifier,
        'MachServices': {identifier: True},
        'KeepAlive': {'Crashed': True},
        'ThrottleInterval': 5,
        'ExitTimeOut': 60,
    }, target)
PY

mkdir -p "$utility_contents/Resources/AnchorUtilitiesNotices"
cp "$utility_root/LICENSE" "$utility_root/NOTICE.md" "$utility_contents/Resources/AnchorUtilitiesNotices/"
utility_signing_id="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [[ -z "$utility_signing_id" ]]; then utility_signing_id="-"; fi
/usr/bin/codesign --force --sign "$utility_signing_id" --options runtime \
    --identifier "$utility_helper_id" "$utility_contents/Library/LaunchServices/$utility_helper_id"
/usr/bin/codesign --force --sign "$utility_signing_id" --options runtime \
    --identifier "$PRODUCT_BUNDLE_IDENTIFIER.utilities.now-playing" \
    "$utility_contents/Frameworks/libAnchorUtilitiesNowPlaying.dylib"
