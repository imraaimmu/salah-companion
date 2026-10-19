package com.google.android.datatransport

import android.content.Context
import com.google.android.datatransport.cct.CCTDestination
import com.google.android.datatransport.runtime.Destination
import com.google.android.datatransport.runtime.TransportRuntime
import java.lang.reflect.Method
import java.lang.reflect.Modifier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The no-op datatransport stand-ins (src/main/java/com/google/android/datatransport) must expose
 * every member MediaPipe Tasks 0.10.35's RemoteLoggingClient links against, with the exact
 * descriptors from its bytecode (`javap -c` of com.google.mediapipe.tasks.core.logging
 * .RemoteLoggingClient). A missing member would only show up at runtime on a phone as a
 * NoSuchMethodError, so it is checked here by reflection. When MediaPipe is upgraded, re-run
 * javap and update both the stand-ins and this list.
 */
class DatatransportStubsTest {
    private fun method(owner: Class<*>, name: String, vararg params: Class<*>): Method =
        owner.getMethod(name, *params).also { assertTrue("$name must be public", Modifier.isPublic(it.modifiers)) }

    private fun assertStatic(m: Method, isStatic: Boolean) =
        assertEquals("${m.name} static", isStatic, Modifier.isStatic(m.modifiers))

    @Test
    fun transportRuntimeMembers() {
        // invokestatic TransportRuntime.initialize:(Landroid/content/Context;)V
        val init = method(TransportRuntime::class.java, "initialize", Context::class.java)
        assertStatic(init, true)
        assertEquals(Void.TYPE, init.returnType)
        // invokestatic TransportRuntime.getInstance:()Lcom/google/android/datatransport/runtime/TransportRuntime;
        val get = method(TransportRuntime::class.java, "getInstance")
        assertStatic(get, true)
        assertEquals(TransportRuntime::class.java, get.returnType)
        // invokevirtual TransportRuntime.newFactory:(Lcom/google/android/datatransport/runtime/Destination;)Lcom/google/android/datatransport/TransportFactory;
        val newFactory = method(TransportRuntime::class.java, "newFactory", Destination::class.java)
        assertStatic(newFactory, false)
        assertEquals(TransportFactory::class.java, newFactory.returnType)
    }

    @Test
    fun cctDestinationInstance() {
        // getstatic CCTDestination.INSTANCE:Lcom/google/android/datatransport/cct/CCTDestination;
        val f = CCTDestination::class.java.getField("INSTANCE")
        assertTrue(Modifier.isStatic(f.modifiers) && Modifier.isPublic(f.modifiers))
        assertEquals(CCTDestination::class.java, f.type)
        assertTrue(Destination::class.java.isAssignableFrom(CCTDestination::class.java))
    }

    @Test
    fun encodingEventTransportMembers() {
        // invokestatic Encoding.of:(Ljava/lang/String;)Lcom/google/android/datatransport/Encoding;
        val of = method(Encoding::class.java, "of", String::class.java)
        assertStatic(of, true)
        assertEquals(Encoding::class.java, of.returnType)
        // invokestatic Event.ofData:(Ljava/lang/Object;)Lcom/google/android/datatransport/Event;
        val ofData = method(Event::class.java, "ofData", Any::class.java)
        assertStatic(ofData, true)
        assertEquals(Event::class.java, ofData.returnType)
        // invokeinterface TransportFactory.getTransport:(Ljava/lang/String;Ljava/lang/Class;
        //   Lcom/google/android/datatransport/Encoding;Lcom/google/android/datatransport/Transformer;)
        //   Lcom/google/android/datatransport/Transport;
        assertTrue(TransportFactory::class.java.isInterface)
        val getTransport = method(
            TransportFactory::class.java, "getTransport",
            String::class.java, Class::class.java, Encoding::class.java, Transformer::class.java,
        )
        assertEquals(Transport::class.java, getTransport.returnType)
        // invokeinterface Transport.send:(Lcom/google/android/datatransport/Event;)V
        assertTrue(Transport::class.java.isInterface)
        val send = method(Transport::class.java, "send", Event::class.java)
        assertEquals(Void.TYPE, send.returnType)
        // invokedynamic ...:()Lcom/google/android/datatransport/Transformer; -> a functional
        // interface whose single abstract method is apply(Object)Object.
        assertTrue(Transformer::class.java.isInterface)
        val abstract = Transformer::class.java.methods.filter { Modifier.isAbstract(it.modifiers) }
        assertEquals(1, abstract.size)
        assertEquals("apply", abstract[0].name)
        assertEquals(listOf(Any::class.java), abstract[0].parameterTypes.toList())
        assertEquals(Any::class.java, abstract[0].returnType)
    }

    @Test
    fun theCallSequenceRunsAndDropsEverything() {
        TransportRuntime.initialize(null)
        val runtime = TransportRuntime.getInstance()
        assertSame(runtime, TransportRuntime.getInstance())
        val factory = runtime.newFactory(CCTDestination.INSTANCE)
        val transport = factory.getTransport(
            "test", ByteArray::class.java, Encoding.of("proto"),
            Transformer<ByteArray, ByteArray> { it },
        )
        assertNotNull(transport)
        transport.send(Event.ofData(byteArrayOf(1, 2, 3))) // no-op, never throws
    }
}
