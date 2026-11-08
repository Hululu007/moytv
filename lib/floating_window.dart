import 'package:flutter/services.dart';

class FloatingWindow {
  static const MethodChannel _channel = MethodChannel('moyi/floating_window');

  static Future<bool> isPermissionGranted() async {
    try {
      return await _channel.invokeMethod<bool>('isPermissionGranted') ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> requestPermission() async {
    await _channel.invokeMethod<void>('requestPermission');
  }

  static Future<bool> isShowing() async {
    try {
      return await _channel.invokeMethod<bool>('isShowing') ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> show() async {
    await _channel.invokeMethod<void>('show');
  }

  static Future<void> hide() async {
    await _channel.invokeMethod<void>('hide');
  }
}
