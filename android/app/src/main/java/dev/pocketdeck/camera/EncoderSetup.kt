package dev.pocketdeck.camera

/**
 * The calls one surface-input encoder needs, in the only order MediaCodec
 * accepts: create, configure, createInputSurface, start. The input surface
 * exists only while the codec is configured; `start` before it fails with a
 * `CodecException` on the platform encoders (observed on the emulator's Codec2
 * AVC encoder), which is why the order lives here and is pinned by
 * CameraEncoderOrderTest instead of being repeated at the call site.
 */
interface SurfaceCodec {
    fun create(): Any

    fun configure(codec: Any)

    /** The encoder's input surface: legal between [configure] and [start]. */
    fun createInputSurface(codec: Any): Any

    fun start(codec: Any)

    /** Stops if needed and releases; called exactly once when a step fails. */
    fun release(codec: Any)
}

/** A configured, started encoder and the surface a camera can render into. */
class StartedCodec(val codec: Any, val surface: Any)

/** A failed step, named so the log says where the encoder refused. */
class CodecSetupException(val step: String, val refused: Throwable) :
    Exception("$step: ${refused.javaClass.simpleName}", refused)

/**
 * Wraps the four calls so every failure releases the codec it built: the
 * platform leaks the native codec otherwise, and the next capture on the same
 * process can then fail to create one.
 */
object EncoderSetup {

    const val CREATE = "create"
    const val CONFIGURE = "configure"
    const val INPUT_SURFACE = "input_surface"
    const val START = "start"

    fun start(codec: SurfaceCodec): StartedCodec {
        var step = CREATE
        var handle: Any? = null
        try {
            handle = codec.create()
            step = CONFIGURE
            codec.configure(handle)
            step = INPUT_SURFACE
            val surface = codec.createInputSurface(handle)
            step = START
            codec.start(handle)
            return StartedCodec(handle, surface)
        } catch (t: Throwable) {
            handle?.let { runCatching { codec.release(it) } }
            throw CodecSetupException(step, t)
        }
    }
}
