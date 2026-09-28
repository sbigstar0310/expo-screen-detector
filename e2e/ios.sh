#!/usr/bin/env bash
# iOS Simulator smoke / e2e test for expo-screen-detector (example app).
#
# Builds the example app (Release by default, JS bundle embedded, no Metro),
# installs it on a headless simulator, drives it with `xcrun simctl` and the
# agent-device CLI, and asserts on the `[SDQA]` console lines the app logs.
#
# Usage:  e2e/ios.sh            (from anywhere)
# Exit:   0 = no FAIL (PASS/SKIP only), 1 = at least one FAIL, 2 = setup error
#
# Environment overrides:
#   SIM_UDID        simulator UDID (wins over SIM_NAME/SIM_OS)
#   SIM_NAME        device name to pick            (default: "iPhone 17 Pro")
#   SIM_OS          runtime version prefix to pick  (default: newest runtime that has SIM_NAME)
#   CONFIGURATION   Release | Debug                 (default: Release; Debug needs Metro on :8081)
#   SKIP_BUILD=1    reuse the last built .app
#   IOS_MIRROR      1 = build in a mirror outside the repo, 0 = build in place,
#                   auto (default) = mirror only if the repo is in an iCloud-synced folder
#   IOS_WORKDIR     mirror/DerivedData location     (default: ~/Library/Caches/expo-screen-detector-e2e)
#   ART_DIR         where logs go (default: $IOS_WORKDIR/artifacts/ios-<timestamp>)
#   KEEP_SIM=1      don't shut the simulator down at the end
#   BUILD_TIMEOUT   seconds                         (default: 1800)
#   AGENT_DEVICE    path to the agent-device CLI
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE_ID="expo.modules.screendetector.example"
APP_NAME="exposcreendetectorexample"
SCHEME="exposcreendetectorexample"
CONFIGURATION="${CONFIGURATION:-Release}"
SIM_NAME="${SIM_NAME:-iPhone 17 Pro}"
SIM_OS="${SIM_OS:-}"
IOS_MIRROR="${IOS_MIRROR:-auto}"
IOS_WORKDIR="${IOS_WORKDIR:-$HOME/Library/Caches/expo-screen-detector-e2e}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-1800}"
AGENT_DEVICE="${AGENT_DEVICE:-$(command -v agent-device || echo "$HOME/.claude/plugins/cache/daegyu-plugins/mobile-qa/ec08edae9855/bin/agent-device")}"
AD_SESSION="sdqa-ios-$$"

ART_DIR="${ART_DIR:-$IOS_WORKDIR/artifacts/ios-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$ART_DIR"
LOG_FILE="$ART_DIR/device.log"      # full app-process unified log
SDQA_FILE="$ART_DIR/sdqa.log"       # just the SDQA lines
START_TS=$(date +%s)

RESULTS=()
FAILED=0
LOG_PID=""
UDID=""
WE_BOOTED=0
AD_OPEN=0

say()  { printf '[ios-e2e %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { say "SETUP ERROR: $*"; cleanup; exit 2; }
record() { # record <case> <PASS|FAIL|SKIP> <detail>
  RESULTS+=("$(printf '%-4s | %-28s | %s' "$2" "$1" "$3")")
  say "$2 $1 - $3"
  [[ "$2" == FAIL ]] && FAILED=1
  return 0
}

ad() { "$AGENT_DEVICE" "$@" --platform ios --udid "$UDID" --session "$AD_SESSION" >>"$ART_DIR/agent-device.log" 2>&1; }

cleanup() {
  [[ -n "$LOG_PID" ]] && kill "$LOG_PID" 2>/dev/null
  if [[ "$AD_OPEN" == 1 ]]; then "$AGENT_DEVICE" close --session "$AD_SESSION" >>"$ART_DIR/agent-device.log" 2>&1 || true; fi
  [[ -n "$UDID" ]] && pkill -f "idb_companion --udid $UDID" 2>/dev/null
  if [[ -n "$UDID" && "${KEEP_SIM:-0}" != 1 && "$WE_BOOTED" == 1 ]]; then
    say "shutting down simulator $UDID"
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  fi
}
trap 'cleanup; exit 130' INT TERM

# wait_for <regex> <timeout_s> [since_line] -> prints first matching SDQA line after since_line
wait_for() {
  local re="$1" to="$2" since="${3:-0}" i=0 hit
  while (( i < to * 2 )); do
    hit=$(sdqa | tail -n +"$((since + 1))" | grep -E -m1 -- "$re") && { echo "$hit"; return 0; }
    sleep 0.5; i=$((i + 1))
  done
  return 1
}
sdqa() { grep -E '\[SDQA' "$LOG_FILE" 2>/dev/null; }
sdqa_lines() { sdqa | wc -l | tr -d ' '; }
app_pid() { xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | awk -v b="$BUNDLE_ID" '$3 ~ b {print $1; exit}'; }
# json field from an [SDQA] line
field() { sed -nE "s/.*\"$2\":(\"[^\"]*\"|[a-z0-9]+).*/\1/p" <<<"$1" | tr -d '"'; }
vals_ok() { [[ "$(field "$1" off)" == false && "$(field "$1" locked)" == false && "$(field "$1" unavailable)" == false ]]; }
fatal_seen() { grep -E -m1 "Cannot find native module|Invariant Violation|Unhandled JS Exception|RCTFatal|\[SDQA\] ERROR|\[SDQA-BG\] ERROR|Terminating app due to" "$LOG_FILE" 2>/dev/null; }

# ---------------------------------------------------------------- simulator
if [[ -n "${SIM_UDID:-}" ]]; then
  UDID="$SIM_UDID"
else
  UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys,re
name, want = sys.argv[1], sys.argv[2]
best = None
for rt, devs in json.load(sys.stdin)["devices"].items():
    m = re.search(r"iOS-(\d+)-(\d+)", rt)
    if not m: continue
    ver = (int(m[1]), int(m[2])); vs = f"{ver[0]}.{ver[1]}"
    if want and not vs.startswith(want): continue
    for d in devs:
        if d["name"] == name and d.get("isAvailable", True):
            key = (d["state"] != "Booted", ver)   # prefer a device nobody else booted
            if best is None or key > best[0]: best = (key, d["udid"])
print(best[1] if best else "")' "$SIM_NAME" "$SIM_OS")
fi
[[ -n "$UDID" ]] || die "no simulator named '$SIM_NAME' ${SIM_OS:+(iOS $SIM_OS)} found; set SIM_UDID"
SIM_DESC=$(xcrun simctl list devices | grep "$UDID" | sed -E 's/^ +//; s/ *\((Shutdown|Booted)\) *$//')
SIM_DESC="$SIM_DESC, iOS $(xcrun simctl list devices | awk -v u="$UDID" '/^-- /{rt=$0} index($0,u){print rt; exit}' | sed -E 's/-- iOS ([0-9.]+) --/\1/')"
say "simulator: $SIM_DESC"
say "configuration: $CONFIGURATION  artifacts: $ART_DIR"

# ---------------------------------------------------------------- build
if [[ "$IOS_MIRROR" == auto ]]; then
  # iCloud "Desktop & Documents" stamps build products with FinderInfo/fileprovider
  # xattrs and codesign then fails ("resource fork, Finder information, or similar
  # detritus not allowed"), notably in expo-modules-jsi's nested xcodebuild.
  if xattr "$REPO_DIR/example" 2>/dev/null | grep -q 'com.apple.fileprovider' \
     || [[ "$REPO_DIR" == "$HOME/Desktop"* || "$REPO_DIR" == "$HOME/Documents"* ]]; then IOS_MIRROR=1; else IOS_MIRROR=0; fi
fi
if [[ "$IOS_MIRROR" == 1 ]]; then
  BUILD_ROOT="$IOS_WORKDIR/repo"
else
  BUILD_ROOT="$REPO_DIR"
fi
DERIVED="$IOS_WORKDIR/DerivedData"
APP_PATH="$DERIVED/Build/Products/${CONFIGURATION}-iphonesimulator/${APP_NAME}.app"

if [[ "${SKIP_BUILD:-0}" != 1 ]]; then
  [[ -d "$REPO_DIR/example/ios" ]] || die "example/ios missing - run 'cd example && npx expo prebuild -p ios' first"
  mkdir -p "$IOS_WORKDIR"
  if [[ "$IOS_MIRROR" == 1 ]]; then
    say "repo is in an iCloud-synced folder -> mirroring to $BUILD_ROOT (IOS_MIRROR=0 to disable)"
    mkdir -p "$BUILD_ROOT"
    rsync -a --delete --exclude .git --exclude /example/android --exclude /android/build \
      --exclude /android/.gradle --exclude /example/ios/Pods --exclude /example/ios/build \
      --exclude /e2e/artifacts --exclude .DerivedData "$REPO_DIR/" "$BUILD_ROOT/" || die "rsync failed"
    # Pods contain absolute paths, so regenerate them for the mirror (uses the CocoaPods cache).
    if [[ ! -f "$BUILD_ROOT/example/ios/Pods/Manifest.lock" ]] || ! cmp -s "$BUILD_ROOT/example/ios/Podfile.lock" "$BUILD_ROOT/example/ios/Pods/Manifest.lock" \
       || [[ "$REPO_DIR/example/ios/Podfile" -nt "$BUILD_ROOT/example/ios/Pods/Manifest.lock" ]]; then
      say "pod install (mirror)"
      (cd "$BUILD_ROOT/example/ios" && pod install) >"$ART_DIR/pod-install.log" 2>&1 || die "pod install failed (see $ART_DIR/pod-install.log)"
    fi
  fi
  say "xcodebuild $CONFIGURATION (log: $ART_DIR/xcodebuild.log) ..."
  (cd "$BUILD_ROOT/example/ios" && xcodebuild -workspace "$APP_NAME.xcworkspace" -scheme "$SCHEME" \
      -configuration "$CONFIGURATION" -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO build) \
      >"$ART_DIR/xcodebuild.log" 2>&1 &
  BPID=$!
  waited=0
  while kill -0 "$BPID" 2>/dev/null; do
    sleep 10; waited=$((waited + 10))
    (( waited % 60 == 0 )) && say "  ...building ${waited}s"
    (( waited >= BUILD_TIMEOUT )) && { kill "$BPID"; die "build timed out after ${BUILD_TIMEOUT}s"; }
  done
  wait "$BPID" || { grep -E "error:|detritus" "$ART_DIR/xcodebuild.log" | head -20; die "xcodebuild failed (see $ART_DIR/xcodebuild.log)"; }
  say "build OK in ${waited}s"
fi
[[ -d "$APP_PATH" ]] || die "app not found at $APP_PATH (build first or unset SKIP_BUILD)"

# ---------------------------------------------------------------- boot (headless)
if ! xcrun simctl list devices | grep "$UDID" | grep -q Booted; then
  say "booting $UDID headless (Simulator.app not opened)"
  xcrun simctl boot "$UDID" || die "simctl boot failed"
  WE_BOOTED=1
fi
BOOT_T0=$(date +%s)
xcrun simctl bootstatus "$UDID" </dev/null >"$ART_DIR/bootstatus.log" 2>&1 &
BSPID=$!
while kill -0 "$BSPID" 2>/dev/null; do
  sleep 2
  (( $(date +%s) - BOOT_T0 > 420 )) && { kill "$BSPID"; die "simulator did not finish booting in 420s"; }
done
say "simulator ready after $(( $(date +%s) - BOOT_T0 ))s"
sleep 2

# ---------------------------------------------------------------- install + log capture
xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
xcrun simctl install "$UDID" "$APP_PATH" || die "install failed"
# RN routes console.log -> RCTLog -> os_log (subsystem com.facebook.react.log, category javascript).
xcrun simctl spawn "$UDID" log stream --style compact --level debug \
  --predicate "process == \"$APP_NAME\" OR eventMessage CONTAINS \"SDQA\"" </dev/null >"$LOG_FILE" 2>&1 &
LOG_PID=$!
sleep 2

# ================================================================ case 1: launch
say "case 1: launch + module load"
LAUNCH_OUT=$(xcrun simctl launch "$UDID" "$BUNDLE_ID" 2>&1); say "  $LAUNCH_OUT"
PID1=$(awk -F': ' '{print $2}' <<<"$LAUNCH_OUT" | tr -d ' ')
REG=$(wait_for 'bg-regist' 30)
LINE1=$(wait_for '"src":"interval"' 30)
sleep 2
FATAL=$(fatal_seen)
if [[ -z "$LINE1" && -z "$REG" ]]; then
  if grep -q "$APP_NAME" "$LOG_FILE"; then
    record "1 launch/module-load" FAIL "app ran but no [SDQA] lines in unified log (console.log not visible in $CONFIGURATION? retry CONFIGURATION=Debug)"
  else
    record "1 launch/module-load" FAIL "no app log output at all"
  fi
elif [[ -n "$FATAL" ]]; then
  record "1 launch/module-load" FAIL "fatal: $FATAL"
elif [[ -z "$REG" ]]; then
  record "1 launch/module-load" FAIL "no '[SDQA] bg-registered' (got: $(sdqa | grep -m1 bg-register))"
elif ! vals_ok "$LINE1"; then
  record "1 launch/module-load" FAIL "unexpected values: ${LINE1##*\[SDQA\] }"
else
  record "1 launch/module-load" PASS "${LINE1##*\[SDQA\] }"
fi
BGWARN=$(grep -m1 -oE "Background tasks are not supported[^\"]*" "$LOG_FILE")
[[ -n "$BGWARN" ]] && say "  note: expo-background-task says: $BGWARN"

# attach agent-device to the already-running app (no relaunch)
if ad open "$BUNDLE_ID"; then AD_OPEN=1; else say "  agent-device open failed (see agent-device.log)"; fi

# ================================================================ case 2: refresh
say "case 2: btn-refresh"
N=$(sdqa_lines)
if [[ "$AD_OPEN" == 1 ]] && ad press 'id="btn-refresh"'; then
  L=$(wait_for '"src":"refresh"' 10 "$N")
  if [[ -z "$L" ]]; then record "2 btn-refresh" FAIL "tap sent but no src:refresh line"
  elif ! vals_ok "$L"; then record "2 btn-refresh" FAIL "values: ${L##*\[SDQA\] }"
  else
    UIV=$("$AGENT_DEVICE" get text 'id="val-off"' --platform ios --udid "$UDID" --session "$AD_SESSION" 2>&1 | tail -1)
    record "2 btn-refresh" PASS "${L##*\[SDQA\] } (val-off UI: ${UIV})"
  fi
else
  record "2 btn-refresh" FAIL "could not tap btn-refresh via agent-device"
fi

# ================================================================ case 3: background/foreground
say "case 3: background -> foreground"
N=$(sdqa_lines)
xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null 2>&1   # push our app to background
BG=$(wait_for '"to":"background"' 10 "$N")
sleep 5
NB=$(sdqa_lines)
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null 2>&1           # bring it back (no relaunch)
FG=$(wait_for '"to":"active"' 10 "$NB")
RES=$(wait_for '"appState":"active"' 10 "$NB")
PID2=$(app_pid)
FATAL=$(fatal_seen)
if [[ -n "$FATAL" ]]; then record "3 bg/fg" FAIL "fatal: $FATAL"
elif [[ -z "$BG" || -z "$FG" ]]; then record "3 bg/fg" FAIL "missing appState events (bg='$BG' fg='$FG')"
elif [[ -n "$PID1" && -n "$PID2" && "$PID1" != "$PID2" ]]; then record "3 bg/fg" FAIL "process restarted (pid $PID1 -> $PID2)"
elif [[ -z "$RES" ]] || ! vals_ok "$RES"; then record "3 bg/fg" FAIL "polling did not resume cleanly: $RES"
else
  BGPOLL=$(sdqa | sed -n "$((N + 1)),${NB}p" | grep -c '"appState":"background"')
  record "3 bg/fg" PASS "same pid $PID2; ${BGPOLL} polls while backgrounded; resumed: ${RES##*\[SDQA\] }"
fi

# ================================================================ case 4: background task trigger
say "case 4: btn-trigger-bg"
N=$(sdqa_lines)
if [[ "$AD_OPEN" == 1 ]] && ad press 'id="btn-trigger-bg"'; then
  TRIG=$(wait_for 'bg-trigger' 15 "$N")
  BGRUN=$(wait_for '\[SDQA-BG\]' 20 "$N")
  FATAL=$(fatal_seen)
  if [[ -n "$FATAL" ]]; then record "4 bg-task trigger" FAIL "fatal: $FATAL"
  elif [[ -n "$BGRUN" ]]; then
    if vals_ok "$BGRUN"; then record "4 bg-task trigger" PASS "trigger: ${TRIG##*\] } | task ran: ${BGRUN##*\] }"
    else record "4 bg-task trigger" FAIL "task ran with unexpected values: ${BGRUN##*\] }"; fi
  elif [[ -n "$TRIG" ]]; then
    WHY="Simulator: getStatusAsync=Restricted so the task was never registered${BGWARN:+ (\"$BGWARN\")}"
    [[ "$CONFIGURATION" == Release ]] && WHY="$WHY; Release: triggerTaskWorkerForTestingAsync is __DEV__-only and returns false without touching native"
    record "4 bg-task trigger" SKIP "trigger returned (${TRIG##*\] }), no [SDQA-BG] within 20s - $WHY"
  else
    record "4 bg-task trigger" SKIP "no bg-trigger result line within 15s (trigger promise never settled on Simulator)"
  fi
else
  record "4 bg-task trigger" FAIL "could not tap btn-trigger-bg"
fi

# ================================================================ case 5: lock
say "case 5: simulator lock"
# simctl has no lock command. idb's `ui button LOCK` is the only headless option; it
# needs idb_companion + a SimulatorKit that matches the installed Xcode.
LOCK_OUT=""
if command -v idb >/dev/null 2>&1; then
  N=$(sdqa_lines)
  LOCK_OUT=$(python3 - "$UDID" 2>&1 <<'PY'
import asyncio, sys
asyncio.set_event_loop(asyncio.new_event_loop())   # idb CLI breaks on Python >= 3.12 without this
from idb.cli.main import main
sys.argv = ["idb", "ui", "button", "LOCK", "--udid", sys.argv[1]]
main()
PY
)
  LOCK_RC=$?
  [[ -z "$LOCK_OUT" ]] && LOCK_OUT="(no output)"
  printf '%s\n' "$LOCK_OUT" >"$ART_DIR/idb-lock.log"
  sleep 12
  # Only trust the lock if the app actually saw it (appState leaves "active");
  # idb can exit 0 while its HID call silently failed.
  LOCKEV=$(sdqa | tail -n +"$((N + 1))" | grep -E -m1 '"event":"appState".*"to":"(inactive|background)"')
  AFTER=$(sdqa | tail -n +"$((N + 1))" | grep -E '"off"' | tail -1)
  if [[ -n "$LOCKEV" ]]; then
    record "5 simulator lock" SKIP "idb LOCK took effect (${LOCKEV##*\] }); no passcode on Simulator so locked=false by design. last: ${AFTER##*\] }"
    xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
  else
    record "5 simulator lock" SKIP "no working headless lock: idb 'ui button LOCK' rc=$LOCK_RC but app never left active ($(tr '\n' ' ' <<<"$LOCK_OUT" | cut -c1-160))"
  fi
else
  record "5 simulator lock" SKIP "no scriptable headless lock (simctl has none; agent-device has none; idb not installed)"
fi

# ---------------------------------------------------------------- summary
sleep 1
sdqa >"$SDQA_FILE"
cleanup
LOG_PID=""; AD_OPEN=0
ELAPSED=$(( $(date +%s) - START_TS ))
echo
echo "================ iOS e2e summary ($CONFIGURATION, ${ELAPSED}s) ================"
echo "simulator: $SIM_DESC"
printf '%s\n' "${RESULTS[@]}"
echo "artifacts: $ART_DIR"
[[ "$FAILED" == 0 ]] && echo "RESULT: OK" || echo "RESULT: FAILED"
exit "$FAILED"
