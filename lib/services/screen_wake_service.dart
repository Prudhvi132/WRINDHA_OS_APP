import 'package:flutter/services.dart';

/// Keeps the device screen awake while a focus timer or stopwatch is active.
class ScreenWakeService {
  static const MethodChannel _channel = MethodChannel('com.wrindha.app/wakelock');
  static bool _isEnabled = false;

  static Future<void> setKeepScreenOn(bool enabled, {bool force = false}) async {
    if (!force && _isEnabled == enabled) return;
    _isEnabled = enabled;
    try {
      await _channel.invokeMethod<void>('setKeepScreenOn', {'enabled': enabled});
    } on MissingPluginException {
      // Unsupported platforms (e.g., web or widget tests) safely ignore wake lock.
    } on PlatformException {
      // Ignore platform errors so timer state is never disrupted.
    }
  }
}
