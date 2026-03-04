# expo-screen-detector

Expo module for detecting screen-off, screen-lock, and screen-unavailable state on iOS and Android.

## Installation

```bash
npm install github:sbigstar0310/expo-screen-detector
```

After installing, rebuild your native apps:

```bash
npx expo run:ios
npx expo run:android
```

## API

```typescript
import ExpoScreenDetector from "expo-screen-detector";
```

### `isScreenOff(): Promise<boolean>`

Returns `true` if the device screen is off.

- **iOS**: Checks if `UIScreen.main.brightness == 0`
- **Android**: Checks `PowerManager.isInteractive` (returns `true` when not interactive)

### `isScreenLocked(): Promise<boolean>`

Returns `true` if the device is locked.

- **iOS**: Checks if protected data is unavailable (`!UIApplication.shared.isProtectedDataAvailable`)
- **Android**: Checks `KeyguardManager.isKeyguardLocked`

### `isScreenUnavailable(): Promise<boolean>`

Returns `true` if the screen is off **or** locked (combines both checks).

## Requirements

- Expo SDK 50+
- iOS 15.1+
- Android (no minimum version requirement beyond Expo defaults)

## License

MIT
