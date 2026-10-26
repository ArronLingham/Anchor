#!/bin/bash
# Finalize the host seal after Xcode copies/signs Swift package resources.
# Resource-only incremental builds can otherwise retain the previous host seal.
set -euo pipefail
utility_app="${1:?usage: finalize-app.sh /absolute/path/Anchor.app [signing identity]}"
utility_identity="${2:-Apple Development}"
utility_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$utility_app/Contents/Info.plist")
case "$utility_bundle_id" in
    com.arronlingham.Anchor|com.arronlingham.Anchor.dev) ;;
    *) echo "Expected an Anchor build" >&2; exit 1 ;;
esac
/usr/bin/codesign --force --sign "$utility_identity" --options runtime \
    --preserve-metadata=identifier,entitlements,requirements,flags "$utility_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$utility_app"
