# Flutter specific rules
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# Biometric authentication
-keep class androidx.lifecycle.DefaultLifecycleObserver
