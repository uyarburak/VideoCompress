import Flutter
import AVFoundation

public class SwiftVideoCompressPlugin: NSObject, FlutterPlugin {
    private let channelName = "video_compress"
    // private var exporter: AVAssetExportSession? = nil
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
        // case "cancelCompression":
        //     cancelCompression(result)
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
    
    
    // @objc private func updateProgress(timer:Timer) {
    //     let asset = timer.userInfo as! AVAssetExportSession
    //     if(!stopCommand) {
    //         channel.invokeMethod("updateProgress", arguments: "\(String(describing: asset.progress * 100))")
    //     }
    // }
    
    private func compressVideo(_ path: String,_ maxDimensionPx: Int,_ startTimeMs: Int64?,
                          _ endTimeMs: Int64?,_ frameRate: Int?,_ bitRate: Int?,
                          _ result: @escaping FlutterResult) {

        // Helper to log messages to Flutter on the main thread
        func log(_ message: String) {
            self.channel.invokeMethod("log", arguments: message)
        }
        
        log("Starting video compression...")
        let sourceVideoUrl = Utility.getPathUrl(path)
        let sourceVideoType = "mp4"
        
        log("Loading video asset...")
        let sourceVideoAsset = avController.getVideoAsset(sourceVideoUrl)
        guard let sourceVideoTrack = sourceVideoAsset.tracks(withMediaType: .video).first else {
            log("Error: Could not get source video track. The file might be audio-only or corrupt.")
            result(FlutterError(code: "compression_error", message: "Failed to read video track.", details: nil))
            return
        }

        // Get the audio track
        let sourceAudioTrack = sourceVideoAsset.tracks(withMediaType: .audio).first

        let uuid = NSUUID()
        let compressionUrl =
        Utility.getPathUrl("\(Utility.basePath())/\(Utility.getFileName(path))\(uuid.uuidString).\(sourceVideoType)")

        // MARK: - Time Range Setup
        let videoDurationInMs = Int64(sourceVideoAsset.duration.seconds * 1000)
        let finalStartTimeMs = startTimeMs ?? 0
        let finalEndTimeMs = endTimeMs ?? videoDurationInMs

        if finalStartTimeMs >= finalEndTimeMs {
            log("Error: Start time (\(finalStartTimeMs)) must be less than end time (\(finalEndTimeMs)).")
            result(FlutterError(code: "invalid_argument", message: "Start time must be less than end time.", details: nil))
            return
        }

        let timeRange = CMTimeRange(start: CMTimeMake(value: finalStartTimeMs, timescale: 1000),
                                    end: CMTimeMake(value: finalEndTimeMs, timescale: 1000))
        log("Time range: \(timeRange.start.seconds)s to \(timeRange.end.seconds)s")
        
        // MARK: - Create a new Composition with Video and Audio Tracks
        log("Creating new composition...")
        let composition = AVMutableComposition()

        guard let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            log("Error: Could not create video track in composition.")
            result(FlutterError(code: "composition_error", message: "Failed to create video track in composition.", details: nil))
            return
        }
        
        // Add video track
        do {
            try compositionVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
        } catch {
            log("Error inserting video track: \(error.localizedDescription)")
            result(FlutterError(code: "composition_error", message: "Error inserting video track: \(error.localizedDescription)", details: nil))
            return
        }

        // Add audio track if it exists
        var compositionAudioTrack: AVMutableCompositionTrack? = nil
        if let sourceAudioTrack = sourceAudioTrack {
            compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            if let compositionAudioTrack = compositionAudioTrack {
                do {
                    try compositionAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
                    log("Audio track added to composition.")
                } catch {
                    log("Warning: Could not insert audio track: \(error.localizedDescription). Proceeding without audio.")
                }
            }
        } else {
            log("No audio track found in source video.")
        }

        // MARK: - Video Composition for Scaling, Frame Rate, and Dimension Correction
        var needsCustomComposition = false
        let videoComposition = AVMutableVideoComposition()

        // Define the maximum dimension allowed for the output video
        let maxDimension: CGFloat = CGFloat(maxDimensionPx)

        let originalSize = sourceVideoTrack.naturalSize
        var targetSize = originalSize

        // Step 1 - Scale down the video if it's larger than the max dimension
        if targetSize.width > maxDimension || targetSize.height > maxDimension {
            log("Original size \(originalSize) exceeds max dimension of \(maxDimension)px. Scaling down...")
            let aspectRatio = targetSize.width / targetSize.height
            
            if targetSize.width > targetSize.height {
                // Landscape or square video
                targetSize.width = maxDimension
                targetSize.height = maxDimension / aspectRatio
            } else {
                // Portrait video
                targetSize.height = maxDimension
                targetSize.width = maxDimension * aspectRatio
            }
            log("Scaled target size (preserving aspect ratio): \(targetSize)")
        }

        // Step 2 - Ensure the final dimensions (scaled or original) are even
        func makeEven(_ value: CGFloat) -> CGFloat {
            let intValue = Int(ceil(value))
            return CGFloat(intValue % 2 == 0 ? intValue : intValue - 1)
        }

        let finalSize = CGSize(width: makeEven(targetSize.width), height: makeEven(targetSize.height))

        if finalSize != originalSize {
            needsCustomComposition = true
        }

        log("Final render size after ensuring even dimensions: \(finalSize)")
        videoComposition.renderSize = finalSize

        // Set frame rate if needed
        if let targetFrameRate = frameRate, sourceVideoTrack.nominalFrameRate > Float(targetFrameRate) {
            needsCustomComposition = true
            videoComposition.frameDuration = CMTimeMake(value: 1, timescale: Int32(targetFrameRate))
            log("Reducing frame rate to \(targetFrameRate)")
        } else {
            videoComposition.frameDuration = CMTimeMake(value: 1, timescale: Int32(sourceVideoTrack.nominalFrameRate))
            log("Keeping original frame rate of \(sourceVideoTrack.nominalFrameRate)")
        }

        // Calculate the scaled size while preserving aspect ratio
        let assetSize = sourceVideoTrack.naturalSize
        let preferredTransform = sourceVideoTrack.preferredTransform

        // Calculate the transformed size after rotation
        let transformRect = CGRect(origin: .zero, size: assetSize).applying(preferredTransform)
        let transformedSize = CGSize(width: abs(transformRect.size.width), 
                                    height: abs(transformRect.size.height))

        // Calculate aspect ratios
        let renderAspect = finalSize.width / finalSize.height
        let assetAspect = transformedSize.width / transformedSize.height

        var scaleFactor: CGFloat = 1.0
        if assetAspect > renderAspect {
            // Asset is wider than render size
            scaleFactor = finalSize.width / transformedSize.width
        } else {
            // Asset is taller than render size
            scaleFactor = finalSize.height / transformedSize.height
        }

        // Apply scale transform
        let scaleTransform = CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)

        // Apply the original transform (rotation, etc.) FIRST
        let scaledTransform = preferredTransform.concatenating(scaleTransform)

        // Calculate translation to center the video
        let scaledWidth = transformedSize.width * scaleFactor
        let scaledHeight = transformedSize.height * scaleFactor
        let xOffset = (finalSize.width - scaledWidth) / 2
        let yOffset = (finalSize.height - scaledHeight) / 2

        // Apply translation AFTER rotation/scaling
        let finalTransform = scaledTransform.concatenating(CGAffineTransform(translationX: xOffset, y: yOffset))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)
        layerInstruction.setTransform(finalTransform, at: .zero)

        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]
        
        // MARK: - Export with AVAssetWriter for bitrate control (asynchronous)
        let actualBitRate = bitRate ?? 2_000_000
        log("Using video bitRate: \(actualBitRate) bps")
        
        // Setup AVAssetWriter
        guard let assetWriter = try? AVAssetWriter(outputURL: compressionUrl, fileType: .mp4) else {
            log("Error: Could not create AVAssetWriter.")
            result(FlutterError(code: "export_error", message: "Failed to create AVAssetWriter.", details: nil))
            return
        }
        
        // Add this after setting the transform
        // layerInstruction.setCropRectangle(finalSize, at: .zero)

        // Add pixel aspect ratio settings to ensure square pixels
        let pixelAspectRatio = [AVVideoPixelAspectRatioKey: [
            AVVideoPixelAspectRatioHorizontalSpacingKey: 1,
            AVVideoPixelAspectRatioVerticalSpacingKey: 1
        ]]

        // Update video settings to include pixel aspect ratio
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: NSNumber(value: Int(finalSize.width)),
            AVVideoHeightKey: NSNumber(value: Int(finalSize.height)),
            AVVideoPixelAspectRatioKey: pixelAspectRatio,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: NSNumber(value: actualBitRate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: NSNumber(value: true)
            ]
        ]
        
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput.expectsMediaDataInRealTime = false
        videoWriterInput.transform = finalTransform
        
        if assetWriter.canAdd(videoWriterInput) {
            assetWriter.add(videoWriterInput)
        } else {
            log("Error: Cannot add video input to asset writer.")
            result(FlutterError(code: "export_error", message: "Cannot add video input to asset writer.", details: nil))
            return
        }
        
        // Audio output settings (passthrough)
        var audioWriterInput: AVAssetWriterInput? = nil
        if compositionAudioTrack != nil {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000
            ]
            
            audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioWriterInput?.expectsMediaDataInRealTime = false
            
            if let audioInput = audioWriterInput, assetWriter.canAdd(audioInput) {
                assetWriter.add(audioInput)
            } else {
                log("Warning: Could not add audio input to asset writer. Proceeding without audio.")
                audioWriterInput = nil
            }
        }
        
        // Create AVAssetReader
        let assetReader: AVAssetReader
        do {
            assetReader = try AVAssetReader(asset: composition)
        } catch {
            log("Error: Could not create asset reader: \(error.localizedDescription)")
            result(FlutterError(code: "export_error", message: "Failed to create asset reader.", details: nil))
            return
        }
        
        // Video output from reader
        let videoReaderSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB
        ]
        
        let videoReaderOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: videoReaderSettings
        )
        videoReaderOutput.videoComposition = videoComposition
        videoReaderOutput.alwaysCopiesSampleData = false
        
        if assetReader.canAdd(videoReaderOutput) {
            assetReader.add(videoReaderOutput)
        } else {
            log("Error: Cannot add video output to asset reader.")
            result(FlutterError(code: "export_error", message: "Cannot add video output to asset reader.", details: nil))
            return
        }
        
        // Audio output from reader
        var audioReaderOutput: AVAssetReaderTrackOutput? = nil
        if compositionAudioTrack != nil {
            let audioReaderSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2
            ]
            
            audioReaderOutput = AVAssetReaderTrackOutput(
                track: compositionAudioTrack!,
                outputSettings: audioReaderSettings
            )
            audioReaderOutput?.alwaysCopiesSampleData = false
            
            if let audioOutput = audioReaderOutput, assetReader.canAdd(audioOutput) {
                assetReader.add(audioOutput)
            } else {
                log("Warning: Could not add audio output to asset reader. Proceeding without audio.")
                audioWriterInput = nil
            }
        }
        
        // Start reading and writing asynchronously
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                assetWriter.startWriting()
                assetReader.startReading()
                assetWriter.startSession(atSourceTime: CMTime.zero)
                
                // Create a dispatch group to wait for both video and audio
                let group = DispatchGroup()
                
                // Process video asynchronously
                group.enter()
                videoWriterInput.requestMediaDataWhenReady(on: DispatchQueue(label: "videoQueue")) {
                    while videoWriterInput.isReadyForMoreMediaData {
                        if let sampleBuffer = videoReaderOutput.copyNextSampleBuffer() {
                            videoWriterInput.append(sampleBuffer)
                        } else {
                            videoWriterInput.markAsFinished()
                            group.leave()
                            break
                        }
                    }
                }
                
                // Process audio asynchronously if needed
                if let audioWriterInput = audioWriterInput, let audioReaderOutput = audioReaderOutput {
                    group.enter()
                    audioWriterInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audioQueue")) {
                        while audioWriterInput.isReadyForMoreMediaData {
                            if let sampleBuffer = audioReaderOutput.copyNextSampleBuffer() {
                                audioWriterInput.append(sampleBuffer)
                            } else {
                                audioWriterInput.markAsFinished()
                                group.leave()
                                break
                            }
                        }
                    }
                }
                
                // Wait for both to finish
                group.wait()
                
                assetReader.cancelReading()
                assetWriter.finishWriting {
                    DispatchQueue.main.async {
                        switch assetWriter.status {
                        case .completed:
                            log("Compression completed successfully")
                            var json = self.getMediaInfoJson(Utility.excludeEncoding(compressionUrl.path))
                            json["isCancel"] = false
                            let jsonString = Utility.keyValueToJson(json)
                            result(jsonString)
                        case .failed:
                            log("Error: Asset writer failed with error: \(assetWriter.error?.localizedDescription ?? "unknown error")")
                            result(FlutterError(code: "export_error", message: assetWriter.error?.localizedDescription, details: nil))
                        case .cancelled:
                            log("Compression cancelled")
                            var json = self.getMediaInfoJson(path)
                            json["isCancel"] = true
                            let jsonString = Utility.keyValueToJson(json)
                            result(jsonString)
                        default:
                            result(FlutterError(code: "export_error", message: "Unknown export status", details: nil))
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    log("Error during compression: \(error.localizedDescription)")
                    result(FlutterError(code: "export_error", message: error.localizedDescription, details: nil))
                }
            }
        }
    }
    
    // private func cancelCompression(_ result: FlutterResult) {
    //     stopCommand = true
    //     exporter?.cancelExport()
    //     result("")
    // }
    
}
