# iOS real-device checklist

This is a manual test plan for the parts of `expo-screen-detector` that the iOS Simulator can't exercise. `e2e/ios.sh` covers app launch, module loading, refresh and the background/foreground cycle. It can't cover lock, screen-off or background tasks.

## Why a real device is needed

| Limitation on the Simulator | Effect |
|---|---|
| No passcode, so Data Protection is never active | `isProtectedDataAvailable` stays `true`, so `isScreenLocked()` is always `false` |
| `UIScreen.main.brightness` is fixed (0.5 is commonly reported) | `isScreenOff()` is always `false` |
| No working headless lock (simctl has no lock command; `idb ui button LOCK` needs a SimulatorKit that matches Xcode) | Lock can't be scripted |
| `BGTaskScheduler` doesn't run tasks | `getStatusAsync()` reports `Restricted`, so `registerTaskAsync` only warns *"Background tasks are not supported on iOS simulators. Skipped registering task"* and returns. The example still logs `[SDQA] bg-registered` because it can't tell the difference. `[SDQA-BG]` never fires |

## How the current implementation decides (`ios/ExpoScreenDetectorModule.swift`)

- `isScreenOff` is `UIScreen.main.brightness == 0`
- `isScreenLocked` is `!UIApplication.shared.isProtectedDataAvailable`
- `isScreenUnavailable` is `isScreenOff || isScreenLocked`

## Setup

1. Turn on a passcode on the device (Settings → Face ID & Passcode). Without one, `locked` can never become `true`.
2. Build the example app to the device: `cd example && npx expo run:ios --device --configuration Release`. Use Debug instead if you want Xcode's debugger for step 6.
3. Watch the logs in one of these places: the Xcode console, Console.app (device → filter `SDQA`), or `xcrun devicectl device process launch --console ...`. The app logs `[SDQA] {...}` once per second.
4. Note that iOS protects data about 10 s after lock, not immediately, when "Require Passcode" is set to *Immediately*. Always read values at least 10 s after locking.

## Cases

| # | Steps | Expected with current implementation | Notes |
|---|---|---|---|
| 1 | Unlocked, screen on, app in foreground | `off=false locked=false unavailable=false` | Baseline |
| 2 | Press the side button to lock, wait at least 10 s, read the `[SDQA]` / `[SDQA-BG]` lines logged while locked. The app is suspended soon after, so rely on the last lines before suspension or on the BG task (case 6) | `locked=true unavailable=true` once protected data becomes unavailable (after about 10 s). `off=false` | `off` does not flip to `true` when the display turns off. See the note below |
| 3 | Unlock with Face ID or passcode and return to the app | Polling resumes. `off=false locked=false unavailable=false` within about 1 s | No crash. `appState` goes `background`/`inactive`, then `active` |
| 4 | Screen on, drag Control Center brightness to minimum | Brightness minimum is usually not exactly 0 (for example 0.0 to 0.03), so expect `off=false`. If it reads 0, you get `off=true unavailable=true` **while the screen is visibly on** | This is a false positive whenever brightness is exactly 0 |
| 5 | Lock without a passcode (turn the passcode off temporarily) | `locked=false` always | By design, because protected data is always available without a passcode |
| 6 | Background task: launch from Xcode (Debug), tap **Trigger background task** (or just background the app), pause in the debugger, then run:<br>`e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.expo.modules.backgroundtask.processing"]`<br>then continue | A `[SDQA-BG] {"off":...,"locked":...,"unavailable":...}` line with no ERROR. If you trigger it while locked (lock the device, then resume the debugger after at least 10 s), expect `locked=true unavailable=true` | The identifier is taken from `example/ios/exposcreendetectorexample/Info.plist` → `BGTaskSchedulerPermittedIdentifiers`. The task must be registered first: the app must have launched once and logged `[SDQA] bg-registered` |
| 7 | **Debug build**: tap **Trigger background task** | `[SDQA] bg-trigger {"result":...}` followed by `[SDQA-BG] {...}` shortly after | `triggerTaskWorkerForTestingAsync()` works only when `__DEV__` is true. In a **Release** build it returns `false` without calling native code, on devices as well as the Simulator. Use case 6 for Release |
| 8 | Auto-Lock: set 30 s, leave the app idle until the screen dims and locks | The same as case 2 once locked | Checks the idle-lock path, not the side-button path |

## Suspected wrong behavior (for follow-up)

- **`isScreenOff` uses brightness.** `UIScreen.brightness` is the backlight *setting*. It is not the display power state, so it doesn't change when the screen turns off or locks. Two problems follow:
  - False negatives: the screen is off, but `off=false`.
  - False positives: the user set brightness to 0 while the screen is on, and `off=true`.
- **Better signals to try:**
  - `UIApplication.protectedDataWillBecomeUnavailableNotification` and `protectedDataDidBecomeAvailableNotification`
  - `applicationState` together with `UIScene` activation state
  - The Darwin notification `com.apple.springboard.hasBlankedScreen`: on-device only, and a private API risk
- **`isScreenLocked` returns `false` on devices without a passcode.** Document this limitation in the README.
