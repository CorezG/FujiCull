import AppKit
import FujiCullCore
import SwiftUI

struct ContentView: View {
    @Bindable var model: CullModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .start:
                StartView(model: model)
            case .scanning(let name):
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Reading \(name)…").foregroundStyle(.secondary)
                }
            case .browsing:
                BrowseView(model: model)
            case .failed(let message):
                VStack(spacing: 14) {
                    Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("OK") { model.dismissFailure() }.keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: 420)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .preferredColorScheme(.dark)
    }
}

/// Lists detected camera cards; anything else opens through Open Folder (R1).
struct StartView: View {
    let model: CullModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.detectedCards.isEmpty ? "Insert a card" : "Card detected")
                    .font(.system(size: 26, weight: .semibold))
                Text("Nothing on the card changes until you press Apply.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.detectedCards, id: \.self) { card in
                HStack(spacing: 16) {
                    Image(systemName: "sdcard").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(CullModel.displayName(of: card)).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Open") { Task { await model.open(card) } }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(16)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            }
            Button("Open Folder…") { OpenPanel.chooseFolder(for: model) }
        }
        .frame(width: 480)
    }
}

/// The photo with a small overlay: filename and position (T6; counts and EXIF arrive in T8 and T13).
struct BrowseView: View {
    let model: CullModel

    var body: some View {
        ZStack(alignment: .bottom) {
            ViewerRepresentable(image: model.currentImage, onKey: handle)
            if let frame = model.currentFrame {
                HStack {
                    Text(Self.filename(of: frame)).font(.system(size: 12, design: .monospaced))
                    if frame.isUnpaired {
                        Text(frame.jpg == nil ? "RAF only" : "JPG only")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.yellow)
                    }
                    Spacer()
                    Text("\(model.cursor + 1) / \(model.frames.count)")
                        .font(.system(size: 12, design: .monospaced)).monospacedDigit()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .padding(14)
            } else {
                Text("No photos found in \(model.sourceName).").foregroundStyle(.secondary).padding(40)
            }
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123:
            model.move(by: -1)
            return true
        case 124:
            model.move(by: 1)
            return true
        default:
            return false
        }
    }

    static func filename(of frame: Frame) -> String {
        let path = frame.jpg?.relativePath ?? frame.raf?.relativePath ?? frame.id.rawValue
        return (path as NSString).lastPathComponent
    }
}

enum OpenPanel {
    @MainActor static func chooseFolder(for model: CullModel) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a card or a folder of photos"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.open(url) }
    }
}
