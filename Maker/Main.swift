import AppKit
import AVFoundation
import AVKit
import UniformTypeIdentifiers
import Darwin

@main enum MakerMain {
    static func main() {
        let app = NSApplication.shared
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--create"), arguments.count > index + 1 {
            app.setActivationPolicy(.prohibited)
            Task.detached {
                do {
                    let projectURL = URL(fileURLWithPath: arguments[index + 1])
                    let output: URL
                    if let out = arguments.firstIndex(of: "--output"), arguments.count > out + 1 {
                        output = URL(fileURLWithPath: arguments[out + 1], isDirectory: true)
                    } else { output = projectURL.deletingLastPathComponent().appendingPathComponent("生成结果") }
                    let document = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: projectURL))
                    let request = try document.request(relativeTo: projectURL.deletingLastPathComponent(), output: output,
                                                       zip: !arguments.contains("--no-zip"))
                    let destination = try await Exporter.generate(request) { text, _ in print(text) }
                    print("OUTPUT=\(destination.path)")
                    exit(0)
                } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            }
            app.run()
            return
        }
        let delegate = MakerDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

struct Clip {
    var url: URL
    var info: VideoInfo
}

final class DropRoot: NSView {
    var receive: (([URL]) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        receive?(urls)
        return !urls.isEmpty
    }
}

final class MakerDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var configuration = WallpaperConfiguration()
    private var clips = [Clip]()
    private var output = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/壁纸作品")
    private let nameField = NSTextField(string: "我的壁纸")
    private let table = NSTableView()
    private let playerView = AVPlayerView()
    private let player = AVPlayer()
    private let previewMode = NSSegmentedControl(labels: ["桌面效果", "屏保原色"], trackingMode: .selectOne, target: nil, action: nil)
    private let preset = NSPopUpButton()
    private let fit = NSPopUpButton()
    private let order = NSPopUpButton()
    private let outputLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "选择或拖入视频")
    private let posterLabel = NSTextField(labelWithString: "封面：默认使用首段视频")
    private let progress = NSProgressIndicator()
    private let share = NSButton(checkboxWithTitle: "同时生成分享 ZIP", target: nil, action: nil)
    private let generate = NSButton(title: "生成", target: nil, action: nil)
    private let cancel = NSButton(title: "取消", target: nil, action: nil)
    private let install = NSButton(title: "安装", target: nil, action: nil)
    private let reveal = NSButton(title: "在访达中显示", target: nil, action: nil)
    private let add = NSButton(title: "添加视频…", target: nil, action: nil)
    private var sliders = [String: NSSlider]()
    private var values = [String: NSTextField]()
    private var result: URL?
    private var posterURL: URL?
    private var posterTime = 0.7
    private var activeTask: Task<Void, Never>?
    private var importing = false
    private var suppressChanges = false
    private var previewGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let data = UserDefaults.standard.data(forKey: "desktopDefaults"),
           var defaults = try? JSONDecoder().decode(WallpaperConfiguration.self, from: data) {
            defaults.projectID = UUID().uuidString.lowercased(); defaults.name = "我的壁纸"
            configuration = defaults
        }
        if let path = UserDefaults.standard.string(forKey: "outputFolder") { output = URL(fileURLWithPath: path, isDirectory: true) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 770),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "壁纸制作器"; window.minSize = NSSize(width: 960, height: 710); window.center(); window.delegate = self
        let root = DropRoot(frame: window.contentView!.bounds)
        root.receive = { [weak self] in self?.importVideos($0) }
        window.contentView = root
        let layout = NSStackView(); layout.orientation = .vertical; layout.alignment = .leading; layout.spacing = 14
        layout.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(layout)
        NSLayoutConstraint.activate([layout.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            layout.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            layout.topAnchor.constraint(equalTo: root.topAnchor, constant: 22), layout.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)])
        let panes = row([], spacing: 24); panes.alignment = .top
        let left = column([]); left.spacing = 12; left.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let nameTitle = label("名称", bold: true)
        nameField.placeholderString = "壁纸名称"; nameField.font = .systemFont(ofSize: 15)
        nameField.setAccessibilityLabel("壁纸名称")
        left.addArrangedSubview(nameTitle); left.addArrangedSubview(nameField)
        add.target = self; add.action = #selector(addVideos)
        let remove = button("移除", #selector(removeVideos))
        left.addArrangedSubview(row([add, remove, spacer()]))
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let title = NSTableColumn(identifier: .init("clip")); title.title = "视频"; title.width = 280
        table.addTableColumn(title); table.headerView = nil; table.rowHeight = 30; table.allowsMultipleSelection = true
        table.delegate = self; table.dataSource = self; table.style = .inset; table.registerForDraggedTypes([.fileURL])
        scroll.documentView = table; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        left.addArrangedSubview(scroll)
        left.addArrangedSubview(row([button("上移", #selector(moveUp)), button("下移", #selector(moveDown)), spacer()]))
        order.addItems(withTitles: ["随机播放", "按列表顺序"])
        left.addArrangedSubview(order)
        left.addArrangedSubview(sliderRow("缓停时长", key: "stop", minimum: 0.3, maximum: 5, value: 1.2))
        let note = NSTextField(wrappingLabelWithString: "MOV、MP4、M4V；静音循环。\n生成后点“安装”，再到系统墙纸中选择。")
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        left.addArrangedSubview(note)
        panes.addArrangedSubview(left)

        let right = column([]); right.spacing = 12
        player.isMuted = true; playerView.player = player; playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false; playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor; playerView.layer?.cornerRadius = 8; playerView.layer?.masksToBounds = true
        playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        playerView.heightAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        let ratio = playerView.heightAnchor.constraint(equalTo: playerView.widthAnchor, multiplier: 0.56)
        ratio.priority = .defaultLow; ratio.isActive = true
        right.addArrangedSubview(playerView)
        previewMode.selectedSegment = 0; previewMode.target = self; previewMode.action = #selector(previewChanged)
        right.addArrangedSubview(row([previewMode, spacer(), button("用当前画面作封面", #selector(selectPoster))]))
        posterLabel.font = .systemFont(ofSize: 11); posterLabel.textColor = .secondaryLabelColor
        right.addArrangedSubview(posterLabel)
        preset.addItems(withTitles: ["柔和", "原色", "自定义"]); preset.target = self; preset.action = #selector(presetChanged)
        fit.addItems(withTitles: ["铺满屏幕（裁切）", "完整显示（留边）"]); fit.target = self; fit.action = #selector(parametersChanged)
        right.addArrangedSubview(row([label("桌面配色"), preset, spacer(), fit]))
        let colorGrid = NSGridView(views: [
            [sliderRow("亮度", key: "exposure", minimum: -0.75, maximum: 0.5, value: -0.12), sliderRow("自然饱和度", key: "vibrance", minimum: -1, maximum: 1, value: -0.1)],
            [sliderRow("饱和度", key: "saturation", minimum: 0, maximum: 2, value: 1), sliderRow("对比度", key: "contrast", minimum: 0.5, maximum: 1.5, value: 1)]
        ])
        colorGrid.columnSpacing = 18; colorGrid.rowSpacing = 12
        right.addArrangedSubview(colorGrid)
        panes.addArrangedSubview(right)
        for view in left.arrangedSubviews { view.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true }
        for view in right.arrangedSubviews { view.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true }
        colorGrid.cell(atColumnIndex: 0, rowIndex: 0).contentView!.widthAnchor.constraint(equalTo: colorGrid.cell(atColumnIndex: 1, rowIndex: 0).contentView!.widthAnchor).isActive = true
        layout.addArrangedSubview(panes)
        panes.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        right.widthAnchor.constraint(equalTo: panes.widthAnchor, constant: -324).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let divider = NSBox(); divider.boxType = .separator; layout.addArrangedSubview(divider)
        outputLabel.lineBreakMode = .byTruncatingMiddle; outputLabel.font = .systemFont(ofSize: 12)
        let outputRow = row([label("输出到"), outputLabel, button("选择文件夹…", #selector(chooseOutput))])
        outputLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        layout.addArrangedSubview(outputRow)
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        progress.heightAnchor.constraint(equalToConstant: 5).isActive = true
        layout.addArrangedSubview(progress)
        share.state = .on; generate.target = self; generate.action = #selector(exportProject); generate.keyEquivalent = "\r"
        generate.bezelStyle = .rounded; generate.contentTintColor = .controlAccentColor
        cancel.target = self; cancel.action = #selector(cancelExport); cancel.isEnabled = false
        install.target = self; install.action = #selector(installProject); install.isEnabled = false
        reveal.target = self; reveal.action = #selector(revealResult); reveal.isEnabled = false
        let actions = row([share, spacer(), reveal, install, cancel, generate]); layout.addArrangedSubview(actions)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingMiddle
        layout.addArrangedSubview(status)
        for view in [divider, outputRow, progress, actions, status] { view.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true }
        makeMenu(); apply(configuration)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func label(_ title: String, bold: Bool = false) -> NSTextField {
        let view = NSTextField(labelWithString: title); view.font = .systemFont(ofSize: 13, weight: bold ? .semibold : .regular); return view
    }
    private func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    private func spacer() -> NSView { let view = NSView(); view.setContentHuggingPriority(.init(1), for: .horizontal); return view }
    private func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let view = NSStackView(views: views); view.orientation = .horizontal; view.spacing = spacing; view.alignment = .centerY; return view
    }
    private func column(_ views: [NSView]) -> NSStackView {
        let view = NSStackView(views: views); view.orientation = .vertical; view.alignment = .leading; view.distribution = .fill; return view
    }
    private func sliderRow(_ title: String, key: String, minimum: Double, maximum: Double, value: Double) -> NSView {
        let slider = NSSlider(value: value, minValue: minimum, maxValue: maximum, target: self, action: #selector(parametersChanged))
        slider.identifier = .init(key); slider.isContinuous = true; slider.setAccessibilityLabel(title)
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        let valueLabel = NSTextField(labelWithString: ""); valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.alignment = .right; valueLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        sliders[key] = slider; values[key] = valueLabel
        let content = column([row([label(title), spacer(), valueLabel]), slider]); content.spacing = 2
        slider.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        return content
    }
    private func makeMenu() {
        let menu = NSMenu()
        let app = NSMenuItem(); menu.addItem(app); app.submenu = NSMenu()
        app.submenu?.addItem(withTitle: "退出壁纸制作器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = NSMenuItem(title: "文件", action: nil, keyEquivalent: ""); menu.addItem(file); file.submenu = NSMenu()
        for (title, selector, key) in [("新建", #selector(newProject), "n"), ("打开作品…", #selector(openProject), "o"), ("添加视频…", #selector(addVideos), "i")] {
            let item = file.submenu!.addItem(withTitle: title, action: selector, keyEquivalent: key); item.target = self
        }
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); edit.submenu = NSMenu(); menu.addItem(edit)
        for (title, selector, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.submenu?.addItem(withTitle: title, action: selector, keyEquivalent: key)
        }
        let help = NSMenuItem(title: "帮助", action: nil, keyEquivalent: ""); help.submenu = NSMenu(); menu.addItem(help)
        let item = help.submenu!.addItem(withTitle: "使用说明", action: #selector(openHelp), keyEquivalent: ""); item.target = self
        NSApp.mainMenu = menu
    }
    private func readConfiguration() -> WallpaperConfiguration {
        var value = configuration; value.name = nameField.stringValue
        value.exposure = sliders["exposure"]!.doubleValue; value.vibrance = sliders["vibrance"]!.doubleValue
        value.saturation = sliders["saturation"]!.doubleValue; value.contrast = sliders["contrast"]!.doubleValue
        value.stopDuration = sliders["stop"]!.doubleValue
        value.shuffle = order.indexOfSelectedItem == 0; value.fillScreen = fit.indexOfSelectedItem == 0
        return value
    }
    private func apply(_ value: WallpaperConfiguration) {
        suppressChanges = true; configuration = value; nameField.stringValue = value.name
        for (key, number) in [("exposure", value.exposure), ("vibrance", value.vibrance), ("saturation", value.saturation), ("contrast", value.contrast), ("stop", value.stopDuration)] { sliders[key]?.doubleValue = number }
        order.selectItem(at: value.shuffle ? 0 : 1); fit.selectItem(at: value.fillScreen ? 0 : 1)
        preset.selectItem(at: value.neutral ? 1 : (abs(value.exposure + 0.12) < 0.0001 && abs(value.vibrance + 0.1) < 0.0001 && value.saturation == 1 && value.contrast == 1 ? 0 : 2))
        updateValues(); suppressChanges = false; outputLabel.stringValue = output.path
    }
    private func updateValues() {
        for (key, slider) in sliders { values[key]?.stringValue = String(format: key == "stop" ? "%.1f 秒" : "%.2f", slider.doubleValue) }
    }
    @objc private func parametersChanged() {
        guard !suppressChanges else { return }; updateValues(); preset.selectItem(at: 2)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(rebuildPreview), object: nil)
        perform(#selector(rebuildPreview), with: nil, afterDelay: 0.12)
    }
    @objc private func presetChanged() {
        var value = readConfiguration()
        if preset.indexOfSelectedItem == 0 { value.exposure = -0.12; value.vibrance = -0.10; value.saturation = 1; value.contrast = 1 }
        else if preset.indexOfSelectedItem == 1 { value.exposure = 0; value.vibrance = 0; value.saturation = 1; value.contrast = 1 }
        apply(value); rebuildPreview()
    }
    @objc private func previewChanged() { rebuildPreview() }
    @objc private func rebuildPreview() {
        guard let item = player.currentItem else { return }
        let config = readConfiguration(); let time = player.currentTime(); let playing = player.rate > 0
        if previewMode.selectedSegment == 0 && !config.neutral {
            item.videoComposition = AVVideoComposition(asset: item.asset, applyingCIFiltersWithHandler: { request in
                request.finish(with: config.image(request.sourceImage).cropped(to: request.sourceImage.extent), context: nil)
            })
        } else { item.videoComposition = nil }
        playerView.videoGravity = config.fillScreen ? .resizeAspectFill : .resizeAspect
        if time.isValid && time.seconds.isFinite { player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { _ in if playing { self.player.play() } } }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { clips.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let duration = clips[row].info.duration
        let text = NSTextField(labelWithString: "\(row + 1). \(clips[row].url.lastPathComponent)  ·  \(Int(duration) / 60):\(String(format: "%02d", Int(duration) % 60))")
        text.lineBreakMode = .byTruncatingMiddle; text.toolTip = clips[row].url.path; return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, clips.indices.contains(table.selectedRow) else { return }
        previewGeneration += 1
        let item = AVPlayerItem(url: clips[table.selectedRow].url); player.replaceCurrentItem(with: item)
        player.pause(); rebuildPreview()
        player.seek(to: CMTime(seconds: 0.2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation: NSTableView.DropOperation) -> NSDragOperation { .copy }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        importVideos(urls); return !urls.isEmpty
    }
    @objc private func addVideos() {
        guard activeTask == nil, !importing else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.movie]
        panel.beginSheetModal(for: window) { [weak self] response in if response == .OK { self?.importVideos(panel.urls) } }
    }
    private func importVideos(_ urls: [URL], suggestName: Bool = true) {
        guard activeTask == nil, !importing else { return }
        let existing = Set(clips.map { $0.url.standardizedFileURL })
        let unique = Array(NSOrderedSet(array: urls.filter { $0.isFileURL && !existing.contains($0.standardizedFileURL) }).array as? [URL] ?? [])
        guard !unique.isEmpty else { return }
        importing = true; add.isEnabled = false; generate.isEnabled = false; status.stringValue = "正在读取视频…"
        Task.detached { [weak self] in
            var added = [Clip](); var failures = [String]()
            for url in unique {
                do { added.append(Clip(url: url, info: try await VideoInfo.read(url))) }
                catch { failures.append(error.localizedDescription) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let wasEmpty = self.clips.isEmpty
                self.clips.append(contentsOf: added); self.table.reloadData()
                if wasEmpty, !added.isEmpty {
                    if suggestName && self.nameField.stringValue == "我的壁纸" { self.nameField.stringValue = String(added[0].url.deletingPathExtension().lastPathComponent.prefix(60)) }
                    self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                }
                self.importing = false; self.add.isEnabled = true; self.generate.isEnabled = true
                self.status.stringValue = "\(self.clips.count) 段视频"
                if !failures.isEmpty { self.alert(failures.prefix(3).joined(separator: "\n")) }
            }
        }
    }
    @objc private func removeVideos() {
        guard activeTask == nil else { return }
        for index in table.selectedRowIndexes.reversed() { clips.remove(at: index) }
        table.reloadData(); player.replaceCurrentItem(with: nil)
        if !clips.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        if let posterURL, !clips.contains(where: { $0.url == posterURL }) { self.posterURL = nil; posterLabel.stringValue = "封面：默认使用首段视频" }
    }
    @objc private func moveUp() { move(-1) }
    @objc private func moveDown() { move(1) }
    private func move(_ direction: Int) {
        guard activeTask == nil, table.selectedRowIndexes.count == 1 else { return }
        let index = table.selectedRow, target = index + direction
        guard clips.indices.contains(target) else { return }
        clips.swapAt(index, target); table.reloadData(); table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
    }
    @objc private func selectPoster() {
        guard clips.indices.contains(table.selectedRow) else { return }
        guard player.currentItem?.status == .readyToPlay, player.currentTime().seconds.isFinite else { status.stringValue = "视频仍在准备，请稍后选封面"; return }
        posterURL = clips[table.selectedRow].url; posterTime = max(0, player.currentTime().seconds)
        posterLabel.stringValue = "封面：\(posterURL!.lastPathComponent)，\(String(format: "%.1f", posterTime)) 秒"
    }
    @objc private func chooseOutput() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.output = url; self?.outputLabel.stringValue = url.path; UserDefaults.standard.set(url.path, forKey: "outputFolder") }
        }
    }
    private func setBusy(_ value: Bool) {
        generate.isEnabled = !value; add.isEnabled = !value; cancel.isEnabled = value
        install.isEnabled = !value && result != nil; reveal.isEnabled = !value && result != nil
        nameField.isEnabled = !value; table.isEnabled = !value
        for slider in sliders.values { slider.isEnabled = !value }
        for control in [preset, fit, order] { control.isEnabled = !value }
        share.isEnabled = !value
    }
    @objc private func exportProject() {
        guard activeTask == nil, !importing else { return }
        do {
            let config = try readConfiguration().normalized()
            guard !clips.isEmpty else { throw MakerError.message("请先添加视频。") }
            configuration = config
            if let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: "desktopDefaults") }
            let request = BuildRequest(configuration: config, clips: clips.map(\.url), output: output, zip: share.state == .on,
                                       posterIndex: clips.firstIndex(where: { $0.url == posterURL }) ?? 0, posterTime: posterTime)
            setBusy(true); player.pause(); progress.doubleValue = 0
            activeTask = Task.detached { [weak self] in
                do {
                    let destination = try await Exporter.generate(request) { text, fraction in
                        DispatchQueue.main.async { self?.status.stringValue = text; self?.progress.doubleValue = fraction }
                    }
                    DispatchQueue.main.async {
                        guard let self else { return }; self.result = destination; self.activeTask = nil; self.setBusy(false)
                        self.status.stringValue = "已生成：\(destination.lastPathComponent)"; self.progress.doubleValue = 1
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard let self else { return }; self.activeTask = nil; self.setBusy(false)
                        self.status.stringValue = error is CancellationError ? "已取消" : "生成未完成"
                        if !(error is CancellationError) { self.alert(error.localizedDescription) }
                    }
                }
            }
        } catch { alert(error.localizedDescription) }
    }
    @objc private func cancelExport() { activeTask?.cancel(); status.stringValue = "正在取消…"; cancel.isEnabled = false }
    @objc private func revealResult() { if let result { NSWorkspace.shared.activateFileViewerSelecting([result]) } }
    @objc private func installProject() {
        guard let result, activeTask == nil else { return }; setBusy(true); status.stringValue = "正在安装…"
        activeTask = Task.detached { [weak self] in
            do {
                _ = try await Exporter.command("/bin/zsh", [result.appendingPathComponent("安装.command").path], environment: ["VIDEO_WALLPAPER_NO_OPEN": "1"])
                DispatchQueue.main.async {
                    guard let self else { return }; self.activeTask = nil; self.setBusy(false); self.status.stringValue = "已安装，请在墙纸设置中选择名称"
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
                }
            } catch { DispatchQueue.main.async { self?.activeTask = nil; self?.setBusy(false); self?.alert(error.localizedDescription) } }
        }
    }
    @objc private func newProject() {
        guard activeTask == nil, !importing else { return }; clips = []; table.reloadData(); player.replaceCurrentItem(with: nil)
        posterURL = nil; posterTime = 0.7; result = nil; apply(WallpaperConfiguration()); status.stringValue = "选择或拖入视频"; setBusy(false)
    }
    @objc private func openProject() {
        guard activeTask == nil, !importing else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                let document = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: url))
                let request = try document.request(relativeTo: url.deletingLastPathComponent(), output: self.output, zip: true)
                self.clips = []; self.table.reloadData(); self.player.replaceCurrentItem(with: nil)
                self.apply(request.configuration); self.posterURL = request.clips.indices.contains(request.posterIndex) ? request.clips[request.posterIndex] : nil
                self.posterTime = request.posterTime; self.posterLabel.stringValue = "封面：沿用作品设置"
                self.importVideos(request.clips, suggestName: false)
            } catch { self.alert(error.localizedDescription) }
        }
    }
    @objc private func openHelp() { if let url = Bundle.main.url(forResource: "使用说明", withExtension: "txt") { NSWorkspace.shared.open(url) } }
    private func alert(_ message: String) { let alert = NSAlert(); alert.messageText = "壁纸制作器"; alert.informativeText = message; alert.addButton(withTitle: "好"); alert.beginSheetModal(for: window) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if activeTask != nil { cancelExport(); return false }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if activeTask != nil {
            activeTask?.cancel(); status.stringValue = "正在取消生成，请稍后再退出"; return .terminateCancel
        }
        return .terminateNow
    }
}
