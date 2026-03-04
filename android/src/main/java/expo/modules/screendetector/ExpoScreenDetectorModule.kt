package expo.modules.screendetector

import android.app.KeyguardManager
import android.content.Context
import android.os.PowerManager
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

class ExpoScreenDetectorModule : Module() {
  override fun definition() = ModuleDefinition {
    Name("ExpoScreenDetector")

    AsyncFunction("isScreenOff") {
      val context = appContext.reactContext ?: return@AsyncFunction false
      val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
      !powerManager.isInteractive
    }

    AsyncFunction("isScreenLocked") {
      val context = appContext.reactContext ?: return@AsyncFunction false
      val keyguardManager = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
      keyguardManager.isKeyguardLocked
    }

    AsyncFunction("isScreenUnavailable") {
      val context = appContext.reactContext ?: return@AsyncFunction false
      val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
      val keyguardManager = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
      !powerManager.isInteractive || keyguardManager.isKeyguardLocked
    }
  }
}
