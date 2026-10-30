// iHypnusCare: native Mac front end for tools/hypnus_report.py.
// Welcome screen -> pick or drop a card -> progress while the reader runs -> report shown in a web view.
// Build with tools/app/build_app.sh (bundles the Python reader, template and images in Resources/tools).
import Cocoa
import UniformTypeIdentifiers
import WebKit

let brand = NSColor(srgbRed: 0.0, green: 0.624, blue: 0.890, alpha: 1)
let ink = NSColor(srgbRed: 0.043, green: 0.043, blue: 0.043, alpha: 1)
let ink2 = NSColor(srgbRed: 0.322, green: 0.318, blue: 0.306, alpha: 1)
let pageBG = NSColor(srgbRed: 0.976, green: 0.976, blue: 0.969, alpha: 1)
let toolsDir = Bundle.main.resourceURL!.appendingPathComponent("tools")
let lastFolderKey = "lastFolder"

func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = ink) -> NSTextField {
    let l = NSTextField(wrappingLabelWithString: text)
    l.font = .systemFont(ofSize: size, weight: weight)
    l.textColor = color
    l.alignment = .center
    l.isSelectable = false
    return l
}

// MARK: - Background view that accepts a dropped folder

final class DropView: NSView {
    var onDrop: ((URL) -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func folder(from info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let url = urls?.first else { return nil }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : nil
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onDrop != nil, folder(from: sender) != nil else { return [] }
        highlighted = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        guard let url = folder(from: sender) else { return false }
        onDrop?(url)
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        pageBG.setFill()
        bounds.fill()
        if highlighted {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 14, dy: 14), xRadius: 16, yRadius: 16)
            path.lineWidth = 3
            path.setLineDash([10, 6], count: 2, phase: 0)
            brand.setStroke()
            path.stroke()
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, NSToolbarDelegate {
    var window: NSWindow!
    var webView: WKWebView?
    var process: Process?
    var progressBar: NSProgressIndicator!
    var counterLabel: NSTextField!
    var detailLabel: NSTextField!
    var currentFolder: URL?
    var reportShown = false

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "iHypnusCare"
        window.minSize = NSSize(width: 860, height: 620)
        window.backgroundColor = pageBG
        window.appearance = NSAppearance(named: .aqua)   // the app is light mode only
        window.setFrameAutosaveName("iHypnusCareMain")
        if !window.setFrameUsingName("iHypnusCareMain") { window.center() }
        let toolbar = NSToolbar(identifier: "main")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        showWelcome()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Folders dropped on the Dock icon or opened with "Open With"
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { DispatchQueue.main.async { self.startReading(url) } }
    }

    // MARK: Menu

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About iHypnusCare", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide iHypnusCare", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit iHypnusCare", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open SD Card or Folder…", action: #selector(openFolder), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Export PDF…", action: #selector(exportPDF), keyEquivalent: "e")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let winItem = NSMenuItem(); main.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = winMenu
        NSApp.windowsMenu = winMenu
        NSApp.mainMenu = main
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(exportPDF) { return reportShown }
        if item.action == #selector(openFolder) { return process == nil }
        return true
    }

    // MARK: Toolbar

    let openID = NSToolbarItem.Identifier("open"), exportID = NSToolbarItem.Identifier("export")

    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { [openID, .flexibleSpace, exportID] }
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { [openID, .flexibleSpace, exportID] }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id == openID {
            item.label = "Open…"
            item.toolTip = "Open another SD card or folder"
            item.image = NSImage(systemSymbolName: "sdcard", accessibilityDescription: "Open")
            item.action = #selector(openFolder)
        } else {
            item.label = "Export PDF"
            item.toolTip = "Save the report for the selected dates as a PDF"
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export PDF")
            item.action = #selector(exportPDF)
        }
        item.target = self
        item.isBordered = true
        return item
    }
    @objc func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        item.itemIdentifier == exportID ? reportShown : process == nil
    }

    // MARK: Screens

    func showWelcome() {
        reportShown = false
        webView = nil
        window.title = "iHypnusCare"
        let root = DropView(frame: .zero)
        root.onDrop = { [weak self] url in self?.startReading(url) }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let logo = NSImage(contentsOf: toolsDir.appendingPathComponent("assets/hypnus-logo.png")) {
            let iv = NSImageView(image: logo)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.heightAnchor.constraint(equalToConstant: 64).isActive = true
            iv.widthAnchor.constraint(equalToConstant: 64 * logo.size.width / max(1, logo.size.height)).isActive = true
            stack.addArrangedSubview(iv)
        }
        let title = label("iHypnusCare", size: 30, weight: .semibold)
        stack.addArrangedSubview(title)
        let sub = label("Turn the SD card from your Hypnus CPAP machine into a clear therapy report.", size: 15, color: ink2)
        sub.preferredMaxLayoutWidth = 520
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(26, after: sub)

        let features = NSStackView()
        features.orientation = .vertical
        features.alignment = .leading
        features.spacing = 12
        for (symbol, text) in [
            ("chart.bar.xaxis", "Usage, AHI, pressure and leak trends for any date range"),
            ("moon.zzz", "Night-by-night detail showing every apnea and hypopnea"),
            ("list.bullet.rectangle", "The compliance and therapy figures a sleep doctor looks for"),
            ("doc.richtext", "Export a PDF to share with your doctor"),
            ("lock.shield", "Read-only: nothing on your SD card is ever changed"),
        ] {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 12
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 17, weight: .regular)
            icon.contentTintColor = brand
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
            let t = label(text, size: 14)
            t.alignment = .left
            row.addArrangedSubview(icon)
            row.addArrangedSubview(t)
            features.addArrangedSubview(row)
        }
        stack.addArrangedSubview(features)
        stack.setCustomSpacing(30, after: features)

        let button = NSButton(title: "Open SD Card or Folder…", target: self, action: #selector(openFolder))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 15, weight: .semibold)
        button.bezelColor = brand
        button.keyEquivalent = "\r"
        stack.addArrangedSubview(button)

        let hint = label("or drag the card or a folder onto this window", size: 12.5, color: ink2)
        stack.addArrangedSubview(hint)

        if let last = UserDefaults.standard.url(forKey: lastFolderKey), FileManager.default.fileExists(atPath: last.path) {
            let again = NSButton(title: "Open last folder: \(last.lastPathComponent)", target: self, action: #selector(openLast))
            again.isBordered = false
            again.contentTintColor = brand
            again.font = .systemFont(ofSize: 13)
            stack.setCustomSpacing(18, after: hint)
            stack.addArrangedSubview(again)
        }

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -10),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
        ])
        window.contentView = root
        window.toolbar?.validateVisibleItems()
    }

    func showLoading(_ folder: URL) {
        let root = DropView(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let logo = NSImage(contentsOf: toolsDir.appendingPathComponent("assets/hypnus-logo.png")) {
            let iv = NSImageView(image: logo)
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.heightAnchor.constraint(equalToConstant: 44).isActive = true
            iv.widthAnchor.constraint(equalToConstant: 44 * logo.size.width / max(1, logo.size.height)).isActive = true
            stack.addArrangedSubview(iv)
            stack.setCustomSpacing(22, after: iv)
        }
        stack.addArrangedSubview(label("Reading your SD card…", size: 22, weight: .semibold))
        let path = label((folder.path as NSString).abbreviatingWithTildeInPath, size: 12.5, color: ink2)
        path.preferredMaxLayoutWidth = 520
        stack.addArrangedSubview(path)
        stack.setCustomSpacing(22, after: path)

        progressBar = NSProgressIndicator()
        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.widthAnchor.constraint(equalToConstant: 460).isActive = true
        progressBar.startAnimation(nil)
        stack.addArrangedSubview(progressBar)

        counterLabel = label("Starting…", size: 14, weight: .medium)
        counterLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        stack.addArrangedSubview(counterLabel)
        detailLabel = label(" ", size: 12.5, color: ink2)
        stack.addArrangedSubview(detailLabel)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelReading))
        cancel.bezelStyle = .rounded
        stack.setCustomSpacing(22, after: detailLabel)
        stack.addArrangedSubview(cancel)

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -10),
        ])
        window.contentView = root
        window.toolbar?.validateVisibleItems()
    }

    func showReport(_ html: URL, folder: URL) {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "cpap")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        wv.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        webView = wv
        window.contentView = wv
        window.title = "iHypnusCare — \(folder.lastPathComponent)"
        reportShown = true
        window.toolbar?.validateVisibleItems()
    }

    // MARK: Actions

    @objc func openFolder() {
        guard process == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Read Card"
        panel.message = "Choose your Hypnus SD card, or a folder that holds a copy of it."
        if let last = UserDefaults.standard.url(forKey: lastFolderKey) { panel.directoryURL = last.deletingLastPathComponent() }
        else { panel.directoryURL = URL(fileURLWithPath: "/Volumes") }
        panel.beginSheetModal(for: window) { [weak self] resp in
            if resp == .OK, let url = panel.url { self?.startReading(url) }
        }
    }

    @objc func openLast() {
        if let last = UserDefaults.standard.url(forKey: lastFolderKey) { startReading(last) }
    }

    @objc func exportPDF() {
        webView?.evaluateJavaScript("window.cpapExportPdf && window.cpapExportPdf()", completionHandler: nil)
    }

    @objc func cancelReading() {
        process?.terminate()
    }

    func startReading(_ folder: URL) {
        guard process == nil else { return }
        currentFolder = folder
        showLoading(folder)

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("local.ihypnuscare")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let out = cacheDir.appendingPathComponent("report.html")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", toolsDir.appendingPathComponent("hypnus_report.py").path, folder.path, "--html", out.path, "--progress"]
        let stdout = Pipe(), stderr = Pipe()
        p.standardOutput = stdout
        p.standardError = stderr

        var buffer = Data()
        var errData = Data()
        let errLock = NSLock()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            buffer.append(h.availableData)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let done = obj["done"] as? Int, let total = obj["total"] as? Int else { continue }
                let files = obj["files"] as? Int ?? 0
                let name = obj["folder"] as? String ?? ""
                DispatchQueue.main.async { self?.updateProgress(done: done, total: total, files: files, folder: name) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { h in
            errLock.lock(); errData.append(h.availableData); errLock.unlock()
        }
        p.terminationHandler = { [weak self] proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            errLock.lock(); let err = String(data: errData, encoding: .utf8) ?? ""; errLock.unlock()
            DispatchQueue.main.async { self?.finished(proc, output: out, error: err) }
        }
        do {
            try p.run()
            process = p
        } catch {
            fail("Couldn't start Python (/usr/bin/python3). Install Apple's Command Line Tools with: xcode-select --install\n\n\(error.localizedDescription)")
        }
    }

    func updateProgress(done: Int, total: Int, files: Int, folder: String) {
        guard progressBar != nil else { return }
        if progressBar.isIndeterminate {
            progressBar.isIndeterminate = false
            progressBar.stopAnimation(nil)
        }
        progressBar.maxValue = Double(total)
        progressBar.doubleValue = Double(done)
        let nf = NumberFormatter(); nf.numberStyle = .decimal
        counterLabel.stringValue = "Folder \(nf.string(from: done as NSNumber)!) of \(nf.string(from: total as NSNumber)!)  ·  \(nf.string(from: files as NSNumber)!) files read"
        if done >= total {
            detailLabel.stringValue = "Building the report…"
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
        } else if folder.count == 8, let d = DateFormatter.cardFolder.date(from: folder) {
            detailLabel.stringValue = "Reading \(DateFormatter.longDay.string(from: d))"
        } else {
            detailLabel.stringValue = folder
        }
    }

    func finished(_ p: Process, output: URL, error: String) {
        process = nil
        if p.terminationReason == .uncaughtSignal {   // cancelled
            showWelcome(); return
        }
        if p.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path), let folder = currentFolder {
            UserDefaults.standard.set(folder, forKey: lastFolderKey)
            showReport(output, folder: folder)
        } else {
            let msg = error.trimmingCharacters(in: .whitespacesAndNewlines)
            fail(msg.isEmpty ? "The reader stopped with code \(p.terminationStatus)." : String(msg.suffix(1200)))
        }
    }

    func fail(_ message: String) {
        process = nil
        let alert = NSAlert()
        alert.messageText = "Couldn't read that folder"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] _ in self?.showWelcome() }
    }

    // MARK: PDF from the page

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], body["type"] as? String == "pdf",
              let b64 = body["data"] as? String, let data = Data(base64Encoded: b64) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = body["name"] as? String ?? "CPAP report.pdf"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
                let js = "document.querySelector('#pdfStatus').textContent = " + Self.jsString("Saved \(url.lastPathComponent)")
                self?.webView?.evaluateJavaScript(js, completionHandler: nil)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
    }
}

extension DateFormatter {
    static let cardFolder: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()
    static let longDay: DateFormatter = { let f = DateFormatter(); f.dateStyle = .long; return f }()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
