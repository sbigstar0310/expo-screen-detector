import { requireNativeModule } from "expo-modules-core";

export default requireNativeModule<{
  isScreenOff(): Promise<boolean>;
  isScreenLocked(): Promise<boolean>;
  isScreenUnavailable(): Promise<boolean>;
}>("ExpoScreenDetector");
