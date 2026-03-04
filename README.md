# expo-screen-detector

[![npm version](https://img.shields.io/npm/v/expo-screen-detector?style=for-the-badge)](https://www.npmjs.com/package/expo-screen-detector)
[![npm downloads](https://img.shields.io/npm/dt/expo-screen-detector?style=for-the-badge)](https://www.npmjs.com/package/expo-screen-detector)
[![license](https://img.shields.io/github/license/sbigstar0310/expo-screen-detector?style=for-the-badge)](./LICENSE)
[![platform - android](https://img.shields.io/badge/platform-Android-3ddc84.svg?logo=android&style=for-the-badge)](https://www.android.com)
[![platform - ios](https://img.shields.io/badge/platform-iOS-000.svg?logo=apple&style=for-the-badge)](https://developer.apple.com/ios)

React Native doesn't expose native APIs for detecting when the screen turns off or the device locks. **expo-screen-detector** bridges these platform APIs so you can respond to screen state changes in your JS/TS code.

- **Screen off** — brightness zero (iOS) or display not interactive (Android)
- **Screen locked** — protected data unavailable (iOS) or keyguard active (Android)
- **Screen unavailable** — combined check (off OR locked)

## Installation

```bash
npm install expo-screen-detector
```

This module contains native code. After installing, rebuild your app:

```bash
npx expo run:ios
npx expo run:android
```

No additional native configuration is required — Expo autolinking handles module registration on both platforms.

> **Note**: This module requires a [development build](https://docs.expo.dev/develop/development-builds/introduction/). It does not work with Expo Go.

## Quick Start

```typescript
import ExpoScreenDetector from "expo-screen-detector";

async function checkScreenState() {
  const isOff = await ExpoScreenDetector.isScreenOff();
  const isLocked = await ExpoScreenDetector.isScreenLocked();
  const isUnavailable = await ExpoScreenDetector.isScreenUnavailable();

  console.log({ isOff, isLocked, isUnavailable });
}
```

### Background Task Example

```typescript
import ExpoScreenDetector from "expo-screen-detector";

// Inside a background task handler
const unavailable = await ExpoScreenDetector.isScreenUnavailable();
if (unavailable) {
  // Screen is off or locked — safe to run background work
  await performBackgroundSync();
}
```

## API

| Function | Returns | Description |
|---|---|---|
| `isScreenOff()` | `Promise<boolean>` | `true` if the screen is off |
| `isScreenLocked()` | `Promise<boolean>` | `true` if the device is locked |
| `isScreenUnavailable()` | `Promise<boolean>` | `true` if the screen is off **or** locked |

### `isScreenOff()`

Returns `true` when the device screen is off.

| Platform | Native API |
|---|---|
| iOS | `UIScreen.main.brightness == 0` |
| Android | `!PowerManager.isInteractive` |

### `isScreenLocked()`

Returns `true` when the device is locked.

| Platform | Native API |
|---|---|
| iOS | `!UIApplication.shared.isProtectedDataAvailable` |
| Android | `KeyguardManager.isKeyguardLocked` |

### `isScreenUnavailable()`

Returns `true` when the screen is off **or** the device is locked. This is a convenience method that combines both checks into a single call.

## Compatibility

| expo-screen-detector | Expo SDK | React Native |
|---|---|---|
| 0.1.x | 50+ | 0.73+ |

### Platform Requirements

- **iOS**: 15.1+
- **Android**: API 24+ (Expo default minSdk)

## Contributing

Contributions are welcome! Feel free to open an issue or submit a pull request.

## License

MIT — see [LICENSE](./LICENSE) for details.
