package app.contigua.c4

import app.contigua.proto.Frames
import app.contigua.server.AppEntry
import app.contigua.server.CannedVideo
import app.contigua.server.IntRect
import app.contigua.server.FakePlatform
import app.contigua.server.GateSettings
import app.contigua.server.Server
import app.contigua.server.Session
import java.io.File
import java.util.concurrent.CountDownLatch

/**
 * C4 interop harness: runs the real [Session] over a loopback socket backed by
 * fakes and a canned H.264 clip, so `tools/fakephone/deckctl.py` can be pointed
 * at it. Prints `PORT=<n>` once listening and stays up.
 *
 *   ./gradlew :app:c4Harness -Pc4args="--h264 /tmp/c4.h264"
 */
object C4Harness {

    @JvmStatic
    fun main(args: Array<String>) {
        var h264Path = "build/c4.h264"
        var i = 0
        while (i < args.size) {
            when (args[i]) {
                "--h264" -> h264Path = args.getOrNull(++i) ?: h264Path
            }
            i++
        }

        val clip = File(h264Path).let { file ->
            if (!file.exists()) generate(file)
            AnnexB.parse(file.readBytes())
        }
        System.err.println("harness: clip config=${clip.csd.size}B frames=${clip.frames.size}")

        val platform = FakePlatform()
        platform.apps = listOf(
            AppEntry("com.android.settings", "Settings", "com.android.settings/.Settings", multi = false),
            AppEntry("com.android.chrome", "Chrome", "com.android.chrome/.Main", multi = true),
        )
        platform.video = CannedVideo { stream, w, h, sink ->
            Thread {
                sink.onConfig(stream, Frames.CODEC_H264, w, h, clip.csd, IntRect(0, 0, w, h))
                var pts = 0L
                for (frame in clip.frames) {
                    sink.onFrame(stream, pts, frame.key, frame.data)
                    pts += 33_333L
                    Thread.sleep(30)
                }
            }.start()
        }

        val holder = arrayOfNulls<Server>(1)
        platform.onPairingRequestHandler = { request ->
            holder[0]?.respondPairing(request.requestId, true)
        }

        val server = Server(
            { socket, plain, hello ->
                Session(
                    socket = socket,
                    plainSocket = plain,
                    display = platform,
                    catalog = platform,
                    launcher = platform,
                    injector = platform,
                    power = platform,
                    device = platform,
                    store = platform,
                    callback = platform,
                    now = { System.nanoTime() / 1_000_000 },
                    log = { System.err.println("harness: $it") },
                    preReadHello = hello,
                    gateProvider = { GateSettings(true, true) },
                )
            },
            log = { System.err.println("harness: $it") },
            gateProvider = { GateSettings(true, true) },
        )
        holder[0] = server
        val port = server.start()
        println("PORT=$port")
        System.out.flush()
        CountDownLatch(1).await()
    }

    private fun generate(target: File) {
        target.parentFile?.mkdirs()
        System.err.println("harness: generating ${target.path} with ffmpeg")
        val cmd = listOf(
            "ffmpeg", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x480:rate=30",
            "-t", "3", "-c:v", "libx264", "-bf", "0", "-f", "h264", target.path,
        )
        val process = ProcessBuilder(cmd).redirectErrorStream(true).start()
        process.inputStream.use { it.readBytes() }
        val code = process.waitFor()
        check(code == 0) { "ffmpeg failed with exit $code" }
    }
}
