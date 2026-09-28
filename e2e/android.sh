#!/usr/bin/env bash
# Android e2e for expo-screen-detector.
#
# Drives the example app (release APK, no Metro) on an emulator/device and
# asserts on logcat output of the SDQA_BG background task (expo-background-task
# / WorkManager) under different screen / keyguard states.
#
# Env overrides:
#   ANDROID_SERIAL   device serial (default: emulator-5554)
#   APK              path to the APK (default: example release APK)
#   PIN              temporary PIN used for the locked cases (default: 1234)
#   SKIP_INSTALL=1   don't (re)install the APK
#   JOB_WAIT / JOB_ATTEMPTS / LAUNCH_WAIT   timeouts (s) / retries
#   E2E_LOG_OUT      copy the captured ReactNativeJS log here
#
# Build the APK first:
#   cd example/android && ./gradlew assembleRelease -PreactNativeArchitectures=arm64-v8a
#
# NOTE: this script temporarily sets a device PIN. A trap always clears it.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ANDROID_SERIAL="${ANDROID_SERIAL:-emulator-5554}"
APK="${APK:-$ROOT/example/android/app/build/outputs/apk/release/app-release.apk}"
PKG="expo.modules.screendetector.example"
PIN="${PIN:-1234}"
JOB_WAIT="${JOB_WAIT:-40}"        # seconds to wait for [SDQA-BG] per force-run
JOB_ATTEMPTS="${JOB_ATTEMPTS:-3}" # force-run attempts per case
LAUNCH_WAIT="${LAUNCH_WAIT:-180}" # seconds to wait for app start + first logs

ADB=(adb -s "$ANDROID_SERIAL")
FAILS=0
RESULTS=()
PIN_SET=0
LOCK_WAS_DISABLED=""
START_TS=$(date +%s)

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
sh_()  { "${ADB[@]}" shell "$@" 2>/dev/null | tr -d '\r'; }
pass() { RESULTS+=("PASS  $1${2:+  | $2}"); log "PASS: $1 ${2:-}"; }
fail() { RESULTS+=("FAIL  $1${2:+  | $2}"); log "FAIL: $1 ${2:-}"; FAILS=$((FAILS + 1)); }

# Logcat is streamed to local files once (adb/logcat -d can be very slow on a
# loaded host); "marks" are line numbers in those files.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sd-e2e-android.XXXXXX")"
JSLOG="$WORK/js.log"; CRASHLOG="$WORK/crash.log"
LOGCAT_PIDS=()
start_logcat() {
  : >"$JSLOG"; : >"$CRASHLOG"
  "${ADB[@]}" logcat -v time -T 1 -s ReactNativeJS:V >"$JSLOG" 2>/dev/null & LOGCAT_PIDS+=($!)
  "${ADB[@]}" logcat -b crash -v time -T 1 >"$CRASHLOG" 2>/dev/null & LOGCAT_PIDS+=($!)
}
stop_logcat() { for p in "${LOGCAT_PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done; }
mark() { wc -l <"$JSLOG" | tr -d ' '; }
# JS log lines after mark $1 matching regex $2
logs_since() { tail -n +"$(($1 + 1))" "$JSLOG" | tr -d '\r' | grep -E "$2"; }

# Screen state via window policy's mAwake (dumpsys power was observed to stall
# for >60s on a loaded host). Prints Awake/Asleep.
wakefulness() {
  case "$(sh_ "dumpsys window | grep -m1 -oE 'mAwake=(true|false)'")" in
    mAwake=true) echo Awake ;; mAwake=false) echo Asleep ;; *) echo unknown ;;
  esac
}
keyguard_showing() {
  # "true"/"false" from window policy / keyguard controller
  local v
  v=$(sh_ "dumpsys window | grep -E 'KeyguardShowing'" | grep -oE '(mKeyguardShowing|isKeyguardShowing|KeyguardShowing)=(true|false)' | head -1 | cut -d= -f2)
  echo "${v:-unknown}"
}

screen_size() {
  local s; s=$(sh_ wm size | grep -oE '[0-9]+x[0-9]+' | tail -1)
  W=${s%x*}; H=${s#*x}; W=${W:-1080}; H=${H:-2400}
}

wake_up() { sh_ input keyevent KEYCODE_WAKEUP >/dev/null; }
sleep_screen() {
  sh_ input keyevent KEYCODE_SLEEP >/dev/null
  for _ in $(seq 1 20); do [[ "$(wakefulness)" == "Asleep" ]] && return 0; sleep 0.5; done
  return 1
}

# Unlock in one shell invocation (keyguard has its own ~10s bouncer timeout).
unlock() {
  screen_size
  local x=$((W / 2)) y1=$((H * 80 / 100)) y2=$((H * 25 / 100))
  for _ in 1 2 3; do
    if [[ "$PIN_SET" == 1 ]]; then
      sh_ "input keyevent KEYCODE_WAKEUP && input swipe $x $y1 $x $y2 300 && input text $PIN && input keyevent 66" >/dev/null
    else
      sh_ "input keyevent KEYCODE_WAKEUP && input swipe $x $y1 $x $y2 300" >/dev/null
    fi
    sleep 1.5
    [[ "$(keyguard_showing)" != "true" ]] && return 0
  done
  return 1
}

# Job id(s) of our app's WorkManager SystemJobService jobs.
job_ids() {
  sh_ "dumpsys jobscheduler | grep -E 'JOB #[^ ]+: [0-9a-f]+ ${PKG}/'" \
    | sed -E 's/.*JOB #[^/]+\/(-?[0-9]+):.*/\1/' | sort -u
}

# force-run our job and wait for an [SDQA-BG] line; echoes the line.
# Retries (re-resolving the job id each time) up to JOB_ATTEMPTS.
force_run_and_capture() {
  local since line ids id attempt t_force
  for attempt in $(seq 1 "$JOB_ATTEMPTS"); do
    ids=""
    for _ in $(seq 1 20); do ids=$(job_ids); [[ -n "$ids" ]] && break; sleep 1; done
    if [[ -z "$ids" ]]; then log "  no scheduled job for $PKG (attempt $attempt)"; continue; fi
    since=$(mark)
    t_force=$(( $(sh_ date +%s) * 1000 ))
    for id in $ids; do
      log "  force-run job $id (attempt $attempt)"
      sh_ cmd jobscheduler run -f "$PKG" "$id" >/dev/null
    done
    for _ in $(seq 1 "$JOB_WAIT"); do
      # only accept a line produced by this force-run (t >= device time at force)
      line=$(logs_since "$since" '\[SDQA-BG\]' | awk -v t0="$t_force" '
        /ERROR/ {print; next}
        match($0, /"t":[0-9]+/) { if (substr($0, RSTART+4, RLENGTH-4) + 0 >= t0) print }' | tail -1)
      if [[ -n "$line" ]]; then
        [[ "$attempt" -gt 1 ]] && log "  (needed $attempt attempts)"
        echo "$line"; return 0
      fi
      sleep 1
    done
    log "  no [SDQA-BG] within ${JOB_WAIT}s"
  done
  return 1
}

# assert_bg <case-name> <off> <locked> <unavailable>
assert_bg() {
  local name="$1" off="$2" locked="$3" unav="$4" line payload
  line=$(force_run_and_capture | tail -1)
  if [[ -z "$line" || "$line" != *"[SDQA-BG]"* ]]; then fail "$name" "no [SDQA-BG] output"; return; fi
  payload="${line#*\[SDQA-BG\] }"
  if [[ "$payload" == ERROR* ]]; then fail "$name" "$payload"; return; fi
  if [[ "$payload" == *"\"off\":$off"* && "$payload" == *"\"locked\":$locked"* && "$payload" == *"\"unavailable\":$unav"* ]]; then
    pass "$name" "$payload"
  else
    fail "$name" "expected off=$off locked=$locked unavailable=$unav, got $payload (screen=$(wakefulness) keyguard=$(keyguard_showing))"
  fi
}

cleanup() {
  local rc=$?
  log "cleanup: unlocking and clearing PIN"
  wake_up
  if [[ "$PIN_SET" == 1 ]]; then
    unlock || log "  warn: keyguard still showing after unlock attempts"
    sh_ locksettings clear --old "$PIN" >/dev/null
    PIN_SET=0
  fi
  # restore "no lock screen" if that was the initial state
  [[ "$LOCK_WAS_DISABLED" == "true" ]] && sh_ locksettings set-disabled true >/dev/null
  wake_up
  local dis="" nopin="" i
  for i in 1 2 3 4 5; do  # retry: adb shell can return empty on a loaded host
    "${ADB[@]}" wait-for-device
    dis=$(sh_ locksettings get-disabled); nopin=$(sh_ locksettings verify 2>&1)
    [[ -n "$dis" && -n "$nopin" ]] && break; sleep 3
  done
  log "  final: screen=$(wakefulness) keyguard=$(keyguard_showing) get-disabled=$dis"
  [[ -n "$LOCK_WAS_DISABLED" && "$dis" != "$LOCK_WAS_DISABLED" ]] && fail "cleanup-disabled" "get-disabled=$dis (expected $LOCK_WAS_DISABLED)"
  if [[ "$nopin" == *"verified successfully"* ]]; then pass "cleanup" "PIN cleared, get-disabled=$dis"
  else fail "cleanup" "credential still set: $nopin"; fi

  # global checks
  local errs crash
  errs=$(logs_since "$RUN_SINCE" '\[SDQA-BG\] ERROR|\[SDQA\] (ERROR|bg-register-error)')
  [[ -n "$errs" ]] && fail "no-errors" "$(echo "$errs" | head -3)" || pass "no-errors"
  sleep 1; stop_logcat
  crash=$(tr -d '\r' <"$CRASHLOG" | grep -F "$PKG")
  [[ -n "$crash" ]] && fail "no-crash" "$(echo "$crash" | head -3)" || pass "no-crash"

  echo
  echo "================ Android e2e results ($ANDROID_SERIAL) ================"
  printf '%s\n' "${RESULTS[@]}"
  echo "Runtime: $(( $(date +%s) - START_TS ))s   Failures: $FAILS"
  [[ -n "${E2E_LOG_OUT:-}" ]] && cp "$JSLOG" "$E2E_LOG_OUT"; echo "JS log: ${E2E_LOG_OUT:-$JSLOG}"
  [[ "$FAILS" -gt 0 || $rc -ne 0 ]] && exit 1
  exit 0
}

# ---------------------------------------------------------------- preflight
"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "device $ANDROID_SERIAL not available"; exit 2; }
for _ in 1 2 3 4 5; do
  LOCK_WAS_DISABLED=$(sh_ locksettings get-disabled); PRE_VERIFY=$(sh_ locksettings verify 2>&1)
  [[ -n "$LOCK_WAS_DISABLED" && -n "$PRE_VERIFY" ]] && break; sleep 3
done
if [[ "$PRE_VERIFY" != *"verified successfully"* ]]; then
  echo "device already has a lock credential set; refusing to run (would not be able to restore it)"; exit 2
fi
start_logcat
sleep 2
RUN_SINCE=0
trap cleanup EXIT
trap 'exit 130' INT TERM

wake_up
unlock >/dev/null 2>&1 || true

# ------------------------------------------------------ case 1: install+launch
log "case 1: install + launch"
if [[ "${SKIP_INSTALL:-0}" != 1 ]]; then
  [[ -f "$APK" ]] || { fail "1 install+launch" "APK not found: $APK"; exit 1; }
  ok=0
  for i in 1 2 3; do
    "${ADB[@]}" wait-for-device
    out=$("${ADB[@]}" install -r -t "$APK" 2>&1) && { ok=1; break; }
    log "  install attempt $i failed: $(echo "$out" | tail -1)"; sleep 5
  done
  [[ $ok == 1 ]] || { fail "1 install+launch" "adb install failed: $(echo "$out" | tail -1)"; exit 1; }
fi
sh_ am force-stop "$PKG"
C1=$(mark)
reg=""; fg=""; launches=0; t0=$(date +%s)
while (( $(date +%s) - t0 < LAUNCH_WAIT )); do
  # (re)launch if the process is gone (a heavily loaded emulator can ANR-kill
  # the app during startup: "failed to complete startup")
  if [[ -z "$(sh_ pidof "$PKG")" ]]; then
    if (( launches >= 3 )); then break; fi
    launches=$((launches + 1)); log "  launch #$launches"
    sh_ monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null
  fi
  reg=$(logs_since "$C1" '\[SDQA\] bg-registered' | tail -1)
  fg=$(logs_since "$C1" '\[SDQA\] \{"t":[0-9]+,"src"' | grep '"appState":"active"' | tail -1)
  [[ -n "$reg" && -n "$fg" ]] && break
  sleep 2
done
(( launches > 1 )) && log "  needed $launches launches"
if [[ -z "$reg" ]]; then fail "1 install+launch" "no bg-registered"
elif [[ -z "$fg" ]]; then fail "1 install+launch" "no foreground [SDQA] line"
elif [[ "$fg" == *'"off":false'* && "$fg" == *'"locked":false'* && "$fg" == *'"unavailable":false'* ]]; then
  pass "1 install+launch" "${fg#*\[SDQA\] }"
else fail "1 install+launch" "${fg#*\[SDQA\] }"; fi

# ------------------------------------------ case 2: background, screen on, no PIN
log "case 2: backgrounded, screen on, no PIN"
sh_ input keyevent KEYCODE_HOME >/dev/null
sleep 2
assert_bg "2 bg/screen-on/no-PIN" false false false

# ---------------------------------------------- case 3: screen off, no PIN
log "case 3: screen off, no PIN"
sleep_screen || log "  warn: screen did not reach Asleep"
sleep 1
assert_bg "3 screen-off/no-PIN" true false true
wake_up; sleep 1

# ------------------------------------------------ case 4: PIN set, screen off
log "case 4: PIN set, screen off"
if sh_ locksettings set-pin "$PIN" | grep -qi 'set to'; then PIN_SET=1; else
  PIN_SET=1  # assume set; cleanup clears with --old regardless
  log "  warn: set-pin output unexpected"
fi
sleep 1
sleep_screen || log "  warn: screen did not reach Asleep"
# wait for keyguard to engage
for _ in $(seq 1 15); do [[ "$(keyguard_showing)" == "true" ]] && break; sleep 1; done
log "  keyguard=$(keyguard_showing) screen=$(wakefulness)"
assert_bg "4 PIN/screen-off" true true true

# ---------------------------------- case 5: PIN set, screen on at keyguard
log "case 5: PIN set, screen on at keyguard (not unlocked)"
wake_up
for _ in $(seq 1 10); do [[ "$(wakefulness)" == "Awake" ]] && break; sleep 0.5; done
log "  keyguard=$(keyguard_showing) screen=$(wakefulness)"
assert_bg "5 PIN/keyguard/screen-on" false true true

# cleanup (trap) runs on exit
