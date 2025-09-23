// lib/services/background_service.dart

import 'dart:async';
import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:wakelock_plus/wakelock_plus.dart';
import '../utils/constants.dart';
import '../main.dart'; // Import to access notification constants and plugin instance

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      isForegroundMode: true,
      autoStart: true,
      notificationChannelId: notificationChannelId,
      initialNotificationTitle: 'VJ Bus Service',
      initialNotificationContent: 'Initializing...',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(onForeground: onStart, autoStart: true),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  
  IO.Socket? socket;
  Timer? trackingTimer;
  String? currentRouteId;
  String? currentSocketId;

  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) => service.setAsForegroundService());
    service.on('setAsBackground').listen((event) => service.setAsBackgroundService());
  }

  // --- FIX: The listener is now async to allow for 'await' ---
  service.on('stopService').listen((event) async {
    trackingTimer?.cancel();
    
    // --- FIX: 'await' ensures the broadcast is sent before disconnecting ---
    await _sendFinalBroadcast(socket, currentRouteId, () => currentSocketId);
    
    // This code now runs only AFTER the final broadcast is complete.
    socket?.disconnect();
    WakelockPlus.disable();
    service.stopSelf();
  });

  service.on('startTracking').listen((event) {
    if (event == null) return;
    currentRouteId = event['route_id'];
    
    socket = _connectSocket(currentRouteId, "Driver");
    
    socket!.onConnect((_) {
      currentSocketId = socket!.id;
      WakelockPlus.enable();
      service.invoke('updateUI', {'isTracking': true, 'status': 'Connected'});
      trackingTimer = _startLocationUpdates(service, socket!, currentRouteId!, () => currentSocketId);
    });

    socket!.onDisconnect((_) {
      service.invoke('updateUI', {'isTracking': false, 'status': 'Connection Lost'});
      trackingTimer?.cancel();
      WakelockPlus.disable();
    });
  });
}

Timer _startLocationUpdates(ServiceInstance service, IO.Socket socket, String routeId, String? Function() getSocketId) {
  _updateNotification(title: "Tracking Active", content: "Live location is being shared for Route: $routeId");
  
  return Timer.periodic(const Duration(seconds: 5), (timer) async {
    if (!socket.connected) {
      timer.cancel();
      _updateNotification(title: "Connection Lost", content: "Attempting to reconnect...");
      return;
    }
    try {
      Position position = await Geolocator.getCurrentPosition(forceAndroidLocationManager: true);
      socket.emit("location_update", {
        "route_id": routeId,
        "latitude": position.latitude,
        "longitude": position.longitude,
        "socket_id": getSocketId(),
        "role": "Driver",
        "heading": position.heading,
        "status": "tracking_active",
      });
    } catch (e) {
      _updateNotification(title: "Location Error", content: "Failed to get current location.");
    }
  });
}

// --- FIX: This function now returns a Future<void> to be awaitable ---
Future<void> _sendFinalBroadcast(IO.Socket? socket, String? routeId, String? Function() getSocketId) async {
  if (socket == null || !socket.connected || routeId == null) return;
  try {
    Position? position = await Geolocator.getLastKnownPosition() ?? await Geolocator.getCurrentPosition();
    socket.emit("location_update", {
      "route_id": routeId,
      "latitude": position.latitude,
      "longitude": position.longitude,
      "socket_id": getSocketId(),
      "role": "Driver",
      "heading": position.heading,
      "status": "stopped",
    });
    // Add a tiny delay to ensure the message has time to be sent.
    await Future.delayed(const Duration(milliseconds: 500));
  } catch (e) {
    // Fail silently to ensure the service can stop.
  }
}

void _updateNotification({required String title, required String content}) {
  flutterLocalNotificationsPlugin.show(
    888,
    title,
    content,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        notificationChannelId,
        'VJ Bus Driver Service',
        icon: '@mipmap/ic_launcher',
        ongoing: true,
        autoCancel: false,
      ),
    ),
  );
}

IO.Socket _connectSocket(String? routeId, String role) {
  return IO.io(
    websocketUrl,
    IO.OptionBuilder()
        .setTransports(['websocket'])
        .setQuery({'role': role, 'route_id': routeId ?? 'Unknown'})
        .disableAutoConnect()
        .build(),
  )..connect();
}
