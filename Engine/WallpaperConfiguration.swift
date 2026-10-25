import Foundation
import CoreImage

struct WallpaperConfiguration: Codable {
    var projectID = UUID().uuidString.lowercased()
    var name = "我的壁纸"
    var exposure: Double = -0.12
    var vibrance: Double = -0.10
    var saturation: Double = 1
    var contrast: Double = 1
    var stopDuration: Double = 1.2
    var resumeDuration: Double = 0.4
    var shuffle = true
    var fillScreen = true

    var providerID: String { "local.videowallpaper.p" + projectID.replacingOccurrences(of: "-", with: "") }
    var neutral: Bool { abs(exposure) < 0.00001 && abs(vibrance) < 0.00001 && abs(saturation - 1) < 0.00001 && abs(contrast - 1) < 0.00001 }

    func normalized() throws -> Self {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.name.isEmpty, result.name.count <= 60, result.name.utf8.count <= 180,
              !result.name.hasPrefix("."),
              result.name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\0\n\r\t")) == nil,
              UUID(uuidString: projectID) != nil else {
            throw MakerError.message("名称请填写 1～60 个字，不含斜线、冒号或换行。")
        }
        func bound(_ value: Double, _ low: Double, _ high: Double) -> Double { value.isFinite ? min(high, max(low, value)) : low }
        result.exposure = bound(exposure, -0.75, 0.5)
        result.vibrance = bound(vibrance, -1, 1)
        result.saturation = bound(saturation, 0, 2)
        result.contrast = bound(contrast, 0.5, 1.5)
        result.stopDuration = bound(stopDuration, 0.3, 5)
        result.resumeDuration = bound(resumeDuration, 0.1, 2)
        return result
    }

    static func load(resources: URL) -> Self {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("wallpaper.json")),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              let normalized = try? value.normalized() else { return Self() }
        return normalized
    }

    func image(_ source: CIImage, amount: Float = 1) -> CIImage {
        let strength = Double(amount)
        var image = source
        if abs(vibrance * strength) > 0.00001 {
            image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": vibrance * strength])
        }
        if abs((saturation - 1) * strength) > 0.00001 || abs((contrast - 1) * strength) > 0.00001 {
            image = image.applyingFilter("CIColorControls", parameters: [
                "inputSaturation": 1 + (saturation - 1) * strength,
                "inputContrast": 1 + (contrast - 1) * strength,
            ])
        }
        if abs(exposure * strength) > 0.00001 {
            image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": exposure * strength])
        }
        return image
    }
}

enum MakerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
