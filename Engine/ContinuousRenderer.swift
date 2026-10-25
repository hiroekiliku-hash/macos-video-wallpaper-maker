import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import IOSurface

struct Movie: Codable {
    let id: String
    let file: String
    let duration: Double
    var needsComposition: Bool?
}

// WallpaperAgent owns the surface; the last IOSurface stays displayed while the
// player pauses or replaces its item. A missing decoded frame never clears it.
final class ContinuousRenderer {
    let root = CALayer()
    let display = AVSampleBufferDisplayLayer()
    let player = AVPlayer()
    private var output: AVPlayerItemVideoOutput?
    private let configuration: WallpaperConfiguration
    private var movieIndex = -1
    private var movieGeneration = 0
    private var isLoadingMovie = false
    private let resources: URL
    private var movies: [Movie]
    private var movie: Movie?
    private var timer: Timer?
    private var endObserver: NSObjectProtocol?
    private var rampGeneration = 0
    private var firstFrame = false
    private var wantsPlayback = false
    private var isRamping = false
    private let colorContext = CIContext(options: [.cacheIntermediates: false])
    private var colorPool: CVPixelBufferPool?
    private var colorPoolSize = CGSize.zero
    private var sourceBuffer: CVPixelBuffer?
    private var appearanceTransition: (start: CFTimeInterval, from: Float, to: Float, duration: Double)?
    private(set) var desktopLookAmount: Float = 1
    private(set) var latestBuffer: CVPixelBuffer?
    private(set) var presentedFrames = 0
    private(set) var nilFrames = 0

    init(size: CGSize, scale: CGFloat, resources: URL = Bundle.main.resourceURL!) throws {
        self.resources = resources
        self.configuration = WallpaperConfiguration.load(resources: resources)
        let url = resources.appendingPathComponent("playlist.json")
        movies = try JSONDecoder().decode([Movie].self, from: Data(contentsOf: url))
        guard !movies.isEmpty else { throw CocoaError(.fileReadNoSuchFile) }
        root.frame = CGRect(origin: .zero, size: size)
        root.contentsScale = scale
        root.backgroundColor = NSColor.black.cgColor
        display.frame = root.bounds
        display.videoGravity = configuration.fillScreen ? .resizeAspectFill : .resizeAspect
        root.addSublayer(display)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        if let image = NSImage(contentsOf: resources.appendingPathComponent("ScreenSaverPreview.png"))?.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let buffer = Self.pixelBuffer(image: image) { present(buffer) }
        chooseNextMovie()
    }

    func resize(_ size: CGSize, scale: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: size)
        root.contentsScale = scale
        display.frame = root.bounds
        CATransaction.commit()
    }

    private func chooseNextMovie() {
        let previous = movie?.id
        if configuration.shuffle {
            movie = movies.filter { $0.id != previous }.randomElement() ?? movies.first
        } else {
            movieIndex = (movieIndex + 1) % movies.count
            movie = movies[movieIndex]
        }
        guard let movie else { return }
        movieGeneration += 1
        let generation = movieGeneration
        isLoadingMovie = true
        firstFrame = false
        player.pause()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        let url = resources.appendingPathComponent("Movies/" + movie.file)
        let item = AVPlayerItem(url: url)
        let install: () -> Void = { [weak self] in
            guard let self, self.movieGeneration == generation else { return }
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ])
            item.add(output)
            self.output = output
            self.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                object: item, queue: .main) { [weak self] _ in
                    guard let self, self.wantsPlayback, self.movieGeneration == generation else { return }
                    self.chooseNextMovie()
                }
            self.player.replaceCurrentItem(with: item)
            self.isLoadingMovie = false
            self.player.play()
            self.startPump()
            extensionLog("movie=\(movie.id)")
        }
        if movie.needsComposition == true {
            // Let AVFoundation apply the phone video's rotation/mirroring before decoding output.
            AVVideoComposition.videoComposition(withPropertiesOf: item.asset) { composition, error in
                DispatchQueue.main.async {
                    guard composition != nil else {
                        extensionLog("orientation composition failed: \(String(describing: error))")
                        return
                    }
                    item.videoComposition = composition
                    install()
                }
            }
        } else { install() }
    }

    private func startPump() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.pump() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pump() {
        guard let output else { return }
        let appearanceChanged = advanceAppearance()
        if isLoadingMovie {
            if appearanceChanged, let sourceBuffer { present(sourceBuffer) }
            return
        }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: time),
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            present(buffer)
            firstFrame = true
        } else {
            nilFrames += 1
            // Recolor the held frame too, including the last slow frames and snapshots.
            if appearanceChanged, let sourceBuffer { present(sourceBuffer) }
        }
        if !wantsPlayback && !isRamping && firstFrame {
            player.pause()
            if appearanceTransition == nil { timer?.invalidate(); timer = nil }
        }
        if wantsPlayback, firstFrame, player.currentItem?.status == .readyToPlay, let movie, movie.duration > 0,
           player.currentTime().seconds >= movie.duration - 0.04 { chooseNextMovie() }
    }

    private func present(_ buffer: CVPixelBuffer) {
        sourceBuffer = buffer
        let buffer = colorAdjusted(buffer)
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &description) == noErr, let description else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
            let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if display.status == .failed {
            // Keep the still visible until there is a replacement sample to enqueue.
            display.flush()
        }
        display.enqueue(sample)
        latestBuffer = buffer
        presentedFrames += 1
    }

    private func colorAdjusted(_ source: CVPixelBuffer) -> CVPixelBuffer {
        // Original decoded pixels are retained, so restoring full color never compounds a filter.
        guard desktopLookAmount > 0.00001 && !configuration.neutral else { return source }
        let size = CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        if colorPool == nil || colorPoolSize != size {
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            colorPool = nil
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &colorPool)
            colorPoolSize = size
        }
        var destination: CVPixelBuffer?
        guard let colorPool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, colorPool, &destination) == kCVReturnSuccess,
              let destination else { return source }
        CVBufferPropagateAttachments(source, destination)
        let input = CIImage(cvPixelBuffer: source)
        let image = configuration.image(input, amount: desktopLookAmount)
        colorContext.render(image, to: destination, bounds: image.extent,
                            colorSpace: input.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
        return destination
    }

    @discardableResult private func advanceAppearance() -> Bool {
        guard let transition = appearanceTransition else { return false }
        let progress = min(1, (CACurrentMediaTime() - transition.start) / transition.duration)
        let eased = Float(progress * progress * (3 - 2 * progress))
        desktopLookAmount = transition.from + (transition.to - transition.from) * eased
        if progress >= 1 { desktopLookAmount = transition.to; appearanceTransition = nil }
        return true
    }

    private func transitionAppearance(to target: Float, duration: Double) {
        advanceAppearance()
        guard abs(desktopLookAmount - target) > 0.00001 else { appearanceTransition = nil; return }
        if duration <= 0 {
            desktopLookAmount = target; appearanceTransition = nil
            if let sourceBuffer { present(sourceBuffer) }
        } else {
            appearanceTransition = (CACurrentMediaTime(), desktopLookAmount, target, duration)
            startPump()
        }
    }

    func setPlaying(_ playing: Bool, smoothly: Bool = true) {
        guard wantsPlayback != playing || !firstFrame else { return }
        wantsPlayback = playing
        transitionAppearance(to: playing ? 0 : 1, duration: smoothly ? (playing ? configuration.resumeDuration : configuration.stopDuration) : 0)
        rampGeneration += 1
        let generation = rampGeneration
        if playing {
            isRamping = false
            startPump()
            if !isLoadingMovie { player.play() }
            extensionLog("resume time=\(player.currentTime().seconds)")
        } else if firstFrame && smoothly && player.rate > 0 {
            isRamping = true
            let initialRate = player.rate
            let startedAt = CACurrentMediaTime()
            var rampTimer: Timer?
            rampTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                guard let self, self.rampGeneration == generation, !self.wantsPlayback else {
                    timer.invalidate(); return
                }
                let progress = min(1, (CACurrentMediaTime() - startedAt) / self.configuration.stopDuration)
                self.player.rate = initialRate * Float(pow(1 - progress, 2))
                if progress >= 1 {
                    self.player.pause()
                    self.pump()
                    self.isRamping = false
                    if self.appearanceTransition == nil { self.timer?.invalidate(); self.timer = nil }
                    timer.invalidate()
                    extensionLog("frozen time=\(self.player.currentTime().seconds) frames=\(self.presentedFrames)")
                }
            }
            RunLoop.main.add(rampTimer!, forMode: .common)
        } else if firstFrame {
            player.pause()
            if appearanceTransition == nil { timer?.invalidate(); timer = nil }
        }
    }

    func snapshot() -> AnyObject? {
        guard let latestBuffer, let surface = CVPixelBufferGetIOSurface(latestBuffer)?.takeUnretainedValue() else { return nil }
        return createSnapshotXPC(surface: surface)
    }

    private static func pixelBuffer(image: CGImage) -> CVPixelBuffer? {
        let width = min(1920, image.width), height = max(1, image.height * width / image.width)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
            let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    deinit {
        timer?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player.pause(); player.replaceCurrentItem(with: nil)
    }
}
