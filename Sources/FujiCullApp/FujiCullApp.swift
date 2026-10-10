import FujiCullCore
import SwiftUI

@main
struct FujiCullApp: App {
    @State private var model = CullModel()

    var body: some Scene {
        // One window, one source at a time (DESIGN §5.5). Dark so the photo is the brightest thing on screen (R18).
        Window("FujiCull", id: "main") {
            ContentView(model: model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { OpenPanel.chooseFolder(for: model) }
                    .keyboardShortcut("o")
                Button("Apply…") { model.beginApply() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!model.canApply)
                Button("Close Card") { model.close() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(model.phase != .browsing)
            }
            CommandGroup(replacing: .undoRedo) {
                item("Undo Decision", .cull(.undo), "z", [.command])
            }
            // Every key is also a menu item, so the shortcuts can be discovered (R13).
            CommandMenu("Cull") {
                item("Keep", .cull(.keep), .upArrow)
                item("Reject", .cull(.reject), .downArrow)
                item("Toggle Favourite", .cull(.toggleFavourite), "/")
                item("Reset to Undecided", .cull(.reset), ".")
                Divider()
                item("Undo Last Decision", .cull(.undo), .delete)
                Divider()
                item("Show Only Undecided", .cull(.toggleUndecidedFilter), "\'")
            }
            CommandGroup(before: .toolbar) {
                item("Previous Frame", .cull(.previous), .leftArrow)
                item("Next Frame", .cull(.next), .rightArrow)
                item("Back 10 Frames", .cull(.jump(-10)), .leftArrow, [.shift])
                item("Forward 10 Frames", .cull(.jump(10)), .rightArrow, [.shift])
                Divider()
                item("Zoom to 100%", .toggleZoom, .return)
                item("Fit to Window", .fitToWindow, .escape)
                item("Grid", .toggleGrid, "g")
                item("Show EXIF", .toggleExif, "i")
                Button(model.showsTimings ? "Hide Timings" : "Show Timings") { model.toggleTimings() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Divider()
            }
        }
    }

    private func item(
        _ title: String, _ action: KeyAction, _ key: KeyEquivalent, _ modifiers: EventModifiers = []
    ) -> some View {
        Button(title) { model.perform(action) }
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(!model.canPerform(action))
    }
}
