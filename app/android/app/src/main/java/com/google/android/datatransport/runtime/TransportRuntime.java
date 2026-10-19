// No-op stand-in for Google datatransport (com.google.android.datatransport), which MediaPipe
// Tasks uses only to upload usage statistics (RemoteLoggingClient, log source
// COREML_ON_DEVICE_SOLUTIONS). The real library is excluded in app/build.gradle.kts so nothing
// is queued or sent (docs/SPEC.md section 8). Only the API surface MediaPipe calls exists here;
// if a MediaPipe upgrade needs more, the release build fails in R8 (missing class), loudly,
// and DatatransportStubsTest (JVM, reflection) lists every member MediaPipe uses.
// API stand-in written for Salah Companion from MediaPipe's call sites only (names and
// signatures); no Google code was copied. Licensed with this project (see NOTICE.md).
package com.google.android.datatransport.runtime;

import android.content.Context;
import com.google.android.datatransport.Encoding;
import com.google.android.datatransport.Transformer;
import com.google.android.datatransport.Transport;
import com.google.android.datatransport.TransportFactory;

/** Accepts events and drops them. Never stores, schedules or uploads anything. */
public final class TransportRuntime {
  private static final TransportRuntime INSTANCE = new TransportRuntime();

  private TransportRuntime() {}

  public static void initialize(Context context) {}

  public static TransportRuntime getInstance() {
    return INSTANCE;
  }

  public TransportFactory newFactory(Destination destination) {
    return new TransportFactory() {
      @Override
      public <T> Transport<T> getTransport(
          String name, Class<T> payloadType, Encoding encoding, Transformer<T, byte[]> transformer) {
        return event -> {};
      }
    };
  }
}
