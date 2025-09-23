import 'package:flutter/material.dart';

void showLogDialog(BuildContext context, List<String> logs, VoidCallback onClear) {
  showDialog(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text("📝 App Logs"),
      content: SizedBox(
        width: double.maxFinite,
        height: 300,
        child: logs.isEmpty
            ? const Center(child: Text("No logs available"))
            : ListView.builder(
                itemCount: logs.length,
                reverse: true,
                itemBuilder: (context, index) {
                  String log = logs[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4.0),
                    child: Text(log, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
                  );
                },
              ),
      ),
      actions: [
        TextButton(
          child: const Text("Clear"),
          onPressed: () {
            onClear();
            Navigator.of(dialogContext).pop();
          },
        ),
        TextButton(
          child: const Text("Close"),
          onPressed: () => Navigator.of(dialogContext).pop(),
        ),
      ],
    ),
  );
}
