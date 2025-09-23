import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';
// ignore: unused_import
import 'package:http/http.dart' as http;

// Import the RouteService
import 'route_service.dart';
String? socketId;
const String websocketUrl = "wss://bus.vjstartup.com";

Future<void> initializeService() async {
  final service = FlutterBackgroundService();
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      isForegroundMode: true,
      autoStart: true, // Ensure the service starts automatically
    ),
    iosConfiguration: IosConfiguration(),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  String? selectedRoute = prefs.getString("selectedRoute");

  // Get the socket connection with user info
  IO.Socket socket = connectSocket(selectedRoute, "Driver");
  
  service.on("stopService").listen((event) {
    service.stopSelf();
    socket.emit("tracking_status", {"route_id": selectedRoute, "status": "stopped"});
    socket.disconnect();
  });
}

// Create a reusable function to connect socket with proper identity
IO.Socket connectSocket(String? routeId, String role) {
  Map<String, dynamic> queryParams = {
    'role': role,
    'route_id': routeId ?? 'Unknown',
  };
  
  if (routeId != null) {
    queryParams['route_id'] = routeId;
  }
  
  IO.Socket socket = IO.io(
    websocketUrl,
    IO.OptionBuilder()
        .setTransports(['websocket'])
        .setQuery(queryParams)
        .disableAutoConnect()
        .build(),
  );
  
  socket.connect();
  return socket;
}

// Function to disconnect a socket and cleanup
void disconnectSocket(IO.Socket socket) {
  if (socket.connected) {
    socket.disconnect();
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeService();
  runApp(DriverLocationApp());
}

class DriverLocationApp extends StatefulWidget {
  const DriverLocationApp({super.key});

  @override
  _DriverLocationAppState createState() => _DriverLocationAppState();
}

class _DriverLocationAppState extends State<DriverLocationApp> {
  dynamic isTracking = false;
  bool isButtonPressed = false;
  double buttonOpacity = 1.0;
  
  // Using RouteService for routes management
  final RouteService _routeService = RouteService();
  List<String> routes = [];
  bool isLoadingRoutes = true;
  
  String? selectedRouteId;
  late IO.Socket socket;
  Timer? trackingTimer;
  Timer? longPressTimer;
  int vibrationCount = 0;

  // Text controller for password field
  late TextEditingController _passwordController;
  // Password constant
  final String? _adminPassword = "123";
  
  // Error logging
  List<String> _errorLogs = [];
  final int _maxErrorLogs = 100; // Maximum number of error logs to keep

  @override
  void initState() {
    super.initState();
    _setupInitialData();
    _checkBatteryOptimization();
    _passwordController = TextEditingController();
  }
  
  Future<void> _setupInitialData() async {
    // Load routes first
    await _loadRoutes();

    // Then load selected route
    await _loadSelectedRoute();
    
    // Setup socket connection after route data is loaded
    _setupSocket();

    setState(() {
      isLoadingRoutes = false;
    });
  }
  
  Future<void> _loadRoutes() async {
    try {
      final loadedRoutes = await _routeService.getRoutes();
      setState(() {
        routes = loadedRoutes;
      });
    } catch (e) {
      print("Error loading routes: $e");
      // If error, fallback to empty list, which will be replaced by defaults
      setState(() {
        routes = [];
      });
    }
  }

  void _showAdminDisconnectAlert() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text("Disconnected"),
        content: Text("You have been disconnected by an administrator"),
        actions: [
          TextButton(
            child: Text("OK"),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  void _setupSocket() {
    // Create new socket connection with proper identity
    socket = connectSocket(selectedRouteId, "Driver");
    
    // Setup listeners for the socket
    _setupSocketListeners();
  }

  Future<void> _onRouteChanged(String? newRoute) async {
    if (isTracking == true) _toggleTracking();

    // Save the new route
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString("selectedRoute", newRoute!);

    // Disconnect existing socket
    disconnectSocket(socket);
    
    // Connect new socket with the new route
    setState(() {
      selectedRouteId = newRoute;
      _setupSocket(); // This will create a new socket with the new route ID
    });
  }
  
  void _setupSocketListeners() {
    socket.onConnect((_) {
      print("Socket Connected âœ…");
      socketId = socket.id;
      print("Main App Socket ID: $socketId");
      _logInfo("Socket connected with ID: $socketId, Route: $selectedRouteId");
      
      // Save socketId to SharedPreferences
      SharedPreferences.getInstance().then((prefs) {
        prefs.setString('socketId', socketId ?? '');
        if (selectedRouteId != null) {
          prefs.setString("selectedRoute", selectedRouteId!);
        }
      });
      
      setState(() {}); // Update UI if needed
    });

    socket.onDisconnect((_) {
      print("Socket Disconnected âŒ");
      _logInfo("Socket disconnected: $socketId");
      socketId = null; // Clear socketId on disconnect
      
      // Remove from SharedPreferences
      SharedPreferences.getInstance().then((prefs) {
        prefs.remove('socketId');
      });
      
      setState(() {}); // Update UI if needed
    });

    // Handle force_disconnect event
    socket.on('disconnect_by_admin', (data) {
      print("Received force disconnect from admin: $data");
      _logInfo("Admin disconnect received: $data");
      
      // Check if the disconnected socketId matches our current socketId
      if (data != null && data['socket_id'] == socketId) {
        if (isTracking == true) {
          sendFinalBroadcast(selectedRouteId!);
          trackingTimer?.cancel();
          FlutterBackgroundService().invoke("stopService");
          WakelockPlus.disable();
          setState(() => isTracking = false);
        }
        
        // Disconnect the socket
        disconnectSocket(socket);
        
        // Show alert to the user
        _showAdminDisconnectAlert();
        
        // Reconnect with a new socket after a delay
        Future.delayed(Duration(seconds: 2), () {
          _setupSocket();
        });
      }
    });
  }

  Future<void> _checkBatteryOptimization() async {
    var isIgnoring = await Permission.ignoreBatteryOptimizations.isGranted;
    if (!isIgnoring) {
      await Permission.ignoreBatteryOptimizations.request();
    }
  }

  Future<void> _loadSelectedRoute() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    
    // Get the stored route ID
    String? storedRouteId = prefs.getString("selectedRoute");
    
    // Validate it exists in our current routes list
    bool isValidRoute = storedRouteId != null && routes.contains(storedRouteId);
    
    setState(() {
      // Use stored route if valid, otherwise default to first route (if available)
      selectedRouteId = isValidRoute 
          ? storedRouteId 
          : (routes.isNotEmpty ? routes.first : null);
    });
    
    // If we selected a different route than stored, update the storage
    if (selectedRouteId != storedRouteId && selectedRouteId != null) {
      await prefs.setString("selectedRoute", selectedRouteId!);
    }
  }

  Future<void> _refreshRoutes() async {
    setState(() {
      isLoadingRoutes = true;
    });
    
    try {
      final refreshedRoutes = await _routeService.refreshRoutes();
      setState(() {
        routes = refreshedRoutes;
        isLoadingRoutes = false;
      });
      
      // Re-validate selected route after refresh
      await _loadSelectedRoute();
      
      // Log success
      _logInfo("Routes refreshed successfully - ${routes.length} routes loaded");

    } catch (e) {
      // Log the error
      _logError("Failed to refresh routes: $e");
      
      setState(() {
        isLoadingRoutes = false;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to refresh routes. Using cached data.")),
      );
    }
  }

  void _toggleTracking() async {
    setState(() => isButtonPressed = true);
    await Future.delayed(Duration(milliseconds: 100));
    setState(() => isButtonPressed = false);

    final service = FlutterBackgroundService();
    if (isTracking == true) {
      setState(() => isTracking = null);
      await Future.delayed(Duration(seconds: 2));
      sendFinalBroadcast(selectedRouteId!);
      await Future.delayed(Duration(seconds: 1));
      trackingTimer?.cancel();
      service.invoke("stopService");
      WakelockPlus.disable();
      setState(() => isTracking = false);
    } else {
      if (await Permission.location.request().isGranted) {
        if (selectedRouteId == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Please select a route first")),
          );
          return;
        }
        
        SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setString("selectedRoute", selectedRouteId!);
        
        // Make sure socket is connected before tracking
        if (!socket.connected) {
          _setupSocket();
          await Future.delayed(Duration(seconds: 1)); // Give it time to connect
        }
        
        service.startService();
        WakelockPlus.enable();
        setState(() => isTracking = true);
        startTracking();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Location permission denied")),
        );
      }
    }
  }

  void startTracking() async {
    const double stopRadius = 500; // 500 meters
    const double targetLatitude = 17.539883;
    const double targetLongitude = 78.386531;

    _logInfo("Started tracking for route: $selectedRouteId, socketId: $socketId");
    
    trackingTimer = Timer.periodic(Duration(seconds: 5), (timer) async {
      Position position = await Geolocator.getCurrentPosition();
      double distance = Geolocator.distanceBetween(
        position.latitude, position.longitude, targetLatitude, targetLongitude);

      Map<String, dynamic> trackingData = {
        "route_id": selectedRouteId,
        "latitude": position.latitude,
        "longitude": position.longitude,
        "socket_id": socketId,
        "role": "Driver",
        "heading": position.heading,
        "status": "tracking_active",
      };
      
      // Ensure socket is connected before sending
      if (socket.connected) {
        socket.emit("location_update", trackingData);
      } else {
        _logError("Socket disconnected during tracking. Attempting to reconnect...");
        _setupSocket(); // Try to reconnect
      }

      DateTime now = DateTime.now();
      if (now.hour >= 6 && now.hour < 12 && distance <= stopRadius) {
        sendFinalBroadcast(selectedRouteId!);
        trackingTimer?.cancel();
        FlutterBackgroundService().invoke("stopService");
        WakelockPlus.disable();
        setState(() => isTracking = false);
        print("ðŸš¦ Auto-stopping: Entered 500m radius of target location (Morning).");
      }
    });
  }

  void sendFinalBroadcast(String routeId) async {
    Position position = await Geolocator.getCurrentPosition();

    Map<String, dynamic> finalBroadcast = {
      "route_id": routeId,
      "latitude": position.latitude,
      "longitude": position.longitude,
      "socket_id": socketId,
      "role": "Driver",
      "heading": position.heading,
      "status": "stopped"
    };
    
    // Ensure socket is connected before sending
    if (socket.connected) {
      socket.emit("location_update", finalBroadcast);
    } else {
      _logError("Socket disconnected during final broadcast");
    }
    disconnectSocket(socket);
    socketId = null; // Clear socketId after sending final broadcast

  }

  // Log an error to the error log array
  void _logError(String error, [StackTrace? stackTrace]) {
    print("ERROR: $error"); // Print to console for debugging
    
    setState(() {
      // Add timestamp to error message
      final now = DateTime.now();
      final timestamp = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
      _errorLogs.add("[$timestamp] âŒ $error ${stackTrace != null ? '\n' + stackTrace.toString().split('\n').first : ''}");
      
      // Trim log if it gets too long
      if (_errorLogs.length > _maxErrorLogs) {
        _errorLogs.removeAt(0);
      }
    });
  }

  // Show error logs from long press 
  void _showErrorLogs() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("ðŸš¨ Error Logs"),
        content: SingleChildScrollView(
          child: Text("Error logs are displayed here."),
        ),
        actions: [
          TextButton(
            child: Text("OK"),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }
  
  // Update the _showErrorLogsScreen to provide more details
  void _showErrorLogsScreen() {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text("ðŸš¨ App Logs"),
        content: Container(
          width: double.maxFinite,
          height: 300,
          child: _errorLogs.isEmpty
            ? Center(child: Text("No logs available"))
            : ListView.builder(
                itemCount: _errorLogs.length,
                itemBuilder: (context, index) {
                  // Display logs in reverse order (newest first)
                  String log = _errorLogs[_errorLogs.length - 1 - index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Text(
                      log,
                      style: TextStyle(fontSize: 14),
                    ),
                  );
                },
              ),
        ),
        actions: [
          TextButton(
            child: Text("Clear Logs"),
            onPressed: () {
              setState(() => _errorLogs.clear());
              Navigator.of(dialogContext).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text("Logs cleared")),
              );
            },
          ),
          TextButton(
            child: Text("Close"),
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
        ],
      ),
    );
  }

  // Add a method to log general info (not just errors)
  void _logInfo(String message) {
    print("INFO: $message"); // Print to console for debugging
    
    setState(() {
      // Add timestamp to message
      final now = DateTime.now();
      final timestamp = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
      _errorLogs.add("[$timestamp] â„¹ï¸ $message");
      
      // Trim log if it gets too long
      if (_errorLogs.length > _maxErrorLogs) {
        _errorLogs.removeAt(0);
      }
    });
  }
  
  void _startVibrationFeedback() {
    vibrationCount = 0;
    longPressTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (vibrationCount >= 5) {
        _showErrorLogs();
        longPressTimer?.cancel();
      } else {
        setState(() {
          buttonOpacity = 1.0 - (vibrationCount * 0.2); // Gradually decrease opacity
        });
        Vibration.vibrate(duration: 100);
        vibrationCount++;
      }
    });
  }

  void _stopVibrationFeedback() {
    longPressTimer?.cancel();
    setState(() {
      buttonOpacity = 1.0; // Reset button opacity
    });
  }

  void _showAdminPanel(BuildContext parentContext) {
    // Always use the parentContext that was passed in
    _passwordController.clear();  // Reset password field
    
    // Store the parent context for later use
    final BuildContext contextToUse = parentContext;
    
    try {
      showDialog(
        context: contextToUse,  // Use the stored context
        barrierDismissible: false,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            title: Text("Admin Access"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Enter admin password to continue"),
                SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: "Password",
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                child: Text("Cancel"),
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
              TextButton(
                child: Text("Submit"),
                onPressed: () {
                  final String enteredPassword = _passwordController.text;
                  Navigator.of(dialogContext).pop();
                  
                  // Use the parent context for the next dialog
                  if (enteredPassword == _adminPassword) {
                    // Delay slightly to ensure the dialog is fully closed
                    Future.delayed(Duration(milliseconds: 100), () {
                      _showAdminOptions(contextToUse);
                    });
                  } else {
                    ScaffoldMessenger.of(contextToUse).showSnackBar(
                      SnackBar(content: Text("Incorrect password")),
                    );
                  }
                },
              ),
            ],
          );
        },
      );
    } catch (e, stackTrace) {
      _logError("Failed to show admin panel: $e", stackTrace);
      ScaffoldMessenger.of(contextToUse).showSnackBar(
        SnackBar(content: Text("Error opening admin panel")),
      );
    }
  }
  
  // In _showAdminOptions(), always use the passed context
  void _showAdminOptions(BuildContext context) {
    try {
      showDialog(
        context: context, // Use the passed context
        barrierDismissible: false,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            title: Text("Admin Options"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text("Refresh Routes"),
                  onTap: isLoadingRoutes 
                    ? null 
                    : () {
                        Navigator.of(dialogContext).pop();
                        _refreshRoutes();
                      },
                ),
                ListTile(
                  leading: Icon(Icons.error_outline),
                  title: Text("View Error Logs"),
                  onTap: () {
                    Navigator.of(dialogContext).pop();
                    _showErrorLogsScreen();
                  },
                ),
                ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text("Reconnect Socket"),
                  onTap: () {
                    Navigator.of(dialogContext).pop();
                    disconnectSocket(socket);
                    _setupSocket();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("Socket reconnected")),
                    );
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                child: Text("Close"),
                onPressed: () => Navigator.of(dialogContext).pop(),
              ),
            ],
          );
        }
      );
    } catch (e) {
      _logError("Failed to show admin options: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error showing admin options: $e")),
      );
    }
  }

  @override
  void dispose() {
    // Clean up socket connection when widget is disposed
    disconnectSocket(socket);
    _passwordController.dispose();
    trackingTimer?.cancel();
    longPressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Builder(
        builder: (BuildContext scaffoldContext) {
          return Scaffold(
            body: Stack(
              children: [
                // Main content
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (isLoadingRoutes)
                        CircularProgressIndicator()
                      else if (routes.isEmpty)
                        Text("No routes available. Check connection.") 
                      else
                        Column(
                          children: [
                            Text(
                              "Select Route:",
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                            SizedBox(height: 8),
                            DropdownButton<String>(
                              value: selectedRouteId,
                              onChanged: _onRouteChanged,
                              items: routes.map((routeId) {
                                return DropdownMenuItem(
                                  value: routeId,
                                  child: Text(routeId),
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      SizedBox(height: 20),
                      Column(
                        children: [
                          Text(
                            isTracking == true
                                ? "âœ… Bus Started" 
                                : "âŒ Bus Stopped",
                            style: TextStyle(
                              fontSize: 18, 
                              fontWeight: FontWeight.bold, 
                              color: isTracking == true ? Color(0xFF006400) : Color(0xFF8B0000)
                            ),
                          ),
                          SizedBox(height: 5),
                          if (selectedRouteId != null)
                            Text(
                              "Route: $selectedRouteId",
                              style: TextStyle(fontSize: 16),
                            ),
                          SizedBox(height: 5),
                          Text(
                            socket.connected 
                                ? "ðŸ”— Connected (ID: ${socketId?.substring(0, 6) ?? 'n/a'}...)" 
                                : "âŒ Disconnected",
                            style: TextStyle(
                              fontSize: 14,
                              color: socket.connected ? Colors.green : Colors.red,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 20),
                      GestureDetector(
                        onTapDown: (_) => setState(() => isButtonPressed = true),
                        onTapUp: (_) => setState(() => isButtonPressed = false),
                        onTapCancel: () => setState(() => isButtonPressed = false),
                        onTap: _toggleTracking,
                        onLongPressStart: (_) => _startVibrationFeedback(),
                        onLongPressEnd: (_) => _stopVibrationFeedback(),
                        child: AnimatedOpacity(
                          duration: Duration(milliseconds: 100),
                          opacity: isButtonPressed ? 0.6 : buttonOpacity,
                          child: AnimatedScale(
                            scale: isButtonPressed ? 0.9 : 1.0,
                            duration: Duration(milliseconds: 100),
                            child: Container(
                              width: 150,
                              height: 150,
                              decoration: BoxDecoration(
                                color: isTracking == true ? Colors.red : Colors.blue,
                                shape: BoxShape.circle,
                              ),
                              alignment: Alignment.center,
                              child: isTracking == null
                                  ? CircularProgressIndicator(color: Colors.white)
                                  : Text(
                                      isTracking == true ? "STOP" : "START",
                                      style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                
                // Admin button positioned at bottom right
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        padding: EdgeInsets.zero,
                        backgroundColor: const Color.fromARGB(255, 255, 255, 255),
                        shape: CircleBorder(),
                      ),
                      child: Text("."),
                      onPressed: () {
                        try {
                          // Use scaffoldContext here which comes from the Builder widget
                          _showAdminPanel(scaffoldContext);
                        } catch (e, stackTrace) {
                          _logError("Failed to open admin panel: $e", stackTrace);
                          ScaffoldMessenger.of(scaffoldContext).showSnackBar(
                            SnackBar(content: Text("Error opening admin panel")),
                          );
                        }
                      },
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}