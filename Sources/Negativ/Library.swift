import Foundation
import AppKit
import UniformTypeIdentifiers
import Combine

/// One editable frame: a scan file, or a virtual copy of it (for scans holding several frames).
struct FrameRef: Hashable, Identifiable {
    let url: URL
    /// 0 is the scan itself; 1, 2… are virtual copies sharing the file.
    let copy: Int

    init(url: URL, copy: Int = 0) {
        self.url = url
        self.copy = copy
    }

    var id: String { key }
    /// Sidecar key: the file name, plus "#n" for copies.
    var key: String { copy == 0 ? url.lastPathComponent : "\(url.lastPathComponent)#\(copy + 1)" }
    var stem: String { url.deletingPathExtension().lastPathComponent }
    var displayName: String { copy == 0 ? stem : "\(stem) (\(copy + 1))" }
    var exportStem: String { copy == 0 ? stem : "\(stem)-\(copy + 1)" }
}

/// One folder of scans plus its edit sidecar (`.negativ.json`).
final class RollStore: ObservableObject {
    let folder: URL
    @Published private(set) var files: [URL] = []
    @Published private(set) var frames: [FrameRef] = []
    @Published private(set) var settings: [String: EditSettings] = [:]
    /// Called on the main queue when a frame's default settings were filled in by film-type detection.
    var onDefaultsDetected: ((FrameRef, EditSettings) -> Void)?
    private var saveWork: DispatchWorkItem?
    private var detecting = false

    var name: String { folder.lastPathComponent }
    private var sidecar: URL { folder.appendingPathComponent(".negativ.json") }

    init(folder: URL) {
        self.folder = folder
        if let data = try? Data(contentsOf: sidecar),
           let s = try? JSONDecoder().decode([String: EditSettings].self, from: data) {
            settings = s
        }
        reload()
    }

    func reload() {
        let list = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        files = list.filter(Pipeline.isSupported)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        rebuildFrames()
    }

    private func rebuildFrames() {
        frames = files.flatMap { url -> [FrameRef] in
            let name = url.lastPathComponent
            let copies = settings.keys.compactMap { k -> Int? in
                guard k.hasPrefix(name + "#"), let n = Int(k.dropFirst(name.count + 1)), n >= 2 else { return nil }
                return n - 1
            }
            return [FrameRef(url: url)] + copies.sorted().map { FrameRef(url: url, copy: $0) }
        }
    }

    func hasSettings(_ f: FrameRef) -> Bool { settings[f.key] != nil }

    func settings(for f: FrameRef) -> EditSettings {
        settings[f.key] ?? EditSettings()
    }

    func set(_ s: EditSettings, for f: FrameRef) {
        settings[f.key] = s
        scheduleSave()
    }

    /// Adds a virtual copy of `f` with the given settings and returns it.
    @discardableResult
    func addCopy(of f: FrameRef, settings s: EditSettings) -> FrameRef {
        let n = (frames.filter { $0.url == f.url }.map(\.copy).max() ?? 0) + 1
        let copy = FrameRef(url: f.url, copy: n)
        settings[copy.key] = s
        rebuildFrames()
        scheduleSave()
        return copy
    }

    func removeCopy(_ f: FrameRef) {
        guard f.copy > 0 else { return }
        settings[f.key] = nil
        rebuildFrames()
        scheduleSave()
    }

    /// Fills in B&W mode for scans that have never been edited and hold B&W film, in the
    /// background, in roll order.
    func detectDefaults(queue: OperationQueue) {
        guard !detecting else { return }
        detecting = true
        let todo = files.map { FrameRef(url: $0) }.filter { !hasSettings($0) }
        let group = DispatchGroup()
        for f in todo {
            group.enter()
            queue.addOperation {
                defer { group.leave() }
                guard let lin = Pipeline.loadPreview(f.url, settings: EditSettings(), maxDim: 600),
                      Processor.looksMonochrome(lin) else { return }
                DispatchQueue.main.async {
                    guard !self.hasSettings(f) else { return }
                    let s = EditSettings(mode: .bwNegative)
                    self.set(s, for: f)
                    self.onDefaultsDetected?(f, s)
                }
            }
        }
        group.notify(queue: .main) { self.detecting = false }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(settings) { try? data.write(to: sidecar, options: .atomic) }
    }
}

struct CardRef: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var libraryRoot: URL
    @Published private(set) var rolls: [URL] = []
    @Published private(set) var cards: [CardRef] = []
    @Published var selectedRoll: URL? {
        didSet { if selectedRoll != oldValue { openRoll() } }
    }
    @Published private(set) var roll: RollStore?
    @Published var current: FrameRef? {
        didSet { if current != oldValue { openCurrent() } }
    }
    @Published var selection: Set<FrameRef> = []
    @Published var importSource: CardRef?
    @Published var showExport = false
    @Published var clipboard: EditSettings?

    @Published private(set) var autoCropping = 0

    let editor = EditorModel()
    private var observers: [Any] = []
    private let background: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .userInitiated
        return q
    }()

    private static let rootKey = "libraryRoot"
    private static let extraKey = "extraRolls"

    init() {
        if let p = UserDefaults.standard.string(forKey: Self.rootKey) {
            libraryRoot = URL(fileURLWithPath: p)
        } else {
            libraryRoot = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Negativ")
        }
        try? FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        editor.onChange = { [weak self] frame, s in self?.roll?.set(s, for: frame) }
        refreshRolls()
        refreshCards()
        selectedRoll = rolls.first

        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            self.refreshCards()
            // A freshly inserted card opens the import sheet straight away.
            if let vol = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
               let card = self.cards.first(where: { $0.url.standardizedFileURL == vol.standardizedFileURL }),
               self.importSource == nil, !self.showExport {
                self.importSource = card
            }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshCards()
        })
        installKeyMonitor()
    }

    // MARK: Library

    var extraRolls: [URL] {
        (UserDefaults.standard.stringArray(forKey: Self.extraKey) ?? []).map { URL(fileURLWithPath: $0) }
    }

    func refreshRolls() {
        let subs = (try? FileManager.default.contentsOfDirectory(at: libraryRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let dirs = subs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
        rolls = (dirs + extraRolls.filter { FileManager.default.fileExists(atPath: $0.path) && !dirs.contains($0) })
            .map(\.standardizedFileURL)
    }

    func refreshCards() {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        cards = vols.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("DCIM").path) }.map(CardRef.init)
    }

    func chooseLibraryRoot() {
        guard let url = pickFolder(prompt: "Use as Library") else { return }
        libraryRoot = url
        UserDefaults.standard.set(url.path, forKey: Self.rootKey)
        refreshRolls()
        selectedRoll = rolls.first
    }

    /// Open… : image files or folders.
    func openFiles() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.image, .rawImage, .folder]
        p.prompt = "Open"
        if p.runModal() == .OK { open(p.urls) }
    }

    /// Opens files or folders (from Open…, drag and drop, Finder or the Dock). A folder becomes a
    /// roll; a file opens in its folder's roll with that frame selected.
    func open(_ urls: [URL]) {
        var folder: URL?
        var files: [URL] = []
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir {
                folder = url
            } else if Pipeline.isSupported(url) {
                files.append(url)
                folder = folder ?? url.deletingLastPathComponent()
            }
        }
        guard let folder else { return }
        addRoll(folder)
        selectedRoll = folder.standardizedFileURL
        guard let roll, !files.isEmpty else { return }
        let wanted = Set(files.map { $0.standardizedFileURL.path })
        let frames = roll.frames.filter { wanted.contains($0.url.standardizedFileURL.path) }
        if let first = frames.first {
            current = first
            selection = Set(frames)
        }
    }

    /// Lists a folder as a roll (library subfolders already are).
    private func addRoll(_ url: URL) {
        let dir = url.standardizedFileURL
        guard dir.deletingLastPathComponent() != libraryRoot.standardizedFileURL else { refreshRolls(); return }
        var extra = UserDefaults.standard.stringArray(forKey: Self.extraKey) ?? []
        if !extra.contains(dir.path) { extra.append(dir.path) }
        UserDefaults.standard.set(extra, forKey: Self.extraKey)
        refreshRolls()
    }

    func removeFromList(_ url: URL) {
        var extra = UserDefaults.standard.stringArray(forKey: Self.extraKey) ?? []
        extra.removeAll { $0 == url.path }
        UserDefaults.standard.set(extra, forKey: Self.extraKey)
        refreshRolls()
        if selectedRoll == url { selectedRoll = rolls.first }
    }

    func importFromFolder() {
        guard let url = pickFolder(prompt: "Import") else { return }
        importSource = CardRef(url: url)
    }

    func pickFolder(prompt: String) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = prompt
        return p.runModal() == .OK ? p.url : nil
    }

    private func openRoll() {
        roll?.save()
        guard let selectedRoll else {
            roll = nil
            current = nil
            return
        }
        let r = RollStore(folder: selectedRoll)
        // Film-type detection finishing for the open frame, before the user touched it.
        r.onDefaultsDetected = { [weak self] frame, s in
            guard let self, self.current == frame, self.editor.settings == EditSettings() else { return }
            self.editor.replaceSettings(s, record: false)
        }
        roll = r
        selection = []
        current = r.frames.first
        if let c = current { selection = [c] }
        r.detectDefaults(queue: background)
    }

    private func openCurrent() {
        guard let roll, let current else {
            editor.open(nil, settings: EditSettings())
            return
        }
        editor.open(current, settings: roll.settings(for: current))
    }

    // MARK: Frames

    func select(_ frame: FrameRef, command: Bool, shift: Bool) {
        guard let roll else { return }
        if shift, let cur = current, let a = roll.frames.firstIndex(of: cur), let b = roll.frames.firstIndex(of: frame) {
            selection.formUnion(roll.frames[min(a, b)...max(a, b)])
            current = frame
        } else if command {
            if selection.contains(frame), selection.count > 1 {
                selection.remove(frame)
                if current == frame { current = selection.first }
            } else {
                selection.insert(frame)
                current = frame
            }
        } else {
            selection = [frame]
            current = frame
        }
    }

    func selectAll() {
        guard let roll else { return }
        selection = Set(roll.frames)
    }

    func step(_ delta: Int) {
        guard let roll, let cur = current, let i = roll.frames.firstIndex(of: cur) else { return }
        let j = i + delta
        guard roll.frames.indices.contains(j) else { return }
        select(roll.frames[j], command: false, shift: false)
    }

    /// Auto-crops (and straightens) the current frame, and every other selected frame in the background.
    func autoCropSelection() {
        guard let roll else { return }
        if current != nil { editor.autoCrop() }
        var misses = 0
        for frame in selection where frame != current {
            let s = roll.settings(for: frame)
            autoCropping += 1
            background.addOperation {
                let result = Pipeline.decodePreview(frame.url, maxDim: 1200).flatMap { AutoCrop.run(source: $0, settings: s) }
                DispatchQueue.main.async {
                    self.autoCropping -= 1
                    guard self.roll === roll else { return }
                    if let result {
                        self.applyToOther(frame, in: roll) { old in
                            var ns = old
                            ns.straighten = result.straighten
                            ns.crop = result.crop
                            return ns
                        }
                    } else {
                        misses += 1
                    }
                    if self.autoCropping == 0, misses > 0 {
                        self.editor.flash("No frame edge found in \(misses) of the selected frames")
                    }
                }
            }
        }
    }

    /// Finds every frame in the current scan; the first keeps this frame, the rest become virtual copies.
    func splitCurrentIntoFrames() {
        guard let roll, let cur = current else { return }
        editor.detectAllFrames { rects in
            guard self.roll === roll, self.current == cur else { return }
            guard let first = rects.first else {
                self.editor.flash("No frames found")
                return
            }
            var s = self.editor.settings
            s.crop = first
            self.editor.settings = s
            var created: [FrameRef] = [cur]
            for r in rects.dropFirst() {
                var c = s
                c.crop = r
                created.append(roll.addCopy(of: cur, settings: c))
            }
            self.selection = Set(created)
            self.editor.flash(rects.count == 1 ? "Found one frame" : "Split into \(rects.count) frames")
        }
    }

    func duplicateCurrent() {
        guard let roll, let cur = current else { return }
        let copy = roll.addCopy(of: cur, settings: editor.settings)
        select(copy, command: false, shift: false)
    }

    /// Removes a virtual copy (the scan file itself is never touched).
    func removeCopy(_ frame: FrameRef) {
        guard let roll, frame.copy > 0 else { return }
        let i = roll.frames.firstIndex(of: frame) ?? 0
        roll.removeCopy(frame)
        selection.remove(frame)
        if current == frame {
            current = roll.frames.indices.contains(i - 1) ? roll.frames[i - 1] : roll.frames.first
            if let c = current { selection = [c] }
        }
    }

    func copySettings() { clipboard = editor.settings }

    /// Applies the clipboard's adjustments (not geometry) to every selected frame.
    func pasteSettings() {
        guard let clipboard else { return }
        apply(to: selection.isEmpty ? Set([current].compactMap { $0 }) : selection) { $0.pastingAdjustments(from: clipboard) }
    }

    /// Copies the current frame's adjustments to the rest of the selection.
    func syncToSelection() {
        let src = editor.settings
        apply(to: selection) { $0.pastingAdjustments(from: src) }
    }

    /// Copies the current frame's adjustments to every frame of the roll.
    func syncToRoll() {
        guard let roll else { return }
        let src = editor.settings
        apply(to: Set(roll.frames)) { $0.pastingAdjustments(from: src) }
        editor.flash("Applied to all \(roll.frames.count) frames")
    }

    /// Locks the current frame's measured colour balance and levels, and applies them to the selection.
    func lockBalanceToSelection() {
        guard let lv = editor.currentLevels else { return }
        let a = lv.array
        apply(to: selection.union([current].compactMap { $0 })) { var s = $0; s.fixedLevels = a; return s }
    }

    func unlockBalance() {
        apply(to: selection.union([current].compactMap { $0 })) { var s = $0; s.fixedLevels = nil; return s }
    }

    func resetCurrent() {
        guard current != nil else { return }
        // The film type is a fact about the film, not an edit.
        editor.settings = EditSettings(mode: editor.settings.mode)
    }

    private func apply(to frames: Set<FrameRef>, _ f: (EditSettings) -> EditSettings) {
        guard let roll else { return }
        for frame in frames {
            if frame == current {
                editor.replaceSettings(f(editor.settings), record: true)
            } else {
                applyToOther(frame, in: roll, f)
            }
        }
    }

    /// Changes a frame that isn't open, keeping an undo step for when it is.
    private func applyToOther(_ frame: FrameRef, in roll: RollStore, _ f: (EditSettings) -> EditSettings) {
        let old = roll.settings(for: frame)
        let new = f(old)
        guard new != old else { return }
        editor.recordHistory(old, for: frame, coalesce: false)
        roll.set(new, for: frame)
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            if NSApp.keyWindow?.firstResponder is NSText { return e }
            if self.importSource != nil || self.showExport { return e }
            let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
            if mods == .command, e.charactersIgnoringModifiers?.lowercased() == "a" {
                self.selectAll()
                return nil
            }
            if !mods.intersection([.command, .control, .option]).isEmpty { return e }
            let ed = self.editor
            switch e.keyCode {
            case 123: self.step(-1); return nil          // ←
            case 124: self.step(1); return nil           // →
            case 48:                                     // tab / shift-tab
                self.step(mods.contains(.shift) ? -1 : 1)
                return nil
            case 36, 76, 53:                             // return, enter, escape
                if ed.tool != .none { ed.tool = .none; return nil }
                return e
            default: break
            }
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "c": ed.tool = ed.tool == .crop ? .none : .crop
            case "b": ed.tool = ed.tool == .pickBase ? .none : .pickBase
            case "w": ed.tool = ed.tool == .pickNeutral ? .none : .pickNeutral
            case "n": ed.showNegative.toggle()
            case "a": self.autoCropSelection()
            case "r": ed.resetCrop()
            case "i": ed.toggleInversion()
            default: return e
            }
            return nil
        }
    }
}
