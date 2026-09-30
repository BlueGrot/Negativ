import SwiftUI
import AppKit

struct ImportSheet: View {
    let source: CardRef
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var files: [SourceFile] = []
    @State private var picked: Set<URL> = []
    @State private var scanning = true
    @State private var rollName = ""
    @State private var eject = false
    @State private var copied: Int?
    @State private var error: String?
    /// Files already in the library (matched by name and size).
    @State private var imported: Set<URL> = []

    private var isCard: Bool { app.cards.contains(source) }
    private var pickedFiles: [SourceFile] { files.filter { picked.contains($0.url) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: isCard ? "sdcard" : "folder")
                Text("Import from \(source.name)").font(.headline)
                Spacer()
                if !files.isEmpty {
                    Text("\(picked.count) of \(files.count) · \(ByteCountFormatter.string(fromByteCount: pickedFiles.reduce(0) { $0 + $1.size }, countStyle: .file))"
                         + (imported.isEmpty ? "" : " · \(imported.count) already imported"))
                        .foregroundStyle(.secondary)
                    Button("All") { picked = Set(files.map(\.url)) }
                    if !imported.isEmpty {
                        Button("New") { picked = Set(files.map(\.url)).subtracting(imported) }
                    }
                    Button("None") { picked = [] }
                }
            }
            .padding()
            Divider()
            ZStack {
                if scanning {
                    ProgressView("Reading card…")
                } else if files.isEmpty {
                    Text("No supported images found").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                            ForEach(files) { f in
                                ImportCell(file: f, picked: picked.contains(f.url), alreadyImported: imported.contains(f.url))
                                    .onTapGesture {
                                        if picked.contains(f.url) { picked.remove(f.url) } else { picked.insert(f.url) }
                                    }
                            }
                        }
                        .padding()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.08))
            Divider()
            HStack(spacing: 12) {
                TextField("Roll name", text: $rollName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                Text("→ \(app.libraryRoot.lastPathComponent)").foregroundStyle(.secondary)
                if isCard { Toggle("Eject when done", isOn: $eject) }
                Spacer()
                if let copied {
                    ProgressView(value: Double(copied), total: Double(max(1, picked.count))).frame(width: 140)
                }
                if let error { Text(error).foregroundStyle(.red).lineLimit(1) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(copied != nil)
                Button("Import \(picked.count)") { startImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty || rollName.trimmingCharacters(in: .whitespaces).isEmpty || copied != nil)
            }
            .padding()
        }
        .frame(width: 900, height: 620)
        .task {
            rollName = defaultRollName()
            let root = source.url
            let rolls = app.rolls
            let (found, dupes) = await Task.detached { () -> ([SourceFile], Set<URL>) in
                let found = CardScanner.scan(root)
                return (found, CardScanner.alreadyImported(found, rolls: rolls))
            }.value
            files = found
            imported = dupes
            // Only what's new is selected; re-inserting a card doesn't offer everything again.
            picked = Set(found.map(\.url)).subtracting(dupes)
            scanning = false
        }
    }

    private func defaultRollName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let base = "\(f.string(from: Date())) Roll"
        var name = base
        var n = 2
        while FileManager.default.fileExists(atPath: app.libraryRoot.appendingPathComponent(name).path) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    private func startImport() {
        let name = rollName.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        let dest = app.libraryRoot.appendingPathComponent(name)
        let todo = pickedFiles
        let volume = source.url
        let shouldEject = eject && isCard
        copied = 0
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try CardScanner.copy(todo, to: dest) { n in copied = n }
                DispatchQueue.main.async {
                    app.refreshRolls()
                    app.selectedRoll = dest
                    dismiss()
                    if shouldEject {
                        do {
                            try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                        } catch {
                            app.editor.flash("Imported, but the card could not be ejected: \(error.localizedDescription)")
                        }
                    }
                }
            } catch let e {
                DispatchQueue.main.async {
                    error = e.localizedDescription
                    copied = nil
                }
            }
        }
    }
}

struct ImportCell: View {
    let file: SourceFile
    let picked: Bool
    let alreadyImported: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Color(white: 0.14)
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                }
                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(picked ? Color.accentColor : .white.opacity(0.6))
                    .padding(5)
            }
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .opacity(picked ? 1 : 0.45)
            HStack(spacing: 4) {
                Text(file.url.lastPathComponent).lineLimit(1)
                if alreadyImported {
                    Text("Imported").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .contentShape(Rectangle())
        .task {
            // Auto-inverted so the frames are recognisable before importing.
            image = await ThumbCache.shared.thumbnail(file.url, settings: EditSettings(), maxDim: 300, accurate: false)
        }
    }
}

struct ExportSheet: View {
    @ObservedObject var roll: RollStore
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportOptions.Format = .jpeg
    @State private var quality = 0.92
    @State private var size = 0
    @State private var onlySelected = true
    @State private var dest: URL?
    @State private var done: Int?
    @State private var errors: [String] = []
    @State private var finished = false
    @State private var stop = StopFlag()

    private let sizes = [0, 6000, 4000, 2048]
    private var frames: [FrameRef] {
        onlySelected ? roll.frames.filter { app.selection.contains($0) } : roll.frames
    }
    private var destination: URL { dest ?? roll.folder.appendingPathComponent("Exports") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.title2.bold())
            Form {
                Picker("Frames", selection: $onlySelected) {
                    Text("Selected (\(app.selection.count))").tag(true)
                    Text("Whole roll (\(roll.frames.count))").tag(false)
                }
                Picker("Format", selection: $format) {
                    ForEach(ExportOptions.Format.allCases) { Text($0.rawValue).tag($0) }
                }
                if format == .jpeg {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $quality, in: 0.5...1)
                            Text("\(Int(quality * 100))").monospacedDigit().frame(width: 30)
                        }
                    }
                }
                Picker("Long edge", selection: $size) {
                    Text("Full resolution").tag(0)
                    ForEach(sizes.dropFirst(), id: \.self) { Text("\($0) px").tag($0) }
                }
                LabeledContent("Folder") {
                    HStack {
                        Text(destination.path(percentEncoded: false))
                            .lineLimit(1).truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { if let u = app.pickFolder(prompt: "Export Here") { dest = u } }
                    }
                }
            }
            if let done {
                ProgressView(value: Double(done), total: Double(max(1, frames.count))) {
                    Text(finished ? "Exported \(done - errors.count) of \(frames.count)" + (stop.value ? " (stopped)" : "")
                                  : "Exporting \(done + 1) of \(frames.count)…")
                }
            }
            ForEach(errors, id: \.self) { Text($0).foregroundStyle(.red).font(.caption) }
            HStack {
                if finished {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
                }
                Spacer()
                if done != nil && !finished {
                    Button("Stop") { stop.value = true }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button(finished ? "Close" : "Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                if !finished {
                    Button("Export \(frames.count)") { run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(frames.isEmpty || done != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { onlySelected = app.selection.count > 1 }
    }

    private func run() {
        let list = frames
        let settings = list.map { $0 == app.current ? app.editor.settings : roll.settings(for: $0) }
        let stop = self.stop
        let opts = ExportOptions(format: format, quality: quality, longEdge: size == 0 ? nil : size, dest: destination)
        done = 0
        errors = []
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(at: opts.dest, withIntermediateDirectories: true)
            for (i, frame) in list.enumerated() {
                if stop.value { break }
                var err: String?
                autoreleasepool {
                    do { _ = try Exporter.export(frame.url, name: frame.exportStem, settings: settings[i], options: opts) }
                    catch let e { err = "\(frame.displayName): \(e.localizedDescription)" }
                }
                DispatchQueue.main.async {
                    if let err { errors.append(err) }
                    done = i + 1
                }
            }
            DispatchQueue.main.async { finished = true }
        }
    }
}

/// Lets the export loop on a background queue see the Stop button.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
