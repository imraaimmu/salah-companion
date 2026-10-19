// No-op stand-in for Google datatransport (com.google.android.datatransport), which MediaPipe
// Tasks uses only to upload usage statistics (RemoteLoggingClient, log source
// COREML_ON_DEVICE_SOLUTIONS). The real library is excluded in app/build.gradle.kts so nothing
// is queued or sent (docs/SPEC.md section 8). Only the API surface MediaPipe calls exists here;
// if a MediaPipe upgrade needs more, the release build fails in R8 (missing class), loudly,
// and DatatransportStubsTest (JVM, reflection) lists every member MediaPipe uses.
// API stand-in written for Salah Companion from MediaPipe's call sites only (names and
// signatures); no Google code was copied. Licensed with this project (see NOTICE.md).
package com.google.android.datatransport;

public interface Transport<T> {
  void send(Event<T> event);
}
