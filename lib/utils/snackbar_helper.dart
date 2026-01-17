// ============================================================================
// SNACKBAR HELPER
// ============================================================================
//
// Utility for showing consistent, auto-dismissing snackbars.
// ============================================================================

import 'package:flutter/material.dart';

/// Show a snackbar that auto-dismisses after 2 seconds.
void showAppSnackBar(BuildContext context, String message, {bool isError = false}) {
  ScaffoldMessenger.of(context).clearSnackBars();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 2),
      backgroundColor: isError ? Colors.red : null,
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  );
}
