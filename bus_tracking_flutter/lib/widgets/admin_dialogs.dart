import 'package:flutter/material.dart';
import '../utils/constants.dart';

void showAdminPasswordPanel(BuildContext context, Function onAuthenticated) {
  final passwordController = TextEditingController();
  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text("Admin Access"),
      content: TextField(
        controller: passwordController,
        obscureText: true,
        decoration: const InputDecoration(labelText: "Password"),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text("Cancel")),
        TextButton(
          child: const Text("Submit"),
          onPressed: () {
            if (passwordController.text == adminPassword) {
              Navigator.pop(dialogContext);
              onAuthenticated();
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Incorrect password")),
              );
            }
          },
        ),
      ],
    ),
  );
}

void showAdminOptions(BuildContext context, {required VoidCallback onRefreshRoutes, required VoidCallback onViewLogs, required VoidCallback onReconnectSocket}) {
  showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text("Admin Options"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(leading: const Icon(Icons.refresh), title: const Text("Refresh Routes"), onTap: onRefreshRoutes),
          ListTile(leading: const Icon(Icons.description), title: const Text("View Logs"), onTap: onViewLogs),
          ListTile(leading: const Icon(Icons.sync), title: const Text("Reconnect Socket"), onTap: onReconnectSocket),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text("Close"))],
    ),
  );
}
