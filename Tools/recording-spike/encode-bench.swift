// Encoder half of the M4 recording spike: how the hardware encoders behave at screen-recording sizes.
//
// Feeds synthetic screen-like frames (lines of glyph-sized blocks, a few colored runs, scrolling or being
// typed into) through AVAssetWriter, the way the recorder will, and reports per configuration: whether it
// encodes at all, frames per second when pushed as fast as it accepts, CPU per frame in this process and in
// VideoToolbox's encoder service, and the bitrate. Nothing reads the screen.
//
//   swiftc -O -parse-as-library -o /tmp/encode-bench Tools/recording-spike/encode-bench.swift
//   /tmp/encode-bench probe                  # which encoder each codec and size gets
//   /tmp/encode-bench keys                   # which compression properties AVAssetWriter takes
//   /tmp/encode-bench matrix [frames]        # throughput, CPU, and bitrate across sizes and codecs
//   /tmp/encode-bench realtime [seconds]     # paced at 60 fps: CPU per second of recording

import AVFoundation
import CoreMedia
import CoreText
import CoreVideo
import Darwin
import Foundation
import ImageIO
import VideoToolbox

// MARK: - Frames

/// Screen-like 420v frames: dark glyph blocks in lines on a light page, a few colored runs.
enum Scene: String {
    /// The whole page moves up 8 px a frame: the worst case for an encoder.
    case scroll
    /// One line grows a glyph at a time: what typing or a cursor looks like.
    case typing
    /// Real anti-aliased text (prose and highlighted code, drawn with Core Text at 2×) scrolling 8 px a
    /// frame: what a bitrate has to hold for text to stay sharp.
    case text
}

struct LCG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 33
    }
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}

/// A page taller than a frame, as luma and interleaved chroma at half resolution.
struct Page {
    let width: Int
    let height: Int
    var luma: [UInt8]
    var chroma: [UInt8]

    init(width: Int, height: Int, seed: UInt64 = 7) {
        self.width = width
        self.height = height
        luma = [UInt8](repeating: 235, count: width * height)
        chroma = [UInt8](repeating: 128, count: (width / 2) * (height / 2) * 2)
        var random = LCG(state: seed)
        let lineHeight = 22
        var y = 12
        while y + lineHeight < height {
            var x = 16 + random.int(0...6) * 16
            let end = min(width - 16, x + random.int(200...max(201, width * 3 / 4)))
            while x < end {
                let word = random.int(2...9)
                let colored = random.int(0...5) == 0
                let (cb, cr): (UInt8, UInt8) = colored ? (UInt8(random.int(60...200)), UInt8(random.int(60...200))) : (128, 128)
                for _ in 0..<word where x + 8 < end {
                    let glyphHeight = random.int(9...13)
                    fill(x: x, y: y + 14 - glyphHeight, width: 7, height: glyphHeight, luma: UInt8(random.int(30...90)), cb: cb, cr: cr)
                    x += 9
                }
                x += 9
            }
            y += lineHeight
        }
    }

    mutating func fill(x: Int, y: Int, width w: Int, height h: Int, luma value: UInt8, cb: UInt8, cr: UInt8) {
        for row in max(0, y)..<min(height, y + h) {
            let base = row * width
            for column in max(0, x)..<min(width, x + w) { luma[base + column] = value }
        }
        guard cb != 128 || cr != 128 else { return }
        let chromaWidth = width / 2
        for row in max(0, y / 2)..<min(height / 2, (y + h) / 2) {
            for column in max(0, x / 2)..<min(chromaWidth, (x + w) / 2) {
                chroma[(row * chromaWidth + column) * 2] = cb
                chroma[(row * chromaWidth + column) * 2 + 1] = cr
            }
        }
    }

    /// Copies the window starting at `top` into a 420v buffer of the frame's size.
    func copy(into buffer: CVPixelBuffer, top: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let frameWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let frameHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        luma.withUnsafeBufferPointer { source in
            for row in 0..<frameHeight {
                memcpy(lumaBase + row * lumaStride, source.baseAddress! + (top + row) * width, min(frameWidth, width))
            }
        }
        let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let chromaRows = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let chromaBytes = CVPixelBufferGetWidthOfPlane(buffer, 1) * 2
        chroma.withUnsafeBufferPointer { source in
            for row in 0..<chromaRows {
                memcpy(chromaBase + row * chromaStride, source.baseAddress! + (top / 2 + row) * width, min(chromaBytes, width))
            }
        }
    }
}

/// Frames of real text: a page drawn with Core Text into BGRA, each frame's window converted to 420v by
/// VideoToolbox, as ScreenCaptureKit's own conversion would leave it.
func makeTextFrames(width: Int, height: Int, count: Int) -> [CVPixelBuffer] {
    let scroll = 8
    let pageHeight = height + scroll * count + 32
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: width, height: pageHeight, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: pageHeight))
    let prose = CTFontCreateUIFontForLanguage(.system, 26, nil)!
    let code = CTFontCreateWithName("Menlo" as CFString, 24, nil)
    let words = "the screen recorder writes each frame to a movie file while the encoder keeps up with the stream and nothing is dropped when the page scrolls quickly through long paragraphs of text".split(separator: " ")
    let tokens = ["let", "frame", "=", "try", "await", "stream.next()", "guard", "writer.isReady", "else", "{", "return", "}", "// keep the last frame"]
    let inks = [CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1), CGColor(red: 0.67, green: 0.05, blue: 0.57, alpha: 1), CGColor(red: 0.11, green: 0.27, blue: 0.82, alpha: 1), CGColor(red: 0.2, green: 0.5, blue: 0.2, alpha: 1)]
    var random = LCG(state: 5)
    var y = CGFloat(pageHeight - 48)
    var line = 0
    while y > 16 {
        let isCode = (line / 6) % 2 == 1
        let text = NSMutableAttributedString()
        var x = isCode ? 48 + CGFloat(random.int(0...3) * 4) * 14 : 48
        let limit = CGFloat(width) - 48 - x
        var lineWidth: CGFloat = 0
        while lineWidth < limit * CGFloat(random.int(55...95)) / 100 {
            let word = isCode ? tokens[random.int(0...tokens.count - 1)] : String(words[random.int(0...words.count - 1)])
            let piece = NSAttributedString(string: word + " ", attributes: [
                .init(kCTFontAttributeName as String): isCode ? code : prose,
                .init(kCTForegroundColorAttributeName as String): isCode ? inks[random.int(0...inks.count - 1)] : inks[0],
            ])
            text.append(piece)
            lineWidth = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil)
        }
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        x = 0
        y -= isCode ? 34 : 38
        line += 1
    }
    let page = context.makeImage()!

    var transfer: VTPixelTransferSession?
    VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
    var frames: [CVPixelBuffer] = []
    for index in 0..<count {
        var bgra: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &bgra)
        CVPixelBufferLockBaseAddress(bgra!, [])
        let frameContext = CGContext(
            data: CVPixelBufferGetBaseAddress(bgra!), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(bgra!), space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        // The window starts `index * scroll` pixels down the page; the page is y up.
        frameContext.draw(page, in: CGRect(x: 0, y: CGFloat(height + index * scroll - pageHeight), width: CGFloat(width), height: CGFloat(pageHeight)))
        CVPixelBufferUnlockBaseAddress(bgra!, [])
        CVBufferSetAttachment(bgra!, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(bgra!, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        var yuv: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &yuv)
        CVBufferSetAttachment(yuv!, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        let status = VTPixelTransferSessionTransferImage(transfer!, from: bgra!, to: yuv!)
        precondition(status == noErr, "transfer failed \(status)")
        CVBufferSetAttachment(yuv!, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(yuv!, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        frames.append(yuv!)
    }
    return frames
}

/// A short loop of frames for a scene, made before timing starts.
func makeFrames(width: Int, height: Int, scene: Scene, count: Int = 8) -> [CVPixelBuffer] {
    if scene == .text { return makeTextFrames(width: width, height: height, count: count) }
    let scroll = 8
    var page = Page(width: width + (width % 2), height: height + scroll * count + 32)
    var frames: [CVPixelBuffer] = []
    let attributes: [CFString: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
    ]
    var random = LCG(state: 99)
    for index in 0..<count {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes as CFDictionary, &buffer)
        guard let buffer else { fatalError("no pixel buffer \(width)x\(height)") }
        switch scene {
        case .scroll:
            page.copy(into: buffer, top: index * scroll)
        case .typing:
            // A new glyph at the end of a line near the middle, each frame.
            page.fill(x: width / 3 + index * 9, y: height / 2, width: 7, height: random.int(9...13), luma: 40, cb: 128, cr: 128)
            page.copy(into: buffer, top: 0)
        case .text:
            break
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        frames.append(buffer)
    }
    return frames
}

// MARK: - CPU time

/// CPU seconds used so far by this process.
func ownCPU() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
}

/// CPU seconds used so far by every process with `name` in its path (VideoToolbox's encoder service).
func cpu(ofProcessesNamed name: String) -> Double {
    let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 16)
    let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    var total = 0.0
    for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.size) where pid > 0 {
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path).contains(name) else { continue }
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { continue }
        let ticks = Double(usage.ri_user_time + usage.ri_system_time)
        total += ticks * Double(info.numer) / Double(info.denom) / 1e9
    }
    return total
}

// MARK: - Probe

func probe() {
    let sizes = [(1920, 1080), (1001, 701), (3840, 2160), (4096, 2304), (4098, 2000), (4112, 2658), (6880, 2880), (8192, 4320)]
    for (name, codec) in [("H.264", kCMVideoCodecType_H264), ("HEVC", kCMVideoCodecType_HEVC)] {
        for (width, height) in sizes {
            var hardware = "-"
            for required in [true, false] {
                var session: VTCompressionSession?
                let spec: [CFString: Any] = required
                    ? [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
                    : [:]
                let status = VTCompressionSessionCreate(
                    allocator: nil, width: Int32(width), height: Int32(height), codecType: codec,
                    encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
                    outputCallback: nil, refcon: nil, compressionSessionOut: &session
                )
                if required {
                    hardware = status == noErr ? "hardware" : "no hardware (\(status))"
                } else if let session {
                    var usingHardware: CFTypeRef?
                    VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: &usingHardware)
                    var encoder: CFTypeRef?
                    VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_EncoderID, allocator: nil, valueOut: &encoder)
                    print("\(name) \(width)x\(height): \(hardware); default session: hardware=\((usingHardware as? Bool).map(String.init) ?? "?") encoder=\(encoder as? String ?? "?")")
                    VTCompressionSessionInvalidate(session)
                } else {
                    print("\(name) \(width)x\(height): \(hardware); default session failed (\(status))")
                }
                if let session, required { VTCompressionSessionInvalidate(session) }
            }
        }
    }
}

// MARK: - Writer settings

struct Setup: CustomStringConvertible {
    var codec: AVVideoCodecType
    var width: Int
    var height: Int
    var fps: Int = 60
    var quality: Float? = 0.6
    var bitrate: Int?
    var realTime = true
    var powerEfficient = false
    var requireHardware = true

    var description: String {
        let codecName = codec == .hevc ? "HEVC" : "H.264"
        let rate = quality.map { "q\($0)" } ?? bitrate.map { "\($0 / 1_000_000) Mb/s" } ?? "default"
        return "\(codecName) \(width)x\(height) \(rate)\(realTime ? " rt" : "")\(powerEfficient ? " eff" : "")\(requireHardware ? "" : " any-encoder")"
    }

    var outputSettings: [String: Any] {
        var properties: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if let quality { properties[AVVideoQualityKey] = quality }
        if let bitrate { properties[AVVideoAverageBitRateKey] = bitrate }
        if realTime { properties[kVTCompressionPropertyKey_RealTime as String] = true }
        if powerEfficient { properties[kVTCompressionPropertyKey_MaximizePowerEfficiency as String] = true }
        if codec == .h264 {
            properties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        } else {
            properties[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: properties,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if requireHardware {
            settings[AVVideoEncoderSpecificationKey] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true]
        }
        return settings
    }
}

/// Which compression properties AVAssetWriter accepts in its settings for each codec.
func keys() {
    let candidates: [(String, Any)] = [
        (AVVideoQualityKey, 0.6),
        (AVVideoAverageBitRateKey, 20_000_000),
        (AVVideoExpectedSourceFrameRateKey, 60),
        (AVVideoMaxKeyFrameIntervalDurationKey, 2),
        (AVVideoAllowFrameReorderingKey, false),
        (kVTCompressionPropertyKey_RealTime as String, true),
        (kVTCompressionPropertyKey_MaximizePowerEfficiency as String, true),
        (kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String, true),
        (kVTCompressionPropertyKey_ConstantBitRate as String, 20_000_000),
    ]
    for codec in [AVVideoCodecType.h264, .hevc] {
        for (key, value) in candidates {
            let settings: [String: Any] = [
                AVVideoCodecKey: codec, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080,
                AVVideoCompressionPropertiesKey: [key: value],
            ]
            let writer = try! AVAssetWriter(outputURL: FileManager.default.temporaryDirectory.appending(path: "keys-\(UUID()).mov"), fileType: .mov)
            print("\(codec == .hevc ? "HEVC" : "H.264") \(key): \(writer.canApply(outputSettings: settings, forMediaType: .video) ? "accepted" : "refused")")
        }
    }
}

// MARK: - Runs

struct Result {
    var setup: Setup
    var scene: Scene
    var frames: Int
    var wall: Double
    var ownCPU: Double
    var serviceCPU: Double
    var bytes: Int
    var error: String?

    var line: String {
        if let error { return "\(setup) \(scene.rawValue): FAILED \(error)" }
        let fps = Double(frames) / wall
        let seconds = Double(frames) / Double(setup.fps)
        let megabits = Double(bytes) * 8 / seconds / 1e6
        return String(
            format: "%@ %@: %.0f fps, CPU %.2f ms/frame here + %.2f ms/frame in the service, %.1f Mb/s at %d fps",
            setup.description, scene.rawValue, fps, ownCPU * 1000 / Double(frames), serviceCPU * 1000 / Double(frames), megabits, setup.fps
        )
    }
}

/// Appends `count` frames, as fast as the input takes them or paced at the frame rate, and finishes the file.
/// With `still`, the frame at one second is decoded and written there as a PNG.
func run(_ setup: Setup, scene: Scene, count: Int, paced: Bool, directory: URL, still: URL? = nil) async -> Result {
    let frames = makeFrames(width: setup.width, height: setup.height, scene: scene)
    let url = directory.appending(path: "bench-\(UUID().uuidString).mov")
    var result = Result(setup: setup, scene: scene, frames: count, wall: 0, ownCPU: 0, serviceCPU: 0, bytes: 0)
    do {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        guard writer.canApply(outputSettings: setup.outputSettings, forMediaType: .video) else {
            result.error = "settings refused"
            return result
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: setup.outputSettings)
        input.expectsMediaDataInRealTime = paced
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else {
            result.error = writer.error.map { "\($0)" } ?? "startWriting failed"
            return result
        }
        writer.startSession(atSourceTime: .zero)
        let startCPU = ownCPU()
        let startService = cpu(ofProcessesNamed: "VTEncoderXPCService")
        let start = Date()
        var dropped = 0
        for index in 0..<count {
            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(setup.fps))
            if paced {
                let due = start.addingTimeInterval(Double(index) / Double(setup.fps))
                let wait = due.timeIntervalSinceNow
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                // Real time: a frame the encoder is not ready for is dropped, as a stream's would be.
                if !input.isReadyForMoreMediaData { dropped += 1; continue }
            } else {
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed { break }
                    try await Task.sleep(for: .microseconds(200))
                }
            }
            if writer.status == .failed { break }
            if !adaptor.append(frames[index % frames.count], withPresentationTime: time) { break }
        }
        input.markAsFinished()
        await writer.finishWriting()
        result.wall = Date().timeIntervalSince(start)
        result.ownCPU = ownCPU() - startCPU
        result.serviceCPU = cpu(ofProcessesNamed: "VTEncoderXPCService") - startService
        if writer.status != .completed {
            result.error = writer.error.map { "\(($0 as NSError).domain) \(($0 as NSError).code): \($0.localizedDescription)" } ?? "status \(writer.status.rawValue)"
        }
        if dropped > 0 { result.error = (result.error.map { $0 + "; " } ?? "") + "\(dropped) frames dropped" }
        result.bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if let still, writer.status == .completed {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let frame = try await generator.image(at: CMTime(value: 1, timescale: 1)).image
            // A 1:1 corner holding both prose and code, small enough to look at closely.
            let image = frame.cropping(to: CGRect(x: 0, y: 0, width: 720, height: 420)) ?? frame
            if let destination = CGImageDestinationCreateWithURL(still as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
    } catch {
        result.error = "\(error)"
    }
    try? FileManager.default.removeItem(at: url)
    return result
}

@main
struct EncodeBench {
    static func main() async {
        let arguments = CommandLine.arguments.dropFirst()
        let directory = URL(filePath: ProcessInfo.processInfo.environment["BENCH_DIR"] ?? NSTemporaryDirectory(), directoryHint: .isDirectory)
        switch arguments.first {
        case "probe":
            probe()
        case "keys":
            keys()
        case "matrix":
            let frames = arguments.dropFirst().first.flatMap(Int.init) ?? 240
            var setups: [Setup] = []
            for (width, height) in [(1920, 1080), (3456, 2234), (4096, 2304), (4112, 2658), (6880, 2880)] {
                setups.append(Setup(codec: .h264, width: width, height: height))
                setups.append(Setup(codec: .hevc, width: width, height: height))
            }
            setups.append(Setup(codec: .h264, width: 4112, height: 2658, requireHardware: false))
            setups.append(Setup(codec: .h264, width: 6880, height: 2880, requireHardware: false))
            setups.append(Setup(codec: .h264, width: 1001, height: 701))
            setups.append(Setup(codec: .hevc, width: 1001, height: 701))
            for setup in setups {
                for scene in [Scene.scroll, .typing] {
                    print(await run(setup, scene: scene, count: frames, paced: false, directory: directory).line)
                }
            }
        case "realtime":
            let seconds = arguments.dropFirst().first.flatMap(Int.init) ?? 5
            let setups = [
                Setup(codec: .h264, width: 1920, height: 1080),
                Setup(codec: .h264, width: 3456, height: 2234),
                Setup(codec: .hevc, width: 4112, height: 2658),
                Setup(codec: .hevc, width: 6880, height: 2880),
                Setup(codec: .hevc, width: 6880, height: 2880, powerEfficient: true),
                Setup(codec: .hevc, width: 6880, height: 2880, fps: 30),
            ]
            for setup in setups {
                for scene in [Scene.scroll, .typing] {
                    let result = await run(setup, scene: scene, count: seconds * setup.fps, paced: true, directory: directory)
                    let busy = (result.ownCPU + result.serviceCPU) / max(result.wall, 0.001) * 100
                    print(result.line + String(format: " — %.1f%% of a core while recording", busy))
                }
            }
        case "quality":
            // Bitrate by quality setting on real text, at 1920x1080 H.264 and 6880x2880 HEVC; keeps a still of
            // each at one second (quality-<codec>-<q>.png) to judge the text by eye.
            for (codec, width, height) in [(AVVideoCodecType.h264, 1920, 1080), (.hevc, 3456, 2234), (.hevc, 6880, 2880)] {
                for quality: Float in [0.4, 0.5, 0.6, 0.7, 0.8, 0.9] {
                    let still = directory.appending(path: "quality-\(codec == .hevc ? "hevc" : "h264")-\(width)-\(quality).png")
                    print(await run(Setup(codec: codec, width: width, height: height, quality: quality), scene: .text, count: 120, paced: false, directory: directory, still: still).line)
                }
            }
        case "limits":
            // Which shapes H.264 still encodes in hardware: width, height, and area.
            for (width, height) in [(4096, 2304), (4096, 2560), (4096, 4096), (2304, 4096), (2234, 3456), (2160, 3840), (3840, 2400), (4000, 3000), (4096, 2160)] {
                print(await run(Setup(codec: .h264, width: width, height: height), scene: .typing, count: 10, paced: false, directory: directory).line)
            }
        case "textrealtime":
            let seconds = arguments.dropFirst().first.flatMap(Int.init) ?? 5
            for setup in [Setup(codec: .h264, width: 1920, height: 1080), Setup(codec: .h264, width: 3456, height: 2234), Setup(codec: .hevc, width: 6880, height: 2880)] {
                let result = await run(setup, scene: .text, count: seconds * setup.fps, paced: true, directory: directory)
                let busy = (result.ownCPU + result.serviceCPU) / max(result.wall, 0.001) * 100
                print(result.line + String(format: " — %.1f%% of a core while recording", busy))
            }
        default:
            print("usage: encode-bench probe | keys | matrix [frames] | realtime [seconds] | quality")
        }
    }
}
