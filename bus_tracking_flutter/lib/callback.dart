// lib/callback.dart
import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

const String websocketUrl = "wss://bus.vjstartup.com";
const int checkLocationAlarmId = 0;

// This is the entry point for the background alarm.
@pragma('vm:entry-point')
void startLocationChecks() async {
  print("ALARM FIRED: Starting location checks at 6:30 AM.");

  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final String? routeId = prefs.getString("selectedRoute");
  if (routeId == null) {
    print("ALARM ERROR: No route ID found. Cannot start tracking.");
    return;
  }

  // Connect the socket
  final IO.Socket socket = IO.io(
    websocketUrl,
    IO.OptionBuilder()
        .setTransports(['websocket'])
        .setQuery({'role': 'Driver', 'route_id': routeId})
        .build(),
  );

  socket.connect();

  bool isBroadcasting = false;

  socket.onConnect((_) {
    print("Background Socket Connected ✅: ${socket.id}");
    prefs.setString('socketId', socket.id ?? '');
  });

  socket.on('start_now', (_) {
    print("Background 'start_now' received. Switching to location_update.");
    isBroadcasting = true;
  });

  // Start a timer to send checks every 5 seconds
  Timer.periodic(const Duration(seconds: 5), (timer) async {
    try {
      if (!socket.connected) {
        print("Background socket disconnected. Attempting to reconnect...");
        socket.connect();
        return; // Skip this tick
      }

      Position position = await Geolocator.getCurrentPosition();
      final String? socketId = prefs.getString('socketId');

      Map<String, dynamic> trackingData = {
        "route_id": routeId,
        "latitude": position.latitude,
        "longitude": position.longitude,
        "socket_id": socketId,
        "heading": position.heading,
      };

      if (isBroadcasting) {
        // Once server says start, we broadcast updates
        trackingData["status"] = "tracking_active";
        socket.emit("location_update", trackingData);
        print("Background: Emitting location_update.");
      } else {
        // Until then, we send checks
        trackingData["status"] = "checking";
        socket.emit("check_location", trackingData);
        print("Background: Emitting check_location.");
      }

    } catch (e) {
      print("Error in background location timer: $e");
    }
  });
}
