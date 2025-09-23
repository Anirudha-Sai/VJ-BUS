// lib/screens/home_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:vibration/vibration.dart';
import '../services/route_service.dart';
import '../utils/constants.dart';
import '../utils/permissions_helper.dart';
import '../widgets/admin_dialogs.dart';
import '../widgets/log_dialog.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // State Variables
  dynamic isTracking = false;
  String statusMessage = "Stopped";
  bool isButtonPressed = false;
  String? selectedRouteId;
  List<String> routes = [];
  bool isLoadingRoutes = true;
  
  // Services and Controllers
  final RouteService _routeService = RouteService();
  IO.Socket? _uiSocket;
  String? _uiSocketId;
  
  // Logging
  final List<String> _logs = [];
  final int _maxLogs = 100;

  // Timers for Gestures
  Timer? _longPressTimer;
  int _vibrationCount = 0;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  void _initialize() async {
    await PermissionsHelper.checkAndRequestPermissions();
    _log("App Initialized");
    _listenToBackgroundService();
    await _loadRoutes();
    await _loadSelectedRoute();
    if (selectedRouteId != null) {
      _setupUiSocket();
    }
    if (mounted) setState(() => isLoadingRoutes = false);
  }

  void _listenToBackgroundService() {
    FlutterBackgroundService().on('updateUI').listen((event) {
      if (mounted && event != null) {
        setState(() {
          // --- FIX: Removed unnecessary '?' ---
          isTracking = event['isTracking'] ?? false;
          statusMessage = event['status'] ?? "Unknown";
        });
        // --- FIX: Removed unnecessary '?' ---
        _log("BG Service Update: ${event['status']}");
      }
    });
  }


  void _setupUiSocket() {
    _uiSocket?.disconnect();
    _uiSocket = IO.io(
      websocketUrl,
      IO.OptionBuilder()
          .setTransports(['websocket'])
          .setQuery({'role': 'Driver', 'route_id': selectedRouteId ?? 'Unknown'})
          .disableAutoConnect()
          .build(),
    );

    _uiSocket!.onConnect((_) {
      _uiSocketId = _uiSocket!.id;
      _log("UI Socket Connected: $_uiSocketId");
      if(mounted) setState(() {});
    });

    _uiSocket!.onDisconnect((_) {
      _log("UI Socket Disconnected");
      if(mounted) setState(() {});
    });

    _uiSocket!.on('disconnect_by_admin', (data) {
      _log("Admin disconnect command received.");
      if (data != null && data['socket_id'] == _uiSocketId) {
        if (isTracking == true) {
          _stopTrackingService();
        }
        _showAdminDisconnectAlert();
      }
    });

    _uiSocket!.connect();
  }

  Future<void> _loadRoutes() async {
    try {
      final loadedRoutes = await _routeService.getRoutes();
      if (mounted) setState(() => routes = loadedRoutes);
      _log("Routes loaded: ${routes.length}");
    } catch (e) {
      _log("Error loading routes: $e");
    }
  }

  Future<void> _handleRefreshRoutes() async {
    _log("Admin: Forcing route refresh...");
    if (mounted) setState(() => isLoadingRoutes = true);
    try {
      final refreshedRoutes = await _routeService.refreshRoutes();
      if (mounted) {
        setState(() {
          routes = refreshedRoutes;
          if (!routes.contains(selectedRouteId)) {
            selectedRouteId = routes.isNotEmpty ? routes.first : null;
          }
        });
        _log("Routes refreshed successfully.");
      }
    } catch (e) {
      _log("Error refreshing routes: $e");
    } finally {
      if (mounted) setState(() => isLoadingRoutes = false);
    }
  }

  Future<void> _loadSelectedRoute() async {
    final prefs = await SharedPreferences.getInstance();
    final storedRouteId = prefs.getString("selectedRoute");
    if (storedRouteId != null && routes.contains(storedRouteId)) {
      selectedRouteId = storedRouteId;
    } else if (routes.isNotEmpty) {
      selectedRouteId = routes.first;
      await prefs.setString("selectedRoute", selectedRouteId!);
    }
    _log("Selected route set to: $selectedRouteId");
    if (mounted) setState(() {});
  }

  Future<void> _onRouteChanged(String? newRoute) async {
    if (newRoute == null || newRoute == selectedRouteId) return;
    // CORRECTED USAGE: We can now await this function.
    if (isTracking == true) await _stopTrackingService();
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("selectedRoute", newRoute);
    setState(() => selectedRouteId = newRoute);
    _log("Route changed to: $newRoute");
    _setupUiSocket();
  }

  // --- FIX: Changed return type from void to Future<void> ---
  Future<void> _stopTrackingService() async {
    final service = FlutterBackgroundService();
    service.invoke("stopService");
    // Adding a small delay can help ensure the state change propagates
    // before other actions are taken.
    await Future.delayed(const Duration(milliseconds: 500));
  }

  Future<void> _toggleTracking() async {
    if (isTracking == true) {
      setState(() => isTracking = null); // Intermediate state
      await _stopTrackingService();
      return;
    }

    if (selectedRouteId == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please select a route first.")));
      return;
    }

    final hasPermission = await Permission.location.isGranted;
    if (!hasPermission) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Location permission is required.")));
      await PermissionsHelper.checkAndRequestPermissions();
      return;
    }

    final hasBackgroundPermission = await Permission.locationAlways.isGranted;
    if (!hasBackgroundPermission) {
      if (mounted) PermissionsHelper.showBackgroundPermissionDialog(context);
      return;
    }
    
    final service = FlutterBackgroundService();
    service.invoke("startTracking", {'route_id': selectedRouteId});
  }

  void _log(String message) {
    if (!mounted) return;
    final now = DateTime.now();
    final timestamp = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}";
    setState(() {
      _logs.add("[$timestamp] $message");
      if (_logs.length > _maxLogs) _logs.removeAt(0);
    });
  }

  void _showAdminDisconnectAlert() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Disconnected"),
        content: const Text("You have been disconnected by an administrator."),
        actions: [TextButton(child: const Text("OK"), onPressed: () => Navigator.pop(context))],
      ),
    );
  }
  
  void _handleAdminTap() {
    showAdminPasswordPanel(context, () {
      showAdminOptions(
        context,
        onRefreshRoutes: () {
          Navigator.pop(context);
          _handleRefreshRoutes();
        },
        onViewLogs: () {
          Navigator.pop(context);
          showLogDialog(context, List.from(_logs.reversed), () => setState(() => _logs.clear()));
        },
        onReconnectSocket: () {
          Navigator.pop(context);
          _setupUiSocket();
        },
      );
    });
  }

  void _startLongPressVibration() {
    _vibrationCount = 0;
    _longPressTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_vibrationCount >= 5) {
        timer.cancel();
        showLogDialog(context, List.from(_logs.reversed), () => setState(() => _logs.clear()));
      } else {
        Vibration.vibrate(duration: 100);
        _vibrationCount++;
      }
    });
  }

  void _stopLongPressVibration() => _longPressTimer?.cancel();
  
  @override
  void dispose() {
    _uiSocket?.dispose();
    _longPressTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isConnected = _uiSocket?.connected ?? false;
    final Color statusColor = isTracking == true ? Colors.green.shade800 : Colors.red.shade800;

    return Scaffold(
      appBar: AppBar(title: const Text("VJ Bus Driver"), actions: [
        IconButton(icon: const Icon(Icons.admin_panel_settings), onPressed: _handleAdminTap, tooltip: "Admin Panel")
      ]),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isLoadingRoutes) const CircularProgressIndicator()
              else if (routes.isEmpty) const Text("No routes available.")
              else DropdownButton<String>(
                  value: selectedRouteId,
                  isExpanded: true,
                  items: routes.map((r) => DropdownMenuItem(value: r, child: Text(r, style: const TextStyle(fontSize: 18)))).toList(),
                  onChanged: _onRouteChanged,
              ),
              const SizedBox(height: 40),
              Text(isTracking == true ? "Bus Started" : "Bus Stopped", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: statusColor)),
              if (selectedRouteId != null) Text("Route: $selectedRouteId", style: const TextStyle(fontSize: 16)),
              Text(isConnected ? "Connected" : "Disconnected", style: TextStyle(fontSize: 14, color: isConnected ? Colors.green : Colors.red)),
              const SizedBox(height: 30),
              GestureDetector(
                onTap: _toggleTracking,
                onTapDown: (_) => setState(() => isButtonPressed = true),
                onTapUp: (_) => setState(() => isButtonPressed = false),
                onTapCancel: () => setState(() => isButtonPressed = false),
                onLongPressStart: (_) => _startLongPressVibration(),
                onLongPressEnd: (_) => _stopLongPressVibration(),
                child: AnimatedScale(
                  scale: isButtonPressed ? 0.95 : 1.0,
                  duration: const Duration(milliseconds: 150),
                  child: Container(
                    width: 150,
                    height: 150,
                    decoration: BoxDecoration(color: isTracking == true ? Colors.red.shade700 : Colors.blue.shade700, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.3), spreadRadius: 2, blurRadius: 10)]),
                    alignment: Alignment.center,
                    child: isTracking == null
                        ? const CircularProgressIndicator(color: Colors.white)
                        : Text(isTracking == true ? "STOP" : "START", style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
