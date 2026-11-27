import AppKit
import AVFoundation
import IOSurface
import Darwin
func extensionLog(_ message: String) { print(message); fflush(stdout) }
func createSnapshotXPC(surface: IOSurface) -> AnyObject? { nil }

func memoryMiB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS)
    return Double(info.phys_footprint) / 1_048_576
}

@main enum MemoryProbe {
    static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let seconds = Double(CommandLine.arguments[2])!
        let target = URL(fileURLWithPath: CommandLine.arguments[3])
        var renderer: ContinuousRenderer? = try ContinuousRenderer(size: CGSize(width: 1920, height: 1080), scale: 1, resources: resources)
        let host = CALayer(); host.addSublayer(renderer!.root)
        renderer!.setPlaying(true)
        let start = CACurrentMediaTime()
        var samples = [[String: Double]]()
        var lastPhase = -1
        while CACurrentMediaTime() - start < seconds {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let elapsed = CACurrentMediaTime() - start
            let phase = Int(elapsed / 10)
            if phase != lastPhase {
                lastPhase = phase
                let sample = ["seconds": elapsed, "footprintMiB": memoryMiB(), "frames": Double(renderer!.presentedFrames)]
                samples.append(sample)
                print(sample); fflush(stdout)
            }
            // Stay within a finite diagnostic memory budget on the user's machine.
            if memoryMiB() > 1400 { print("Memory limit reached; ending probe"); break }
        }
        renderer!.setPlaying(false)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let frozen = renderer!.playbackTime.seconds
        let pausedFrames = renderer!.presentedFrames
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let held = abs(renderer!.playbackTime.seconds - frozen) < 0.003
        renderer!.setPlaying(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        let resumed = renderer!.playbackTime.seconds > frozen + 0.05
        precondition(held && resumed, "Freeze or decoder-reload resume failed")
        renderer!.setPlaying(false, smoothly: false)
        renderer!.root.removeFromSuperlayer()
        weak var releasedRenderer = renderer
        renderer = nil
        autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        precondition(releasedRenderer == nil, "Renderer was retained after release")
        let report: [String: Any] = ["samples": samples, "freezeHeld": held, "resumed": resumed,
                                   "pausedFrames": pausedFrames, "afterReleaseMiB": memoryMiB()]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: target)
    }
}
