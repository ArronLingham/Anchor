#!/bin/bash
# Reachability audit: a feature is only real if every link in the chain holds.
#
#   read   the key is consumed somewhere that is NOT a settings pane
#   ui     a settings pane exposes it
#   start  the owning manager is start()ed from AnchorApp
#
# read:0 means nothing acts on the key — a switch wired to nothing.
# ui:0   means the user cannot reach it — the failure that shipped twice,
#        for key debounce and focus-follows-mouse, both of which were built,
#        tested, installed and reported done with no way to turn them on.
#
# KNOWN FALSE POSITIVES on the start column:
#   SystemStatsManager  is reference-counted (acquire/release), no start()
#   SnapZoneManager     self-starts from its own init()
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

check () {
  local key="$1" manager="${2:-}"
  local read_ ui start flag=""

  # `|| true` on every grep: grep exits 1 when it matches nothing, and under
  # `set -e` that aborted the audit at the first key with a zero count — so the
  # script silently stopped checking after roughly the eighth key while still
  # printing a confident summary. An audit that quietly skips most of its input
  # is worse than no audit.
  read_=$( { grep -rl "\.$key\b" Anchor --include='*.swift' || true; } \
          | grep -v "models/Constants.swift" | grep -v "Components/Settings/" | wc -l | tr -d ' ' )
  ui=$( { grep -rl "\.$key\b" Anchor/Components/Settings --include='*.swift' 2>/dev/null || true; } \
          | wc -l | tr -d ' ' )
  if [ -n "$manager" ]; then
    start=$( { grep -c "$manager\.shared\.start()" Anchor/AnchorApp.swift 2>/dev/null || true; } | tr -d ' ' )
    [ -z "$start" ] && start=0
  else
    start="-"
  fi

  [ "$read_" = "0" ] && { flag="$flag NO-READ"; fail=1; }
  [ "$ui" = "0" ]    && { flag="$flag NO-UI";   fail=1; }
  [ "$start" = "0" ] && flag="$flag not-started?"

  printf "  %-34s read:%-3s ui:%-3s start:%-3s %s\n" "$key" "$read_" "$ui" "$start" "$flag"
}

# Every key added since the feature waves began. Add new ones here.
check autoClearClipboardEnabled     ClipboardToolsManager
check autoClearClipboardSeconds     ClipboardToolsManager
check autoClearClipboardOnLock      ClipboardToolsManager
check invertScrollVertical          PointerInputManager
check invertScrollHorizontal        PointerInputManager
check mouseSideButtonNavigation     PointerInputManager
check enableTextSnippets            TextSnippetManager
check textSnippets                  TextSnippetManager
check enableSystemStats             SystemStatsManager
check enableSnapZones               SnapZoneManager
check enableKeyDebounce             KeyDebounceManager
check keyDebounceMilliseconds       KeyDebounceManager
check enableFocusFollowsMouse       FocusFollowsMouseManager
check focusFollowsMouseDelayMs      FocusFollowsMouseManager
check pinnedInputDeviceUID          AudioDeviceToolsManager
check enableAudioDeviceHUD          AudioDeviceToolsManager
check enableQuitOnLastWindowClose   AppLifecycleManager
check quitOnCloseExcludedApps       AppLifecycleManager
check blockMediaAppAutoLaunch       AppLifecycleManager
check enableBatteryAlert            SystemAlertManager
check batteryAlertPercent           SystemAlertManager
check enableDiskAlert               SystemAlertManager
check diskAlertPercent              SystemAlertManager
check enableCPUAlert                SystemAlertManager
check cpuAlertPercent               SystemAlertManager
check menuBarShowCPU                MenuBarReadoutManager
check menuBarShowMemory             MenuBarReadoutManager
check menuBarShowNetwork            MenuBarReadoutManager
check enableDiskImageInstaller      DiskImageInstaller

echo
if [ "$fail" = "0" ]; then
  echo "no unreachable features"
else
  echo "UNREACHABLE FEATURES FOUND — see NO-READ / NO-UI above"
  exit 1
fi
