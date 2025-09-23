// main.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

// Make sure you have a 'route_service.dart' file to handle fetching routes.
import 'route_service.dart';

const String websocketUrl = "wss://bus.vjstartup.com";

Future<void> initializeService() async {
  final service = FlutterBackgroundService();
  tz.initializeTimeZones();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      isForegroundMode: true,
      autoStart: true,
      autoStartOnBoot: true,
      notificationChannelId: 'vj_bus_driver_service',
      initialNotificationTitle: 'VJ Bus Service',
      initialNotificationContent: 'Service is running in the background.',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStart,
    ),
  );
}

// MODIFIED: `onStart` function with extensive logging[1]
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  tz.initializeTimeZones();

  final prefs = await SharedPreferences.getInstance();
  
  // Centralized logging function for the background service[1]
  void log(String message) {
    // This log is visible via `adb logcat`
    print('[BackgroundService] $message');
    
    // This saves the log to be viewed in the UI
    final now = DateTime.now().toIso8601String();
    prefs.setString('last_background_log', '$now - $message');
  }

  log("Service instance started. Initializing...");

  Timer? locationTimer;
  IO.Socket? socket;
  bool hasTrackedToday = false;

  Timer.periodic(const Duration(minutes: 1), (timer) async {
    final now = tz.TZDateTime.now(tz.local);
    log("Timer ticked. Current time: $now. Checking conditions...");

    if (now.hour == 0 && now.minute == 0) {
      if (hasTrackedToday) {
        hasTrackedToday = false;
        log("Resetting hasTrackedToday flag at midnight.");
      }
    }

    if (now.hour == 21 && now.minute == 31   && !hasTrackedToday) {
      hasTrackedToday = true;
      log("Condition met: Starting tracking at 6:30 AM.");

      final String? selectedRoute = prefs.getString("selectedRoute");
      if (selectedRoute == null) {
        log("ERROR: No route selected. Cannot start tracking.");
        service.invoke("updateStatus", {'isTracking': false, 'message': 'Cannot start: No route selected'});
        return;
      }

      log("Connecting socket for route: $selectedRoute");
      socket = connectSocket(selectedRoute, "Driver");

      socket?.onConnect((_) {
        log("Socket connected successfully. Socket ID: ${socket?.id}");
        WakelockPlus.enable();
        service.invoke("updateStatus", {'isTracking': true, 'message': 'Tracking Started'});

        locationTimer = Timer.periodic(const Duration(seconds: 5), (locTimer) async {
          if (socket == null || !socket!.connected) return;
          try {
            Position position = await Geolocator.getCurrentPosition();
            log("Got position: ${position.latitude}, ${position.longitude}");
            socket!.emit("location_update", {
              "route_id": selectedRoute,
              "latitude": position.latitude,
              "longitude": position.longitude,
              "socket_id": socket?.id,
              "role": "Driver",
              "heading": position.heading,
              "status": "tracking_active",
            });
          } catch (e) {
            log("ERROR getting location: $e");
          }
        });
      });

      socket?.onDisconnect((_) {
        log("Socket disconnected.");
        locationTimer?.cancel();
        WakelockPlus.disable();
        service.invoke("updateStatus", {'isTracking': false, 'message': 'Connection Lost'});
      });
      
      socket?.onError((error) => log("Socket ERROR: $error"));
    }
  });

  service.on("stopService").listen((event) {
    log("Received stopService event. Stopping tracking.");
    locationTimer?.cancel();
    socket?.emit("tracking_status", {"route_id": event?['route_id'], "status": "stopped"});
    socket?.disconnect();
    WakelockPlus.disable();
    service.invoke("updateStatus", {'isTracking': false, 'message': 'Tracking Stopped'});
  });
}

IO.Socket connectSocket(String? routeId, String role) {
  Map<String, dynamic> queryParams = {'role': role, 'route_id': routeId ?? 'Unknown'};
  IO.Socket socket = IO.io(websocketUrl, IO.OptionBuilder().setTransports(['websocket']).setQuery(queryParams).disableAutoConnect().build());
  socket.connect();
  return socket;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeService();
  runApp(const DriverLocationApp());
}

class DriverLocationApp extends StatefulWidget {
  const DriverLocationApp({super.key});
  @override
  _DriverLocationAppState createState() => _DriverLocationAppState();
}

class _DriverLocationAppState extends State<DriverLocationApp> {
  bool isTracking = false;
  String statusMessage = "Waiting for 6:30 AM...";
  final RouteService _routeService = RouteService();
  List<String> routes = [];
  bool isLoadingRoutes = true;
  String? selectedRouteId;
  
  // NEW: State for in-app logging
  final List<String> _logs = [];
  Timer? _logSyncTimer;
  String? _lastSyncedLog;

  @override
  void initState() {
    super.initState();
    _log("App UI initialized.");
    _setupInitialData();
    _checkAndRequestPermissions();

    final service = FlutterBackgroundService();
    service.on("updateStatus").listen((event) {
      final message = event?['message'] ?? (event?['isTracking'] ? "Tracking Active" : "Tracking Stopped");
      _log("UI received status update: $message");
      if (mounted) {
        setState(() {
          isTracking = event?['isTracking'] ?? false;
          statusMessage = message;
        });
      }
    });
    
    // NEW: Sync logs from the background service every 3 seconds
    _logSyncTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      final prefs = await SharedPreferences.getInstance();
      final latestLog = prefs.getString('last_background_log');
      if (latestLog != null && latestLog != _lastSyncedLog) {
        _log('[BG] $latestLog');
        _lastSyncedLog = latestLog;
      }
    });
  }
  
  // NEW: Centralized logging function for the UI
  void _log(String message) {
    if (mounted) {
      setState(() {
        // Add new logs to the top of the list
        _logs.insert(0, message);
        // Optional: Limit the number of logs to prevent memory issues
        if (_logs.length > 200) {
          _logs.removeLast();
        }
      });
    }
  }

  Future<void> _setupInitialData() async {
    _log("Setting up initial data...");
    await _loadRoutes();
    await _loadSelectedRoute();
    if (mounted) setState(() => isLoadingRoutes = false);
    _log("Initial data setup complete.");
  }

  Future<void> _checkAndRequestPermissions() async {
    _log("Checking permissions...");
    final permissions = [
      Permission.notification,
      Permission.location,
      Permission.locationAlways,
      Permission.ignoreBatteryOptimizations,
    ];
    await permissions.request();
    _log("Permission checks complete.");
  }

  // ... (other functions like _loadRoutes, _loadSelectedRoute, _onRouteChanged remain the same)
  // ...
  Future<void> _loadRoutes() async {
    try {
      _log("Fetching routes from server...");
      final loadedRoutes = await _routeService.getRoutes();
      _log("Successfully fetched ${loadedRoutes.length} routes.");
      if (mounted) setState(() => routes = loadedRoutes);
    } catch (e) {
      _log("ERROR fetching routes: $e");
      if (mounted) setState(() => routes = []);
    }
  }

  Future<void> _loadSelectedRoute() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? storedRouteId = prefs.getString("selectedRoute");
    _log("Loaded stored route: $storedRouteId");
    bool isValidRoute = storedRouteId != null && routes.contains(storedRouteId);
    if (mounted) {
      setState(() {
        selectedRouteId = isValidRoute ? storedRouteId : (routes.isNotEmpty ? routes.first : null);
      });
      if (selectedRouteId != null) {
        _log("Setting current route to: $selectedRouteId");
        await prefs.setString("selectedRoute", selectedRouteId!);
      }
    }
  }

  Future<void> _onRouteChanged(String? newRoute) async {
    if (newRoute == null) return;
    _log("Route changed to: $newRoute");
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString("selectedRoute", newRoute);
    if (mounted) {
      setState(() => selectedRouteId = newRoute);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Route set to $newRoute.")),
      );
    }
  }
  
  // NEW: Function to show the logs screen
  void _showLogsScreen() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (context) => Scaffold(
        appBar: AppBar(title: const Text("Application Logs")),
        body: ListView.builder(
          reverse: true, // Show newest logs first
          itemCount: _logs.length,
          itemBuilder: (context, index) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
              child: Text(_logs[index]),
            );
          },
        ),
      ),
    ));
  }

  @override
  void dispose() {
    _logSyncTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(
          title: const Text("VJ Bus Driver"),
          actions: [
            // NEW: Button to open the logs screen
            IconButton(
              icon: const Icon(Icons.description),
              tooltip: 'Show Logs',
              onPressed: _showLogsScreen,
            ),
          ],
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isLoadingRoutes)
                  const CircularProgressIndicator()
                else if (routes.isEmpty)
                  const Text("No routes available. Check connection.")
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Select Route:", style: TextStyle(fontSize: 16)),
                      const SizedBox(height: 10),
                      DropdownButton<String>(
                        value: selectedRouteId,
                        isExpanded: true,
                        hint: const Text("Choose your route"),
                        items: routes.map((route) {
                          return DropdownMenuItem<String>(
                            value: route,
                            child: Text(route),
                          );
                        }).toList(),
                        onChanged: _onRouteChanged,
                      ),
                    ],
                  ),

                  // ... route selection dropdown ...
                
                const SizedBox(height: 40),
                Icon(isTracking ? Icons.location_on : Icons.location_off_outlined, color: isTracking ? Colors.green : Colors.grey, size: 100),
                const SizedBox(height: 20),
                Text(statusMessage, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isTracking ? Colors.green.shade800 : Colors.red.shade800)),
                if (selectedRouteId != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text("Current Route: $selectedRouteId", style: const TextStyle(fontSize: 16)),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
