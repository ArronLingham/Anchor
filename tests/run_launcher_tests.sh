#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
matcher="$repo/Anchor/Managers/Launcher/FuzzyMatcher.swift"
calculator="$repo/Anchor/Managers/Launcher/CalculatorAction.swift"
test_src="$repo/tests/LauncherTests.swift"

for f in "$matcher" "$calculator" "$test_src"; do
  [[ -f "$f" ]] || { echo "missing source: $f" >&2; exit 1; }
done

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# Create ExceptionCatcher for the tests
cat << 'OBJC' > "$out/ExceptionCatcher.m"
#import <Foundation/Foundation.h>
@interface AudioBridge : NSObject
+ (BOOL)catchException:(void(^)(void))tryBlock error:(__autoreleasing NSError **)error;
@end
@implementation AudioBridge
+ (BOOL)catchException:(void(^)(void))tryBlock error:(__autoreleasing NSError **)error {
    @try { tryBlock(); return YES; }
    @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:exception.name code:0 userInfo:exception.userInfo];
        return NO;
    }
}
@end
OBJC

clang -c "$out/ExceptionCatcher.m" -o "$out/ExceptionCatcher.o"
swiftc -O "$matcher" "$calculator" "$test_src" -import-objc-header "$out/ExceptionCatcher.m" "$out/ExceptionCatcher.o" -o "$out/launchertests"
"$out/launchertests"
