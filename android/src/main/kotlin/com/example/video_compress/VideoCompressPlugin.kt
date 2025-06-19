package com.example.video_compress

import android.content.Context
import android.net.Uri
import android.util.Log
import com.otaliastudios.transcoder.Transcoder
import com.otaliastudios.transcoder.TranscoderListener
import com.otaliastudios.transcoder.resize.ExactResizer
import com.otaliastudios.transcoder.source.TrimDataSource
import com.otaliastudios.transcoder.source.UriDataSource
import com.otaliastudios.transcoder.strategy.DefaultAudioStrategy
import com.otaliastudios.transcoder.strategy.DefaultVideoStrategy
import com.otaliastudios.transcoder.strategy.RemoveTrackStrategy
import com.otaliastudios.transcoder.strategy.TrackStrategy
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import com.otaliastudios.transcoder.internal.utils.Logger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import java.io.File
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.Future

// Android media & URI
import android.media.MediaMetadataRetriever

// Kotlin math extension for roundToInt()
import kotlin.math.roundToInt

// Date formatting
import java.util.Date
import java.util.Locale

/**
 * VideoCompressPlugin
 */
class VideoCompressPlugin : MethodCallHandler, FlutterPlugin {


    private var _context: Context? = null
    private var _channel: MethodChannel? = null
    private val TAG = "VideoCompressPlugin"
    private val LOG = Logger(TAG)
    private var transcodeFuture:Future<Void>? = null
    var channelName = "video_compress"

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = _context;
        val channel = _channel;

        if (context == null || channel == null) {
            Log.w(TAG, "Calling VideoCompress plugin before initialization")
            return
        }

        when (call.method) {
            "getByteThumbnail" -> {
                val path = call.argument<String>("path")
                val quality = call.argument<Int>("quality")!!
                val position = call.argument<Int>("position")!! // to long
                ThumbnailUtility(channelName).getByteThumbnail(path!!, quality, position.toLong(), result)
            }
            "getFileThumbnail" -> {
                val path = call.argument<String>("path")
                val quality = call.argument<Int>("quality")!!
                val position = call.argument<Int>("position")!! // to long
                ThumbnailUtility("video_compress").getFileThumbnail(context, path!!, quality,
                        position.toLong(), result)
            }
            "getMediaInfo" -> {
                val path = call.argument<String>("path")
                result.success(Utility(channelName).getMediaInfoJson(context, path!!).toString())
            }
            "deleteAllCache" -> {
                result.success(Utility(channelName).deleteAllCache(context, result));
            }
            "setLogLevel" -> {
                val logLevel = call.argument<Int>("logLevel")!!
                Logger.setLogLevel(logLevel)
                result.success(true);
            }
            "cancelCompression" -> {
                transcodeFuture?.cancel(true)
                result.success(false);
            }
            "compressVideo" -> {
                val path = call.argument<String>("path")!!
                val maxDimension = call.argument<Int>("maxDimension")!!
                val startTimeMs = call.argument<Int>("startTimeMs")
                val endTimeMs = call.argument<Int>("endTimeMs")
                val frameRate = call.argument<Int>("frameRate") ?: 30

                channel.invokeMethod("log", "Starting Android video compression for $path…")

                // 1) Extract original dimensions
                val retriever = MediaMetadataRetriever().apply {
                    setDataSource(context, Uri.parse(path))
                }
                val origW = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
                    ?.toInt() ?: 0
                val origH = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
                    ?.toInt() ?: 0
                retriever.release()
                channel.invokeMethod("log", "Original size: ${origW}x${origH}")

                fun even(v: Int) = if (v % 2 == 0) v else v - 1
                
                // 1) Prepare the video strategy builder:
                val builder = DefaultVideoStrategy.Builder()
                    .frameRate(frameRate)

                // 2) Pick resizer (clamp+even OR just even OR none):
                if (origW > maxDimension || origH > maxDimension) {
                    // Clamp the larger side, preserve aspect ratio:
                    val ratio = if (origW >= origH) {
                        maxDimension.toFloat() / origW
                    } else {
                        maxDimension.toFloat() / origH
                    }
                    val rawW = origW * ratio
                    val rawH = origH * ratio

                    // Round to nearest even ↓
                    val targetW = even(rawW.roundToInt())
                    val targetH = even(rawH.roundToInt())

                    channel.invokeMethod("log", "Clamping & evening to $targetW×$targetH")
                    builder.addResizer(ExactResizer(targetW, targetH))
                } else if (origW % 2 != 0 || origH % 2 != 0) {
                    // Only even out odd dimensions:
                    val evenW = even(origW)
                    val evenH = even(origH)

                    channel.invokeMethod("log", "Evening out odd dimensions to $evenW×$evenH")
                    builder.addResizer(ExactResizer(evenW, evenH))

                } else {
                    channel.invokeMethod("log", "No resize needed (within bounds & even).")
                }
                    
                
                // 3) Build audio strategy
                val audioTrackStrategy = DefaultAudioStrategy.Builder()
                    .channels(DefaultAudioStrategy.CHANNELS_AS_INPUT)
                    .sampleRate(DefaultAudioStrategy.SAMPLE_RATE_AS_INPUT)
                    .build()
                channel.invokeMethod("log", "Audio strategy: input sample rate & channels")

                // 4) Decide on trimming DataSource
                val dataSource = if (startTimeMs != null || endTimeMs != null) {
                    channel.invokeMethod("log", "Applying trim: start=$startTimeMs, end=$endTimeMs")
                    val src = UriDataSource(context, Uri.parse(path))
                    if (endTimeMs == null) {
                        TrimDataSource(src, (startTimeMs ?: 0) * 1_000L)
                    } else {
                        MyClipDataSource(src, (startTimeMs ?: 0) * 1_000L, endTimeMs.toLong() * 1_000L)
                    }
                    }
                } else {
                    channel.invokeMethod("log", "No trim requested, using full source")
                    UriDataSource(context, Uri.parse(path))
                }

                // 5) Build video strategy with explicit resize
                channel.invokeMethod(
                    "log",
                    "Building video strategy: @${frameRate}fps"
                )
                val videoTrackStrategy = builder.build()

                // 6) Prepare destination path
                val tempDir = context.getExternalFilesDir("video_compress")!!.absolutePath
                val timeStamp =
                    SimpleDateFormat("yyyy-MM-dd HH-mm-ss", Locale.getDefault()).format(Date())
                val destPath = "$tempDir/VID_${timeStamp}_${path.hashCode()}.mp4"
                channel.invokeMethod("log", "Output will be saved to $destPath")

                // 7) Kick off Transcoder
                channel.invokeMethod("log", "Starting Transcoder.into()")
                transcodeFuture = Transcoder.into(destPath)
                    .addDataSource(dataSource)
                    .setAudioTrackStrategy(audioTrackStrategy)
                    .setVideoTrackStrategy(videoTrackStrategy)
                    .setListener(object : TranscoderListener {
                        override fun onTranscodeProgress(progress: Double) {
                            val pct = (progress * 100).toInt()
                            channel.invokeMethod("log", "Progress: $pct%")
                            channel.invokeMethod("updateProgress", progress * 100)
                        }
                        override fun onTranscodeCompleted(successCode: Int) {
                            channel.invokeMethod("log", "Transcode completed (code $successCode)")
                            channel.invokeMethod("updateProgress", 100.0)
                            val json = Utility(channelName).getMediaInfoJson(context, destPath)
                            json.put("isCancel", false)
                            result.success(json.toString())
                        }
                        override fun onTranscodeCanceled() {
                            channel.invokeMethod("log", "Transcode canceled by user")
                            result.success(null)
                        }
                        override fun onTranscodeFailed(exception: Throwable) {
                            channel.invokeMethod("log", "Transcode failed: ${exception.message}")
                            result.success(null)
                        }
                    })
                    .transcode()
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        init(binding.applicationContext, binding.binaryMessenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        _channel?.setMethodCallHandler(null)
        _context = null
        _channel = null
    }

    private fun init(context: Context, messenger: BinaryMessenger) {
        val channel = MethodChannel(messenger, channelName)
        channel.setMethodCallHandler(this)
        _context = context
        _channel = channel
    }

    companion object {
        private const val TAG = "video_compress"
    }

}
