import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            if let roll = app.roll {
                RollView(roll: roll)
            } else {
                EmptyLibraryView()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            let group = DispatchGroup()
            var urls: [URL] = []
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { urls.append(url) } }
                    group.leave()
                }
            }
            group.notify(queue: .main) { app.open(urls) }
            return true
        }
        .sheet(item: $app.importSource) { src in
            ImportSheet(source: src)
        }
        .sheet(isPresented: $app.showExport) {
            if let roll = app.roll { ExportSheet(roll: roll) }
        }
    }
}

struct EmptyLibraryView: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("No rolls yet").font(.title2)
            Text("Insert a memory card with your scans, or import from a folder.").foregroundStyle(.secondary)
            HStack {
                ForEach(app.cards) { card in
                    Button("Import from \(card.name)") { app.importSource = card }
                }
                Button("Import from Folder…") { app.importFromFolder() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SidebarView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        List(selection: $app.selectedRoll) {
            Section("Memory cards") {
                if app.cards.isEmpty {
                    Text("No card inserted").foregroundStyle(.tertiary)
                }
                ForEach(app.cards) { card in
                    HStack {
                        Label(card.name, systemImage: "sdcard")
                        Spacer()
                        Button("Import") { app.importSource = card }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("Rolls") {
                ForEach(app.rolls, id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: "film")
                        .tag(url)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            if app.extraRolls.contains(url) {
                                Button("Remove from List") { app.removeFromList(url) }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Menu {
                    Button("Import from Folder…") { app.importFromFolder() }
                    Button("Open…") { app.openFiles() }
                    Divider()
                    Button("Refresh") { app.refreshRolls(); app.refreshCards() }
                    Button("Choose Library Folder…") { app.chooseLibraryRoot() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Text(app.libraryRoot.lastPathComponent).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(10)
        }
    }
}

struct RollView: View {
    @ObservedObject var roll: RollStore
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var editor: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                EditorCanvas()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                InspectorView()
                    .frame(width: 290)
            }
            Divider()
            FilmstripView(roll: roll)
                .frame(height: 128)
        }
        .navigationTitle(roll.name)
        .navigationSubtitle(app.current.map { "\($0.displayName) · \(roll.frames.count) frames" } ?? "\(roll.frames.count) frames")
        .toolbar {
            ToolbarItemGroup {
                Button { editor.rotate(clockwise: false) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                    .help("Rotate left (⌘[)")
                Button { editor.rotate(clockwise: true) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                    .help("Rotate right (⌘])")
                Button { editor.flip() } label: { Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .help("Flip horizontally (⌥⌘F)")
                Toggle(isOn: Binding(get: { editor.tool == .crop }, set: { editor.tool = $0 ? .crop : .none })) {
                    Label("Crop", systemImage: "crop")
                }
                .help("Crop (C)")
                Toggle(isOn: $editor.showNegative) {
                    Label("Negative", systemImage: "circle.lefthalf.filled")
                }
                .help("Show the unprocessed negative (N)")
            }
            ToolbarItem {
                Button { app.showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export (⌘E)")
            }
        }
    }
}

struct FilmstripView: View {
    @ObservedObject var roll: RollStore
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var editor: EditorModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(Array(roll.frames.enumerated()), id: \.element) { i, frame in
                        let settings = roll.settings(for: frame)
                        let live = editor.thumbnail.flatMap { $0.key == frame.key && $0.settings == settings ? $0.image : nil }
                        FrameCell(frame: frame, index: i + 1, settings: settings, live: live,
                                  isCurrent: app.current == frame, isSelected: app.selection.contains(frame))
                            .id(frame)
                            .onTapGesture {
                                let f = NSEvent.modifierFlags
                                app.select(frame, command: f.contains(.command), shift: f.contains(.shift))
                            }
                            .contextMenu {
                                Button("Duplicate as Virtual Copy") {
                                    app.select(frame, command: false, shift: false)
                                    app.duplicateCurrent()
                                }
                                Button("Split into Frames") {
                                    app.select(frame, command: false, shift: false)
                                    app.splitCurrentIntoFrames()
                                }
                                if frame.copy > 0 {
                                    Button("Remove Virtual Copy") { app.removeCopy(frame) }
                                }
                                Divider()
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([frame.url]) }
                            }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(Color(white: 0.07))
            .onChange(of: app.current) { _, cur in
                if let cur { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(cur, anchor: .center) } }
            }
            .overlay {
                if roll.frames.isEmpty {
                    Text("This roll has no images").foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct FrameCell: View {
    let frame: FrameRef
    let index: Int
    let settings: EditSettings
    /// The editor's current rendering of this frame, when it's the one being edited.
    let live: CGImage?
    let isCurrent: Bool
    let isSelected: Bool
    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Color(white: 0.13)
                if let img = live ?? image {
                    Image(decorative: img, scale: 1).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if frame.copy > 0 {
                    Image(systemName: "square.on.square")
                        .font(.system(size: 9))
                        .padding(3)
                        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                        .padding(3)
                        .help("Virtual copy")
                }
            }
            .frame(width: 130, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isCurrent ? Color.accentColor : (isSelected ? Color.accentColor.opacity(0.5) : .clear), lineWidth: 2)
            )
            Text("\(index)  \(frame.displayName)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: 130)
        }
        .contentShape(Rectangle())
        .task(id: settings) {
            if let exact = ThumbCache.shared.rendered(for: frame.key, settings: settings) {
                image = exact
                return
            }
            // Debounce while sliders are moving.
            if image != nil { try? await Task.sleep(nanoseconds: 400_000_000) }
            guard !Task.isCancelled else { return }
            let img = await ThumbCache.shared.thumbnail(frame.url, settings: settings)
            if !Task.isCancelled, let img { image = img }
        }
    }
}
