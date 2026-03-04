import ExpoModulesCore
import UIKit

public class ExpoScreenDetectorModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoScreenDetector")

    AsyncFunction("isScreenOff") { () -> Bool in
      await MainActor.run {
        UIScreen.main.brightness == 0
      }
    }

    AsyncFunction("isScreenLocked") { () -> Bool in
      await MainActor.run {
        !UIApplication.shared.isProtectedDataAvailable
      }
    }

    AsyncFunction("isScreenUnavailable") { () -> Bool in
      await MainActor.run {
        let screenOff = UIScreen.main.brightness == 0
        let locked = !UIApplication.shared.isProtectedDataAvailable
        return screenOff || locked
      }
    }
  }
}
