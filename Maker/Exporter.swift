import AppKit
import AVFoundation
import Foundation

struct ProjectDocument: Codable {
    var configuration: WallpaperConfiguration
    var clips: [String]
    var posterIndex: Int = 0
    var posterTime: Double = 0.7

    func request(relativeTo folder: URL, output: URL, zip: Bool) throws -> BuildRequest {
        let base = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let urls = try clips.map { path -> URL in
            let url = folder.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(base) else { throw MakerError.message("作品文件中的视频路径超出了作品文件夹。") }
            return url
        }
        return BuildRequest(configuration: try configuration.normalized(), clips: urls, output: output,
                            zip: zip, posterIndex: posterIndex, posterTime: posterTime)
    }
}

struct BuildRequest {
    var configuration: WallpaperConfiguration
    var clips: [URL]
    var output: URL
    var zip: Bool
    var posterIndex: Int
    var posterTime: Double
}

struct VideoInfo {
    var duration: Double
    var needsComposition: Bool
    var size: CGSize

    static func read(_ url: URL) async throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MakerError.message("找不到视频：\(url.lastPathComponent)") }
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard playable, duration.isFinite, duration > 0.05, let track = tracks.first else {
            throw MakerError.message("无法播放“\(url.lastPathComponent)”。请使用可播放的 MOV、MP4 或 M4V 视频。")
        }
        let transform = try await track.load(.preferredTransform)
        let natural = try await track.load(.naturalSize)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        return Self(duration: duration, needsComposition: !transform.isIdentity,
                    size: CGSize(width: abs(rect.width), height: abs(rect.height)))
    }
}

struct ExportedMovie: Codable {
    let id: String
    let file: String
    let duration: Double
    let needsComposition: Bool
}

enum Exporter {
    static func command(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) async throws -> String {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new } }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperMaker-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        do {
            while process.isRunning { try await Task.sleep(nanoseconds: 100_000_000) }
        } catch {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            throw error
        }
        let data = (try? Data(contentsOf: log)) ?? Data()
        let text = String(decoding: data.suffix(24_000), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw MakerError.message("操作未完成：\(text.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return text
    }

    static func copy(_ source: URL, to target: URL) async throws {
        do { _ = try await command("/bin/cp", ["-cR", source.path, target.path]) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        }
        try Task.checkCancellation()
    }

    static func plist(_ values: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: url)
    }

    static func hash(_ bundle: URL) async throws -> String {
        let result = try await command("/usr/bin/codesign", ["-d", "--verbose=4", bundle.path])
        guard let line = result.split(separator: "\n").first(where: { $0.hasPrefix("CDHash=") }) else {
            throw MakerError.message("无法读取生成程序的签名。")
        }
        return String(line.dropFirst(7))
    }

    static func generate(_ request: BuildRequest, progress: @escaping (String, Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        let configuration = try request.configuration.normalized()
        guard !request.clips.isEmpty else { throw MakerError.message("请先添加至少一段视频。") }
        guard let resources = Bundle.main.resourceURL else { throw MakerError.message("制作器资源缺失，请重新获取完整应用。") }
        let template = resources.appendingPathComponent("Template.zip")
        guard fm.fileExists(atPath: template.path) else { throw MakerError.message("缺少壁纸引擎模板。") }
        var infos = [VideoInfo]()
        for (index, url) in request.clips.enumerated() {
            progress("读取视频 \(index + 1)/\(request.clips.count)：\(url.lastPathComponent)", 0.05)
            infos.append(try await VideoInfo.read(url))
        }
        try fm.createDirectory(at: request.output, withIntermediateDirectories: true)
        let inputBytes = request.clips.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let capacity = try? request.output.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let capacity, capacity < inputBytes * (request.zip ? 2 : 1) + 30_000_000 {
            throw MakerError.message("输出磁盘空间不足，请更换文件夹或关闭“同时生成分享 ZIP”。")
        }
        let staging = request.output.appendingPathComponent(".壁纸制作器-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: staging) } }
        let filename = configuration.name + ".app"
        let app = staging.appendingPathComponent(filename)
        progress("准备壁纸引擎…", 0.1)
        _ = try await command("/usr/bin/ditto", ["-x", "-k", template.path, staging.path])
        try fm.moveItem(at: staging.appendingPathComponent("VideoWallpaper.app"), to: app)
        let ext = app.appendingPathComponent("Contents/Extensions/VideoWallpaperExtension.appex")
        let media = ext.appendingPathComponent("Contents/Resources")
        let movies = media.appendingPathComponent("Movies")
        try fm.createDirectory(at: movies, withIntermediateDirectories: true)
        var playlist = [ExportedMovie]()
        for (index, source) in request.clips.enumerated() {
            let file = String(format: "%04d", index + 1) + "." + (source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased())
            progress("复制视频 \(index + 1)/\(request.clips.count)…", 0.15 + 0.55 * Double(index) / Double(request.clips.count))
            try await copy(source, to: movies.appendingPathComponent(file))
            playlist.append(ExportedMovie(id: String(index), file: file, duration: infos[index].duration,
                                          needsComposition: infos[index].needsComposition))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: media.appendingPathComponent("wallpaper.json"))
        try encoder.encode(playlist).write(to: media.appendingPathComponent("playlist.json"))
        let posterIndex = min(max(0, request.posterIndex), request.clips.count - 1)
        let posterTime = min(max(0, request.posterTime.isFinite ? request.posterTime : 0.7), max(0, infos[posterIndex].duration - 0.04))
        progress("生成封面…", 0.73)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: request.clips[posterIndex]))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        let image = try generator.copyCGImage(at: CMTime(seconds: posterTime, preferredTimescale: 600), actualTime: nil)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw MakerError.message("无法生成封面。") }
        try png.write(to: media.appendingPathComponent("ScreenSaverPreview.png"))

        for (bundle, identifier) in [(app, configuration.providerID), (ext, configuration.providerID + ".extension")] {
            let path = bundle.appendingPathComponent("Contents/Info.plist")
            var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as! [String: Any]
            info["CFBundleIdentifier"] = identifier
            info["CFBundleDisplayName"] = configuration.name
            info["CFBundleName"] = configuration.name
            try plist(info, to: path)
        }
        for attribute in ["com.apple.quarantine", "com.apple.FinderInfo", "com.apple.ResourceFork"] {
            _ = try? await command("/usr/bin/xattr", ["-dr", attribute, app.path])
        }
        progress("签名与打包…", 0.8)
        let entitlements = resources.appendingPathComponent("EngineSources/Sandbox.entitlements")
        _ = try await command("/usr/bin/codesign", ["--force", "--sign", "-", "--entitlements", entitlements.path, ext.path])
        _ = try await command("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        let hostHash = try await hash(app), extHash = try await hash(ext)
        try plist(["appFile": filename, "provider": configuration.providerID, "extension": configuration.providerID + ".extension",
                   "hostHash": hostHash, "extensionHash": extHash], to: staging.appendingPathComponent(".安装信息.plist"))
        let installer = staging.appendingPathComponent("安装.command")
        try Installer.text.write(to: installer, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installer.path)
        let relative = playlist.map { "\(filename)/Contents/Extensions/VideoWallpaperExtension.appex/Contents/Resources/Movies/\($0.file)" }
        try encoder.encode(ProjectDocument(configuration: configuration, clips: relative, posterIndex: posterIndex, posterTime: posterTime))
            .write(to: staging.appendingPathComponent("作品.json"))
        let guide = """
        \(configuration.name)

        安装：先把整个文件夹放在 Mac 本地，再双击“安装.command”。如果系统拦截脚本，打开终端，输入 /bin/zsh 和一个空格，把“安装.command”拖进去，按回车。
        使用：在系统设置 → 墙纸中选“\(configuration.name)”，屏幕保护程序选“自动”。屏保播放，回到桌面时缓停并保留画面。不会自动更改触发角或锁屏安全设置。
        修改：用“壁纸制作器”打开本文件夹里的“作品.json”，调整名称、视频或参数，再生成。保留整份作品文件夹即可继续编辑。
        分享：可发送同名 ZIP；对方不需要制作器、Xcode 或重新下载视频。仅支持 Apple Silicon / macOS 26+，当前引擎在 macOS 27 验证；非公开系统接口可能随系统升级变化。程序为本地签名，未作 Apple 开发者公证。
        视频为静音播放；多段视频按选定的随机或顺序方式循环。重启或扩展进程退出后会重新选片，不保证仍是之前那一帧。
        卸载：先选其他墙纸，再把 ~/Applications/\(filename) 移到废纸篓。更新前的同名旧版本会留在 ~/Library/Application Support/VideoWallpaperInstaller/Backups/。
        """
        try guide.write(to: staging.appendingPathComponent("使用说明.txt"), atomically: true, encoding: .utf8)
        try fm.copyItem(at: resources.appendingPathComponent("EngineSources/Vendor/PHOSPHENE-LICENSE"), to: staging.appendingPathComponent("引擎许可.txt"))
        try Task.checkCancellation()
        var destination = request.output.appendingPathComponent(configuration.name)
        if fm.fileExists(atPath: destination.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            destination = request.output.appendingPathComponent(configuration.name + "-" + stamp + "-" + String(UUID().uuidString.prefix(4)))
        }
        try fm.moveItem(at: staging, to: destination)
        committed = true
        if request.zip {
            progress("生成分享 ZIP（保留原视频画质）…", 0.9)
            let archive = destination.appendingPathExtension("zip")
            do {
                _ = try await command("/usr/bin/ditto", ["-c", "-k", "--keepParent", "--noextattr", "--norsrc", "--zlibCompressionLevel", "0", destination.path, archive.path])
            } catch {
                try? fm.removeItem(at: archive)
                if error is CancellationError { throw MakerError.message("已取消分享 ZIP。生成的作品文件夹已保留。") }
                throw MakerError.message("作品已生成，但 ZIP 未完成：\(error.localizedDescription)\n文件夹：\(destination.path)")
            }
        }
        progress("生成完成", 1)
        return destination
    }
}

enum Installer {
    static let text = #"""
    #!/bin/zsh
    set -euo pipefail
    PACKAGE="${0:A:h}"
    INFO="$PACKAGE/.安装信息.plist"
    value() { /usr/bin/plutil -extract "$1" raw "$INFO"; }
    APP_FILE="$(value appFile)"
    PROVIDER="$(value provider)"
    EXTENSION="$(value extension)"
    [[ "$APP_FILE" != */* && "$APP_FILE" != .* && "$APP_FILE" == *.app && "$PROVIDER" == local.videowallpaper.p* ]] || exit 1
    [[ "$(/usr/bin/uname -m)" == arm64 && "$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)" -ge 26 ]] || { print -u2 '需要 Apple Silicon 和 macOS 26 或更新版本。'; exit 1; }
    SOURCE="$PACKAGE/$APP_FILE"
    EXT_REL='Contents/Extensions/VideoWallpaperExtension.appex'
    verify() {
      /usr/bin/codesign --verify --deep --strict "$1"
      local found="$(/usr/bin/codesign -d --verbose=4 "$1" 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print $2}')"
      [[ "$found" == "$2" ]] || { print -u2 '文件校验不符，请重新获取完整安装包。'; exit 1; }
    }
    verify "$SOURCE" "$(value hostHash)"
    verify "$SOURCE/$EXT_REL" "$(value extensionHash)"
    if [[ "${1:-}" == --verify-only ]]; then print '校验通过'; exit 0; fi
    APPS="$HOME/Applications"
    DEST="$APPS/$APP_FILE"
    if [[ -e "$DEST" ]]; then
      EXISTING="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$DEST/Contents/Info.plist" 2>/dev/null || true)"
      [[ "$EXISTING" == "$PROVIDER" ]] || { print -u2 '已有其他同名应用。请在制作器中换一个名称，或打开原作品进行更新。'; exit 1; }
    fi
    /bin/mkdir -p "$APPS"
    STAGE="$(/usr/bin/mktemp -d "$APPS/.VideoWallpaper.XXXXXX")"
    BACKUP="$HOME/Library/Application Support/VideoWallpaperInstaller/Backups/$(/bin/date +%Y%m%d-%H%M%S)-$$"
    OLD=0; NEW=0; COMMITTED=0
    cleanup() {
      local exit_status=$?
      if (( ! COMMITTED )); then
        if (( NEW )); then /bin/mv "$DEST" "$STAGE/failed.app"; fi
        if (( OLD )); then /bin/mv "$BACKUP/$APP_FILE" "$DEST"; fi
      fi
      [[ "$STAGE" == "$APPS"/.VideoWallpaper.* ]] && /bin/rm -rf "$STAGE"
      return $exit_status
    }
    trap cleanup EXIT
    /usr/bin/ditto --noextattr --norsrc --noqtn "$SOURCE" "$STAGE/$APP_FILE"
    verify "$STAGE/$APP_FILE" "$(value hostHash)"
    if [[ -e "$DEST" ]]; then
      # Exact literal path match: do not stop another generated wallpaper's extension.
      EXT_BINARY="$DEST/$EXT_REL/Contents/MacOS/VideoWallpaperExtension"
      while read -r process_id command_line; do
        if [[ "$command_line" == "$EXT_BINARY" || "$command_line" == "$EXT_BINARY "* ]]; then
          /bin/kill -TERM "$process_id" 2>/dev/null || true
        fi
      done < <(/bin/ps -U "$UID" -o pid=,command=)
      /bin/mkdir -p "$BACKUP"; /bin/mv "$DEST" "$BACKUP/$APP_FILE"; OLD=1
    fi
    /bin/mv "$STAGE/$APP_FILE" "$DEST"; NEW=1
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
    /usr/bin/pluginkit -a "$DEST/$EXT_REL"
    /usr/bin/pluginkit -e use -i "$EXTENSION"
    COMMITTED=1
    # WallpaperAgent reconnects to the new code. No authentication or wallpaper preferences are changed.
    /usr/bin/pkill -u "$UID" -x WallpaperAgent || true
    print '已安装。请在墙纸设置中选择这份壁纸，屏幕保护程序选“自动”。'
    if [[ "${VIDEO_WALLPAPER_NO_OPEN:-0}" != 1 ]]; then /usr/bin/open "$DEST"; fi
    """# + "\n"
}
