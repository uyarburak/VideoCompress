import Flutter
import AVFoundation

public class SwiftVideoCompressPlugin: NSObject, FlutterPlugin {
    private let channelName = "video_compress"
    private var exporter: AVAssetExportSession? = nil
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
            let quality = args!["quality"] as! NSNumber
            let startTimeMs = args!["startTimeMs"] as? Int64
            let endTimeMs = args!["endTimeMs"] as? Int64
            let frameRate = args!["frameRate"] as? Int
            compressVideo(path, quality, startTimeMs, endTimeMs, frameRate, result)
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
    
    
    @objc private func updateProgress(timer:Timer) {
        let asset = timer.userInfo as! AVAssetExportSession
        if(!stopCommand) {
            channel.invokeMethod("updateProgress", arguments: "\(String(describing: asset.progress * 100))")
        }
    }
    
    private func getExportPreset(_ quality: NSNumber)->String {
        switch(quality) {
        case 1:
            return AVAssetExportPresetLowQuality    
        case 2:
            return AVAssetExportPresetMediumQuality
        case 3:
            return AVAssetExportPresetHighestQuality
        case 4:
            return AVAssetExportPreset640x480
        case 5:
            return AVAssetExportPreset960x540
        case 6:
            return AVAssetExportPreset1280x720
        case 7:
            return AVAssetExportPreset1920x1080
        default:
            return AVAssetExportPresetMediumQuality
        }
    }
    
    private func compressVideo(_ path: String,_ quality: NSNumber,_ startTimeMs: Int64?,
                               _ endTimeMs: Int64?,_ frameRate: Int?,
                               _ result: @escaping FlutterResult) {

        // Helper to dispatch results to Flutter on the main thread
        func sendResult(_ value: Any) {
            DispatchQueue.main.async {
                result(value)
            }
        }

        // Helper to log messages to Flutter on the main thread
        func log(_ message: String) {
            DispatchQueue.main.async {
                self.channel.invokeMethod("log", arguments: message)
            }
        }
        
        log("Starting video compression...")
        let sourceVideoUrl = Utility.getPathUrl(path)
        let sourceVideoType = "mp4"
        
        log("Loading video asset...")
        let sourceVideoAsset = avController.getVideoAsset(sourceVideoUrl)
        guard let sourceVideoTrack = avController.getTrack(sourceVideoAsset) else {
            log("Error: Could not get source video track. The file might be audio-only or corrupt.")
            sendResult(FlutterError(code: "compression_error", message: "Failed to read video track.", details: nil))
            return
        }

        let uuid = NSUUID()
        let compressionUrl =
        Utility.getPathUrl("\(Utility.basePath())/\(Utility.getFileName(path))\(uuid.uuidString).\(sourceVideoType)")

        // MARK: - Time Range Setup
        let videoDurationInMs = Int64(sourceVideoAsset.duration.seconds * 1000)
        let finalStartTimeMs = startTimeMs ?? 0
        let finalEndTimeMs = endTimeMs ?? videoDurationInMs

        if finalStartTimeMs >= finalEndTimeMs {
            log("Error: Start time (\(finalStartTimeMs)) must be less than end time (\(finalEndTimeMs)).")
            sendResult(FlutterError(code: "invalid_argument", message: "Start time must be less than end time.", details: nil))
            return
        }

        let timeRange = CMTimeRange(start: CMTimeMake(value: finalStartTimeMs, timescale: 1000),
                                    end: CMTimeMake(value: finalEndTimeMs, timescale: 1000))
        log("Time range: \(timeRange.start.seconds)s to \(timeRange.end.seconds)s")
        
        log("Creating composition...")
        let session = sourceVideoTrack.asset!
        
        let exportPreset = getExportPreset(quality)
        log("Setting up export session with quality: \(exportPreset)")

        guard let exporter = AVAssetExportSession(asset: session, presetName: exportPreset) else {
            log("Error: Could not create AVAssetExportSession.")
            sendResult(FlutterError(code: "export_error", message: "Failed to create AVAssetExportSession.", details: nil))
            return
        }
        
        exporter.outputURL = compressionUrl
        exporter.outputFileType = AVFileType.mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.timeRange = timeRange

        // MARK: - Video Composition for Scaling, Frame Rate, and Dimension Correction
        var needsVideoComposition = false
        let videoComposition = AVMutableVideoComposition()

        // NEW: Define the maximum dimension allowed for the output video
        let maxDimension: CGFloat = 1280.0

        let originalSize = sourceVideoTrack.naturalSize
        var targetSize = originalSize

        // NEW: Step 1 - Scale down the video if it's larger than the max dimension
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

        // NEW: Step 2 - Ensure the final dimensions (scaled or original) are even
        // Function to make a dimension even by rounding up
        func makeEven(_ value: CGFloat) -> CGFloat {
            let intValue = Int(ceil(value))
            return CGFloat(intValue % 2 == 0 ? intValue : intValue - 1)
        }

        let finalSize = CGSize(width: makeEven(targetSize.width), height: makeEven(targetSize.height))

        if finalSize != originalSize {
            needsVideoComposition = true
            videoComposition.renderSize = finalSize
            log("Final render size after ensuring even dimensions: \(finalSize)")
        } else {
            videoComposition.renderSize = originalSize
            log("Original dimensions are valid and do not need changes: \(originalSize)")
        }

        if let targetFrameRate = frameRate {
            let sourceFrameRate = sourceVideoTrack.nominalFrameRate
            if sourceFrameRate > Float(targetFrameRate) {
                needsVideoComposition = true
                videoComposition.frameDuration = CMTimeMake(value: 1, timescale: Int32(targetFrameRate))
                log("Reducing frame rate from \(sourceFrameRate) to \(targetFrameRate)")
            } else {
                log("Keeping original frame rate of \(sourceFrameRate)")
            }
        }

        if needsVideoComposition {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: sourceVideoAsset.duration)
            
            let transformer = AVMutableVideoCompositionLayerInstruction(assetTrack: sourceVideoTrack)
            transformer.setTransform(sourceVideoTrack.preferredTransform, at: .zero)
            
            instruction.layerInstructions = [transformer]
            videoComposition.instructions = [instruction]
            
            exporter.videoComposition = videoComposition
            log("Applied custom video composition.")
        }
        
        log("Starting export...")
        let timer = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(self.updateProgress),
                                         userInfo: exporter, repeats: true)
        
        exporter.exportAsynchronously(completionHandler: {
            timer.invalidate()
            if(self.stopCommand) {
                self.stopCommand = false
                log("Compression cancelled")
                var json = self.getMediaInfoJson(path)
                json["isCancel"] = true
                let jsonString = Utility.keyValueToJson(json)
                return sendResult(jsonString)
            }
            log("Compression completed successfully")
            var json = self.getMediaInfoJson(Utility.excludeEncoding(compressionUrl.path))
            json["isCancel"] = false
            let jsonString = Utility.keyValueToJson(json)
            sendResult(jsonString)
        })
        self.exporter = exporter
    }
    
    private func cancelCompression(_ result: FlutterResult) {
        stopCommand = true
        exporter?.cancelExport()
        result("")
    }
    
}
