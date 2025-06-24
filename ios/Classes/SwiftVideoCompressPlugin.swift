import Flutter
import AVFoundation

public class SwiftVideoCompressPlugin: NSObject, FlutterPlugin {
    private let channelName = "video_compress"
    private var writer: AVAssetWriter?
    private var reader: AVAssetReader?
    private var stopCommand = false
    private let channel: FlutterMethodChannel
    private let avController = AvController()
    
    init(channel: FlutterMethodChannel) {
        self.channel = channel
    }
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "video_compress", binaryMessenger: registrar.messenger())
        let instance = SwiftVideoCompressPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? Dictionary<String, Any>
        switch call.method {
        case "getByteThumbnail":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let position = args!["position"] as! NSNumber
            getByteThumbnail(path, quality, position, result)
        case "getFileThumbnail":
            let path = args!["path"] as! String
            let quality = args!["quality"] as! NSNumber
            let position = args!["position"] as! NSNumber
            getFileThumbnail(path, quality, position, result)
        case "getMediaInfo":
            let path = args!["path"] as! String
            getMediaInfo(path, result)
        case "compressVideo":
            let path = args!["path"] as! String
            let maxDimension = args!["maxDimension"] as! Int
            let startTimeMs = args!["startTimeMs"] as? Int64
            let endTimeMs = args!["endTimeMs"] as? Int64
            let frameRate = args!["frameRate"] as? Int
            let bitRate = args!["bitRate"] as? Int
            compressVideo(path, maxDimension, startTimeMs, endTimeMs, frameRate, bitRate, result)
        case "cancelCompression":
            cancelCompression(result)
        case "deleteAllCache":
            Utility.deleteFile(Utility.basePath(), clear: true)
            result(true)
        case "setLogLevel":
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func getBitMap(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult)-> Data?  {
        let url = Utility.getPathUrl(path)
        let asset = avController.getVideoAsset(url)
        guard let track = avController.getTrack(asset) else { return nil }
        
        let assetImgGenerate = AVAssetImageGenerator(asset: asset)
        assetImgGenerate.appliesPreferredTrackTransform = true
        
        let timeScale = CMTimeScale(track.nominalFrameRate)
        let time = CMTimeMakeWithSeconds(Float64(truncating: position),preferredTimescale: timeScale)
        guard let img = try? assetImgGenerate.copyCGImage(at:time, actualTime: nil) else {
            return nil
        }
        let thumbnail = UIImage(cgImage: img)
        let compressionQuality = CGFloat(0.01 * Double(truncating: quality))
        return thumbnail.jpegData(compressionQuality: compressionQuality)
    }
    
    private func getByteThumbnail(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult) {
        if let bitmap = getBitMap(path,quality,position,result) {
            result(bitmap)
        }
    }
    
    private func getFileThumbnail(_ path: String,_ quality: NSNumber,_ position: NSNumber,_ result: FlutterResult) {
        let fileName = Utility.getFileName(path)
        let url = Utility.getPathUrl("\(Utility.basePath())/\(fileName).jpg")
        Utility.deleteFile(path)
        if let bitmap = getBitMap(path,quality,position,result) {
            guard (try? bitmap.write(to: url)) != nil else {
                return result(FlutterError(code: channelName,message: "getFileThumbnail error",details: "getFileThumbnail error"))
            }
            result(Utility.excludeFileProtocol(url.absoluteString))
        }
    }
    
    public func getMediaInfoJson(_ path: String)->[String : Any?] {
        let url = Utility.getPathUrl(path)
        let asset = avController.getVideoAsset(url)
        guard let track = avController.getTrack(asset) else { return [:] }
        
        let playerItem = AVPlayerItem(url: url)
        let metadataAsset = playerItem.asset
        
        let orientation = avController.getVideoOrientation(path)
        
        let title = avController.getMetaDataByTag(metadataAsset,key: "title")
        let author = avController.getMetaDataByTag(metadataAsset,key: "author")
        
        let duration = asset.duration.seconds * 1000
        let filesize = track.totalSampleDataLength
        
        let size = track.naturalSize.applying(track.preferredTransform)
        
        let width = abs(size.width)
        let height = abs(size.height)
        
        let dictionary = [
            "path":Utility.excludeFileProtocol(path),
            "title":title,
            "author":author,
            "width":width,
            "height":height,
            "duration":duration,
            "filesize":filesize,
            "orientation":orientation
            ] as [String : Any?]
        return dictionary
    }
    
    private func getMediaInfo(_ path: String,_ result: FlutterResult) {
        let json = getMediaInfoJson(path)
        let string = Utility.keyValueToJson(json)
        result(string)
    }
    
    private func log(_ message: String) {
        channel.invokeMethod("log", arguments: message)
    }

    public func cancelCompression(_ result: FlutterResult) {
        stopCommand = true
        writer?.cancelWriting()
        reader?.cancelReading()
        result("")
    }

    private func compressVideo(_ path: String,
                               _ maxDimensionPx: Int,
                               _ startTimeMs: Int64?,
                               _ endTimeMs: Int64?,
                               _ frameRate: Int?,
                               _ bitRate: Int?,
                               _ result: @escaping FlutterResult) {

        log("Starting video compression…")
        let sourceURL = Utility.getPathUrl(path)
        let uuid = NSUUID().uuidString
        let outURL = Utility.getPathUrl("\(Utility.basePath())/\(Utility.getFileName(path))\(uuid).mp4")

        // Load asset + track checks
        let asset = avController.getVideoAsset(sourceURL)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            log("Error: No video track.")
            return result(FlutterError(code: "compression_error",
                                       message: "Failed to read video track.",
                                       details: nil))
        }
        let audioTrack = asset.tracks(withMediaType: .audio).first

        // Time-range
        let durationMs = Int64(asset.duration.seconds * 1000)
        let startMs = startTimeMs ?? 0
        let endMs = endTimeMs ?? durationMs
        if startMs >= endMs {
            log("Error: startTime ≥ endTime")
            return result(FlutterError(code: "invalid_argument",
                                       message: "Start time must be less than end time.",
                                       details: nil))
        }
        let timeRange = CMTimeRange(start: CMTimeMake(value: startMs, timescale: 1000),
                                    end:   CMTimeMake(value: endMs,   timescale: 1000))
        log("Time range: \(timeRange.start.seconds)–\(timeRange.end.seconds)s")
        
        // Composition
        log("Building composition…")
        let composition = AVMutableComposition()
        let compVideoTrack = composition.addMutableTrack(withMediaType: .video,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid)!
        try? compVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
        if let aIn = audioTrack,
           let compAudioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compAudioTrack.insertTimeRange(timeRange, of: aIn, at: .zero)
            log("Audio track added.")
        } else {
            log("No audio track.")
        }

        // VideoComposition for scale/frameRate
        log("Configuring videoComposition…")
        let videoComposition = AVMutableVideoComposition()
        let maxDim = CGFloat(maxDimensionPx)
        let origSize = videoTrack.naturalSize
        var target = origSize
        if target.width > maxDim || target.height > maxDim {
            let ar = target.width/target.height
            if target.width > target.height {
                target.width  = maxDim
                target.height = maxDim/ar
            } else {
                target.height = maxDim
                target.width  = maxDim*ar
            }
            log("Scaled → \(target)")
        }
        func makeEven(_ v: CGFloat)->CGFloat {
            let i = Int(ceil(v))
            return CGFloat(i % 2 == 0 ? i : i-1)
        }
        let finalSize = CGSize(width: makeEven(target.width),
                               height: makeEven(target.height))
        log("Final renderSize: \(finalSize)")
        videoComposition.renderSize = finalSize

        if let fps = frameRate, videoTrack.nominalFrameRate > Float(fps) {
            videoComposition.frameDuration = CMTimeMake(value: 1, timescale: Int32(fps))
            log("Lowering FPS → \(fps)")
        } else {
            videoComposition.frameDuration = CMTimeMake(value: 1, timescale: Int32(videoTrack.nominalFrameRate))
            log("Keeping original FPS")
        }

        // Transform + center
        let sx = finalSize.width  / origSize.width
        let sy = finalSize.height / origSize.height
        var t = videoTrack.preferredTransform.concatenating(CGAffineTransform(scaleX: sx, y: sy))
        let dx = (finalSize.width - origSize.width*sx)/2
        let dy = (finalSize.height - origSize.height*sy)/2
        t = t.concatenating(CGAffineTransform(translationX: dx, y: dy))
        let instr = AVMutableVideoCompositionInstruction()
        instr.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        let layerInstr = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)
        layerInstr.setTransform(t, at: .zero)
        instr.layerInstructions = [layerInstr]
        videoComposition.instructions = [instr]

        // MARK: — Reader & Writer Setup —
        log("Setting up reader & writer…")
        do {
            reader = try AVAssetReader(asset: composition)
            // make sure we only read the trimmed range
+           reader?.timeRange = timeRange
            writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        } catch {
            log("Reader/Writer init error: \(error)")
            return result(FlutterError(code: "export_error",
                                       message: error.localizedDescription,
                                       details: nil))
        }

        // Video output from composition
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [compVideoTrack],
                                                              videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB
        ])
        videoOutput.videoComposition = videoComposition
        reader!.add(videoOutput)

        // Audio output
        var audioOutput: AVAssetReaderTrackOutput?
        if let aIn = audioTrack {
            let ao = AVAssetReaderTrackOutput(track: aIn, outputSettings: nil)
            reader!.add(ao)
            audioOutput = ao
        }

        // Writer inputs
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey:  Int(finalSize.width),
            AVVideoHeightKey: Int(finalSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate ?? 2_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = false
        writer!.add(vInput)

        if audioOutput != nil {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVEncoderBitRateKey: 128_000,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44_100
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = false
            writer!.add(aInput)
        }

        // Start
        writer!.startWriting()
        reader!.startReading()
        writer!.startSession(atSourceTime: .zero)
        log("Writing…")

        let queue = DispatchQueue(label: "videoWriterQueue")

        // Video loop
        vInput.requestMediaDataWhenReady(on: queue) {
            while vInput.isReadyForMoreMediaData && !self.stopCommand {
                if let buf = videoOutput.copyNextSampleBuffer() {
                    vInput.append(buf)
                } else {
                    vInput.markAsFinished()
                    break
                }
            }
        }

        // Audio loop
        if let ao = audioOutput,
           let aInput = writer!.inputs.first(where: { $0.mediaType == .audio }) {
            aInput.requestMediaDataWhenReady(on: queue) {
                while aInput.isReadyForMoreMediaData && !self.stopCommand {
                    if let buf = ao.copyNextSampleBuffer() {
                        aInput.append(buf)
                    } else {
                        aInput.markAsFinished()
                        break
                    }
                }
            }
        }

        // Finish
        writer!.finishWriting {
            if self.stopCommand {
                self.stopCommand = false
                self.log("Compression cancelled")
                var info = self.getMediaInfoJson(path)
                info["isCancel"] = true
                let json = Utility.keyValueToJson(info)
                return result(json)
            }
            if self.writer!.status == .completed {
                self.log("Compression succeeded")
                var info = self.getMediaInfoJson(Utility.excludeEncoding(outURL.path))
                info["isCancel"] = false
                let json = Utility.keyValueToJson(info)
                result(json)
            } else {
                self.log("Write error: \(self.writer!.error?.localizedDescription ?? "unknown")")
                result(FlutterError(code: "export_error",
                                    message: self.writer!.error?.localizedDescription,
                                    details: nil))
                
            }
        }
    }
}
