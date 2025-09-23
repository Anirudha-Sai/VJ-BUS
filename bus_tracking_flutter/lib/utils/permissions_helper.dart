// lib/utils/permissions_helper.dart

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionsHelper {
  /// Checks and requests all necessary permissions for location tracking.
  /// Returns `true` if all critical permissions are granted.
  static Future<bool> checkAndRequestPermissions() async {
    // Request Notification permission first (for Android 13+).
    await Permission.notification.request();

    // Request foreground location permission.
    var locationStatus = await Permission.location.request();
    if (!locationStatus.isGranted) {
      // If foreground location is denied, we cannot proceed.
      return false;
    }

    // If foreground is granted, check and request background permission.
    var backgroundStatus = await Permission.locationAlways.status;
    if (!backgroundStatus.isGranted) {
      // This will either show a dialog or the user has to go to settings.
      await Permission.locationAlways.request();
    }

    // Check battery optimization status and request if not ignored.
    var batteryStatus = await Permission.ignoreBatteryOptimizations.status;
    if (!batteryStatus.isGranted) {
      await Permission.ignoreBatteryOptimizations.request();
    }

    // The core requirement is foreground location. Background is for enhancement.
    return await Permission.location.isGranted;
  }

  /// Shows a dialog to guide the user to app settings if background location is denied.
  static void showBackgroundPermissionDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Enable Background Location"),
        content: const Text(
            "To ensure the bus can be tracked at all times, please set location permission to 'Allow all the time' in the app settings."),
        actions: [
          TextButton(
            child: const Text("Cancel"),
            onPressed: () => Navigator.pop(dialogContext),
          ),
          TextButton(
            child: const Text("Open Settings"),
            onPressed: () {
              Navigator.pop(dialogContext);
              openAppSettings(); // From permission_handler package
            },
          ),
        ],
      ),
    );
  }
}
