# Picked up by the Flutter Gradle plugin for release builds (R8).

# MediaPipe Tasks ships no consumer rules. Its native code calls back into Java classes by
# name (JNI) and protobuf-lite reads generated message fields reflectively.
-keep class com.google.mediapipe.** { *; }
-keep class com.google.protobuf.** { *; }
-dontwarn com.google.mediapipe.**
-dontwarn com.google.protobuf.**

# Flogger (used by MediaPipe) finds its backend by reflection.
-keep class com.google.common.flogger.** { *; }
-dontwarn com.google.common.flogger.**

# Guava / AutoValue annotations referenced by MediaPipe but not needed at runtime.
-dontwarn javax.annotation.**
-dontwarn com.google.auto.value.**
-dontwarn com.google.errorprone.annotations.**
-dontwarn org.checkerframework.**
-dontwarn com.google.j2objc.annotations.**
