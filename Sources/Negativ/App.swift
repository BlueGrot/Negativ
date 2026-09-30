import SwiftUI
import AppKit

@main
struct NegativApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var app = AppModel.shared

    init() {
        // Headless tools:
        //   Negativ --render <file> <out-folder> [tiff] [--autocrop]   export with the roll's settings
        //   Negativ --detect <files…>   detected frame rect and tilt per file
        //   Negativ --split <files…>    every frame found per file
        let a = CommandLine.arguments
        func fmt(_ r: NormRect) -> String { String(format: "%.4f %.4f %.4f %.4f", r.x, r.y, r.w, r.h) }
        if let i = a.firstIndex(of: "--detect") {
            for path in a[(i + 1)...] {
                let url = URL(fileURLWithPath: path)
                let d = Pipeline.loadPreview(url, settings: EditSettings(), maxDim: 1200).flatMap(FrameDetector.detect)
                print(url.lastPathComponent, d.map { fmt($0.rect) + String(format: " tilt %+.2f", $0.tilt) } ?? "none")
            }
            exit(0)
        }
        if let i = a.firstIndex(of: "--split") {
            for path in a[(i + 1)...] {
                let url = URL(fileURLWithPath: path)
                let rects = Pipeline.loadPreview(url, settings: EditSettings(), maxDim: 1200).map(FrameDetector.detectAll) ?? []
                print(url.lastPathComponent, rects.isEmpty ? "none" : rects.map(fmt).joined(separator: " | "))
            }
            exit(0)
        }
        if let i = a.firstIndex(of: "--render"), a.count > i + 2 {
            let input = URL(fileURLWithPath: a[i + 1])
            let format: ExportOptions.Format = a.contains("tiff") ? .tiff16 : .jpeg
            let opts = ExportOptions(format: format, dest: URL(fileURLWithPath: a[i + 2]))
            var settings = RollStore(folder: input.deletingLastPathComponent()).settings(for: FrameRef(url: input))
            if a.contains("--autocrop"), let src = Pipeline.decodePreview(input, maxDim: 1200),
               let r = AutoCrop.run(source: src, settings: settings) {
                settings.straighten = r.straighten
                settings.crop = r.crop
            }
            do {
                print(try Exporter.export(input, settings: settings, options: opts).path)
                exit(0)
            } catch {
                FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
                exit(1)
            }
        }
    }

    var body: some Scene {
        Window("Negativ", id: "main") {
            ContentView()
                .environmentObject(app)
                .environmentObject(app.editor)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1060, minHeight: 680)
        }
        .commands { NegativCommands(app: app) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    /// Finder "Open With", or files dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.open(urls)
    }
    func applicationWillTerminate(_ notification: Notification) { AppModel.shared.roll?.save() }
}

struct NegativCommands: Commands {
    @ObservedObject var app: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Import from Folder…") { app.importFromFolder() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Open…") { app.openFiles() }
                .keyboardShortcut("o")
            Divider()
            Button("Choose Library Folder…") { app.chooseLibraryRoot() }
            Divider()
            Button("Export…") { app.showExport = true }
                .keyboardShortcut("e")
                .disabled(app.roll == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                if let text = NSApp.keyWindow?.firstResponder as? NSText { text.undoManager?.undo() } else { app.editor.undo() }
            }
            .keyboardShortcut("z")
            Button("Redo") {
                if let text = NSApp.keyWindow?.firstResponder as? NSText { text.undoManager?.redo() } else { app.editor.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Button("Select All Frames  (⌘A)") { app.selectAll() }
        }
        CommandMenu("Frame") {
            Button("Rotate Left") { app.editor.rotate(clockwise: false) }.keyboardShortcut("[")
            Button("Rotate Right") { app.editor.rotate(clockwise: true) }.keyboardShortcut("]")
            Button("Flip Horizontal") { app.editor.flip() }.keyboardShortcut("f", modifiers: [.command, .option])
            Divider()
            Button("Crop  (C)") { app.editor.tool = app.editor.tool == .crop ? .none : .crop }
            Button("Reset Crop  (R)") { app.editor.resetCrop() }
            Button("Auto Crop and Straighten  (A)") { app.autoCropSelection() }
            Button("Split into Frames") { app.splitCurrentIntoFrames() }.keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Duplicate as Virtual Copy") { app.duplicateCurrent() }.keyboardShortcut("d")
            Button("Remove Virtual Copy") { if let c = app.current { app.removeCopy(c) } }
                .disabled((app.current?.copy ?? 0) == 0)
            Button("Pick Film Base  (B)") { app.editor.tool = .pickBase }
            Button("Pick Neutral  (W)") { app.editor.tool = .pickNeutral }
            Button("Show Negative  (N)") { app.editor.showNegative.toggle() }
            Button("Invert: Negative / Positive  (I)") { app.editor.toggleInversion() }
            Divider()
            Button("Copy Settings") { app.copySettings() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Paste Settings") { app.pasteSettings() }.keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(app.clipboard == nil)
            Button("Sync Settings to Selection") { app.syncToSelection() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Sync Settings to Whole Roll") { app.syncToRoll() }
            Button("Lock Colour Balance for Selection") { app.lockBalanceToSelection() }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Unlock Colour Balance") { app.unlockBalance() }
            Button("Reset Frame") { app.resetCurrent() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Previous Frame  (← or ⇧Tab)") { app.step(-1) }
            Button("Next Frame  (→ or Tab)") { app.step(1) }
        }
    }
}
