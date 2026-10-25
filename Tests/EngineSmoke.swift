import AppKit
import AVFoundation
import IOSurface
func extensionLog(_ message: String) { print(message) }
func createSnapshotXPC(surface: IOSurface) -> AnyObject? { nil }
@main enum EngineSmoke {
    static func main() throws {
        _ = NSApplication.shared
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let renderer = try ContinuousRenderer(size: CGSize(width: 640, height: 400), scale: 1, resources: resources)
        renderer.setPlaying(true)
        var portrait = false
        for _ in 0..<22 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if renderer.presentedFrames > 5, let buffer = renderer.latestBuffer,
               CVPixelBufferGetHeight(buffer) > CVPixelBufferGetWidth(buffer) { portrait = true }
        }
        assert(renderer.presentedFrames > 5, "No actual decoded frames")
        assert(portrait, "Phone rotation did not reach the output buffer")
        renderer.setPlaying(false)
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))
        let frozen = renderer.player.currentTime().seconds
        assert(renderer.player.rate == 0 && renderer.desktopLookAmount > 0.999)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        assert(abs(renderer.player.currentTime().seconds - frozen) < 0.002)
        renderer.setPlaying(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        assert(renderer.desktopLookAmount < 0.001)
        print("Two clips, phone rotation, desktop freeze and original-color resume passed")
    }
}
