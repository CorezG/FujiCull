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
                Button("Close Card") { model.close() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(model.phase != .browsing)
            }
        }
    }
}
