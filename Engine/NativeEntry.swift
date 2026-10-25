import AppKit
import ExtensionFoundation
import Foundation
import Security
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "local.videowallpaper", category: "wallpaper")
func extensionLog(_ message: String) { logger.notice("\(message, privacy: .public)") }
func traceLog(_ message: String) { extensionLog(message) }

@main final class VideoWallpaperExtension: NSObject, AppExtension {
    override required init() {
        super.init()
        _ = dlopen("/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit", RTLD_LAZY)
        extensionLog("extension loaded")
    }
    var configuration: some AppExtensionConfiguration { VideoWallpaperConfiguration() }
}

struct VideoWallpaperConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        // Only signed Apple hosts may drive the wallpaper. Unknown identities fail closed.
        guard connection.responds(to: NSSelectorFromString("auditToken")) else { return false }
        var token = connection.auditToken
        let data = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?, requirement: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess,
              let code, SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        let interface = NSXPCInterface(with: WallpaperExtensionXPCProtocol.self)
        let classSet = NSMutableSet(array: [NSString.self, NSNumber.self, NSData.self, NSArray.self, NSDictionary.self, NSURL.self, NSError.self])
        for name in ["WallpaperIDXPC", "WallpaperCreationRequestXPC", "WallpaperUpdateRequestXPC", "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC", "WallpaperContentTypeSetXPC", "WallpaperChoiceIDXPC", "WallpaperChoiceIDsXPC", "WallpaperExtensionChoiceRequestXPC", "WallpaperChoiceRequestAdditionResultXPC", "WallpaperDebugRequestXPC", "WallpaperDebugResponseXPC", "WallpaperMigrationVersionXPC", "WallpaperSettingsViewModelsXPC", "AuditTokenXPC"] {
            if let cls = NSClassFromString(name) { classSet.add(cls) }
        }
        let classes = classSet as! Set<AnyHashable>
        for (name, count, reply) in [
            ("acquireWithId:request:reply:",2,true), ("updateWithId:request:reply:",2,false),
            ("invalidateWithId:reply:",1,false), ("snapshotWithId:reply:",1,true),
            ("provideSettingsViewModelsWithContentTypes:reply:",1,true),
            ("addChoiceRequestWithChoiceRequest:onBehalfOfProcess:reply:",2,true),
            ("removeChoiceRequestWithChoiceRequest:reply:",1,false), ("selectedChoicesDidChangeFor:reply:",1,false),
            ("invokeContextMenuActionWithMenuItemID:groupItemID:reply:",2,false),
            ("isChoiceDownloadedWith:reply:",1,false), ("downloadWithChoiceID:reply:",1,false),
            ("pauseDownloadFor:reply:",1,false), ("cancelDownloadFor:reply:",1,false),
            ("resumeDownloadFor:reply:",1,false), ("removeDownloadFor:reply:",1,false),
            ("migrateSelectedChoiceFor:reply:",1,true), ("migrateFrom:to:reply:",2,false),
            ("skipShuffledContentWithId:reply:",1,false), ("canSkipShuffledContentWithId:reply:",1,false),
            ("handleDebugRequestFor:reply:",1,true), ("handleNotificationWithNamed:reply:",1,false)] {
            let selector = NSSelectorFromString(name)
            for i in 0..<count { interface.setClasses(classes, for: selector, argumentIndex: i, ofReply: false) }
            if reply { interface.setClasses(classes, for: selector, argumentIndex: 0, ofReply: true) }
        }
        connection.exportedInterface = interface
        connection.remoteObjectInterface = NSXPCInterface(with: WallpaperExtensionProxyXPCProtocol.self)
        connection.exportedObject = Handler()
        connection.resume()
        return true
    }
}

private func property(_ name: String, in value: Any, depth: Int = 0) -> Any? {
    guard depth < 8 else { return nil }
    for child in Mirror(reflecting: value).children {
        if child.label == name { return child.value }
        if let found = property(name, in: child.value, depth: depth + 1) { return found }
    }
    return nil
}
private func caseName(_ value: Any?) -> String {
    guard let value else { return "unknown" }
    let mirror = Mirror(reflecting: value)
    return mirror.displayStyle == .enum ? (mirror.children.first?.label ?? String(describing: value)) : String(describing: value)
}
private func uuid(_ value: Any?, depth: Int = 0) -> UUID? {
    guard let value, depth < 8 else { return nil }
    if let value = value as? UUID { return value }
    for child in Mirror(reflecting: value).children { if let result = uuid(child.value, depth: depth + 1) { return result } }
    return nil
}

private final class Surface {
    let context: CAContext
    let renderer: ContinuousRenderer
    let preview: Bool
    init(size: CGSize, scale: CGFloat, preview: Bool) throws {
        guard let context = CAContext.remoteContext() as? CAContext, context.contextId != 0 else { throw CocoaError(.featureUnsupported) }
        self.context = context; self.preview = preview
        renderer = try ContinuousRenderer(size: size, scale: scale)
        context.layer = renderer.root
        renderer.setPlaying(preview)
        CATransaction.flush()
    }
}

final class Handler: NSObject, WallpaperExtensionXPCProtocol {
    // Accessed only on the main queue, retained across XPC reconnections so that
    // WallpaperAgent can keep the same context and exact frame through unlock.
    private static var surfaces: [String: Surface] = [:]
    private static var ids: [UUID: String] = [:]
    func acquire(withId id: Any?, request: Any?, reply: @escaping (Any?, Error?) -> Void) {
        DispatchQueue.main.async {
            do {
                let size = request.flatMap { property("size", in: $0) as? CGSize } ?? CGSize(width: 1920, height: 1080)
                let scale = request.flatMap { property("scaleFactor", in: $0) as? CGFloat } ?? 1
                let display = request.flatMap { property("directDisplayID", in: $0) as? UInt32 } ?? 0
                let preview = request.flatMap { property("isPreview", in: $0) as? Bool } ?? false
                let key = "\(display)-\(preview ? "preview" : "live")"
                let surface: Surface
                if let previous = Self.surfaces[key] { surface = previous; surface.renderer.resize(size, scale: scale) }
                else { surface = try Surface(size: size, scale: scale, preview: preview); Self.surfaces[key] = surface }
                if let id = uuid(id) { Self.ids[id] = key }
                let mode = caseName(request.flatMap { property("presentationMode", in: $0) })
                let activity = caseName(request.flatMap { property("activityState", in: $0) })
                surface.renderer.setPlaying(!activity.lowercased().contains("suspended") &&
                    (preview || mode == "idle" || mode == "locked"))
                extensionLog("acquire slot=\(key) context=\(surface.context.contextId)")
                reply(createRemoteContextXPC(contextId: surface.context.contextId), nil)
            } catch { reply(nil, error) }
        }
    }
    func update(withId id: Any?, request: Any?, reply: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            let mode = caseName(request.flatMap { property("presentationMode", in: $0) })
            let active = caseName(request.flatMap { property("activityState", in: $0) })
            let key = uuid(id).flatMap { Self.ids[$0] }
            if let key, let surface = Self.surfaces[key] {
                let playing = !active.lowercased().contains("suspended") && (surface.preview || mode == "idle" || mode == "locked")
                surface.renderer.setPlaying(playing)
                extensionLog("update slot=\(key) mode=\(mode) activity=\(active) playing=\(playing)")
            }
            reply(nil)
        }
    }
    func invalidate(withId id: Any?, reply: @escaping (Error?) -> Void) {
        // A native wallpaper may drop and reacquire a connection during unlock.
        // Keep the context and frozen drawable; merely pause the invalidated slot.
        DispatchQueue.main.async {
            if let key = uuid(id).flatMap({ Self.ids[$0] }) { Self.surfaces[key]?.renderer.setPlaying(false, smoothly: true) }
            reply(nil)
        }
    }
    func snapshot(withId id: Any?, reply: @escaping (Any?, Error?) -> Void) {
        DispatchQueue.main.async {
            let surface = uuid(id).flatMap { Self.ids[$0] }.flatMap { Self.surfaces[$0] } ?? Self.surfaces.values.first
            reply(surface?.renderer.snapshot(), nil)
        }
    }
    func provideSettingsViewModels(withContentTypes types: Any?, reply: @escaping (Any?, Error?) -> Void) { reply(settings(), nil) }
    func addChoiceRequest(withChoiceRequest request: Any?, onBehalfOfProcess process: Any?, reply: @escaping (Any?, Error?) -> Void) { reply(nil,nil) }
    func removeChoiceRequest(withChoiceRequest request: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func selectedChoicesDidChange(for id: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func invokeContextMenuAction(withMenuItemID menu: Any?, groupItemID group: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func isChoiceDownloaded(with id: Any?, reply: @escaping (NSNumber?, Error?) -> Void) { reply(true,nil) }
    func download(withChoiceID id: Any?, reply: @escaping (Error?) -> Void) -> Any? { reply(nil); return nil }
    func pauseDownload(for id: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func cancelDownload(for id: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func resumeDownload(for id: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func removeDownload(for id: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func migrateSelectedChoice(for id: Any?, reply: @escaping (Any?, Error?) -> Void) { reply(nil,nil) }
    func migrate(from fromID: Any?, to toID: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func skipShuffledContent(withId id: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
    func canSkipShuffledContent(withId id: Any?, reply: @escaping (Bool, Error?) -> Void) { reply(false,nil) }
    func handleDebugRequest(for request: Any?, reply: @escaping (Any?, Error?) -> Void) { reply(nil,nil) }
    func handleNotification(withNamed name: Any?, reply: @escaping (Error?) -> Void) { reply(nil) }
}

private func settings() -> AnyObject? {
    guard let thumbnail = Bundle.main.url(forResource: "ScreenSaverPreview", withExtension: "png") else { return nil }
    let configuration = WallpaperConfiguration.load(resources: Bundle.main.resourceURL!)
    let provider = ChoiceProviderID(rawValue: Bundle.main.bundleIdentifier!)
    let id = ChoiceID(id: "video-wallpaper", descriptor: ChoiceIDDescriptor(provider: provider, identifier: "video-wallpaper", files: [], configuration: Data("video-wallpaper".utf8)))
    let choice = ChoiceDescriptor(id: id, provider: provider, identifier: "video-wallpaper", name: configuration.name, localizedDescription: "", thumbnail: .image(url: thumbnail), isDownloaded: true, options: [])
    let item = SettingsItem(id: id, localizedName: configuration.name, thumbnail: .image(url: thumbnail), choice: choice, contentBadge: .video, showInTopLevel: true, sortOrder: 0, disposability: .none, contextMenu: nil)
    let group = SettingsGroup(id: GroupID(id: Bundle.main.bundleIdentifier!), items: [item], localizedName: configuration.name, disposability: .none, sortOrder: -100, sortID: GroupSortID(id: "com.apple.wallpaper.aerials"), allChoiceID: nil, shouldHideItemLabels: false, contextMenu: nil, thumbnail: nil)
    let model = SettingsViewModel(groups: [group], refreshPolicy: .default, isModificationDisabled: false)
    let value = SettingsViewModels(desktop: model, screenSaver: model)
    // Local, self-created archive only; never decode data received over XPC here.
    guard let data = try? NSKeyedArchiver.archivedData(withRootObject: ShimViewModelsXPC(value: value), requiringSecureCoding: false),
          let realClass = NSClassFromString("WallpaperSettingsViewModelsXPC"),
          let decoder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    decoder.requiresSecureCoding = false
    decoder.decodingFailurePolicy = .setErrorAndReturn
    decoder.setClass(realClass, forClassName: "ShimViewModelsXPC")
    let result = decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    decoder.finishDecoding()
    if let error = decoder.error { extensionLog("settings error=\(error.localizedDescription)") }
    return result as AnyObject?
}
