package com.synapseauto.synapse_auto

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * OBD-II phase 0 (owner decision, 2026-11-11: our own native bridge, no plugin):
 * a minimal Bluetooth Classic (SPP/RFCOMM) link to an ELM327 adapter — the Vgate
 * iCar Pro BT 3.0 is not BLE. One socket at a time; every call runs on [executor]
 * (one thread, so commands never interleave on the wire) and answers on the main
 * thread, where MethodChannel.Result must be answered.
 *
 * Only already-paired devices are offered (pairing happens in Android's own
 * Bluetooth settings), so no scan and no location permission are needed — only
 * BLUETOOTH_CONNECT on Android 12+, requested by the Dart side.
 *
 * `send` writes a command plus CR and reads until the ELM327 prompt `>` (or the
 * timeout), returning the raw text: phase 0 records exactly what the adapter
 * said; interpreting it is Dart's job.
 */
class ObdBridge(private val context: Context, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var socket: BluetoothSocket? = null
    private var input: InputStream? = null
    private var output: OutputStream? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "bondedDevices" -> run(result) { bondedDevices() }
                "connect" -> {
                    val address = call.argument<String>("address")
                    if (address == null) result.error("bad_args", "address required", null)
                    else run(result) { connect(address) }
                }
                "send" -> {
                    val command = call.argument<String>("command")
                    val timeoutMs = (call.argument<Number>("timeoutMs") ?: 2000).toLong()
                    if (command == null) result.error("bad_args", "command required", null)
                    else run(result) { send(command, timeoutMs) }
                }
                "disconnect" -> run(result) { disconnect(); null }
                else -> result.notImplemented()
            }
        }
    }

    private class ObdError(val code: String, message: String) : Exception(message)

    private fun run(result: MethodChannel.Result, work: () -> Any?) {
        try {
            executor.execute {
                try {
                    val value = work()
                    mainHandler.post { result.success(value) }
                } catch (error: ObdError) {
                    mainHandler.post { result.error(error.code, error.message, null) }
                } catch (error: SecurityException) {
                    mainHandler.post { result.error("permission", "BLUETOOTH_CONNECT not granted: ${error.message}", null) }
                } catch (error: Exception) {
                    mainHandler.post { result.error("io", "${error.javaClass.simpleName}: ${error.message}", null) }
                }
            }
        } catch (error: RejectedExecutionException) {
            result.error("closed", "OBD bridge is shut down", null)
        }
    }

    private fun adapter(): BluetoothAdapter {
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager?
        val adapter = manager?.adapter ?: throw ObdError("unavailable", "this phone has no Bluetooth")
        if (!adapter.isEnabled) throw ObdError("disabled", "Bluetooth is off")
        return adapter
    }

    @SuppressLint("MissingPermission")
    private fun bondedDevices(): List<Map<String, String>> =
        adapter().bondedDevices.map { mapOf("name" to (it.name ?: ""), "address" to it.address) }

    /**
     * Opens the RFCOMM link. ELM327 clones differ in which of the three usual ways
     * they accept, so each is tried in turn and the one that worked is reported —
     * phase 0 records it for the real service to start with.
     */
    @SuppressLint("MissingPermission")
    private fun connect(address: String): Map<String, Any> {
        disconnect()
        val adapter = adapter()
        adapter.cancelDiscovery()
        val device: BluetoothDevice = adapter.getRemoteDevice(address)
        val started = SystemClock.elapsedRealtime()
        val attempts = listOf<Pair<String, () -> BluetoothSocket>>(
            "secure" to { device.createRfcommSocketToServiceRecord(SPP_UUID) },
            "insecure" to { device.createInsecureRfcommSocketToServiceRecord(SPP_UUID) },
            "channel1" to {
                device.javaClass.getMethod("createRfcommSocket", Int::class.javaPrimitiveType).invoke(device, 1) as BluetoothSocket
            },
        )
        val failures = mutableListOf<String>()
        for ((method, open) in attempts) {
            var candidate: BluetoothSocket? = null
            try {
                candidate = open()
                candidate.connect()
                socket = candidate
                input = candidate.inputStream
                output = candidate.outputStream
                return mapOf("method" to method, "millis" to (SystemClock.elapsedRealtime() - started))
            } catch (error: Exception) {
                failures += "$method: ${error.javaClass.simpleName}: ${error.message}"
                try { candidate?.close() } catch (_: IOException) {}
            }
        }
        throw ObdError("connect_failed", failures.joinToString(" | "))
    }

    /**
     * A broken link (adapter unplugged, out of range, the car cut its power) shows
     * up as an IOException or end of stream. The socket is closed right there, so
     * the next call answers `not_connected` instead of failing on a dead socket
     * again — without this, a loop of sends spins through instant errors.
     */
    private fun send(command: String, timeoutMs: Long): Map<String, Any> {
        try {
            return exchange(command, timeoutMs)
        } catch (error: IOException) {
            disconnect()
            throw ObdError("closed", "link lost: ${error.javaClass.simpleName}: ${error.message}")
        } catch (error: ObdError) {
            if (error.code == "closed") disconnect()
            throw error
        }
    }

    private fun exchange(command: String, timeoutMs: Long): Map<String, Any> {
        val input = input ?: throw ObdError("not_connected", "not connected")
        val output = output ?: throw ObdError("not_connected", "not connected")
        // Whatever arrived late from a previous command does not belong to this one.
        while (input.available() > 0) input.read(ByteArray(input.available()))
        val started = SystemClock.elapsedRealtime()
        output.write((command + "\r").toByteArray(Charsets.US_ASCII))
        output.flush()
        val response = StringBuilder()
        val buffer = ByteArray(256)
        var prompt = false
        while (SystemClock.elapsedRealtime() - started < timeoutMs) {
            val available = input.available()
            if (available <= 0) {
                Thread.sleep(2)
                continue
            }
            val read = input.read(buffer, 0, minOf(available, buffer.size))
            if (read < 0) throw ObdError("closed", "the adapter closed the link")
            for (i in 0 until read) {
                val c = buffer[i].toInt().toChar()
                if (c == '>') prompt = true else response.append(c)
            }
            if (prompt) break
        }
        return mapOf(
            "response" to response.toString(),
            "millis" to (SystemClock.elapsedRealtime() - started),
            "timedOut" to !prompt,
        )
    }

    private fun disconnect() {
        try { socket?.close() } catch (_: IOException) {}
        socket = null
        input = null
        output = null
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        try {
            executor.execute { disconnect() }
        } catch (_: RejectedExecutionException) {}
        executor.shutdown()
    }

    companion object {
        const val CHANNEL = "com.synapseauto.synapse_auto/obd"
        /** The Serial Port Profile — what ELM327 Bluetooth Classic adapters speak. */
        val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    }
}
