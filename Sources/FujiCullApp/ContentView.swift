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
            case .resumePrompt(let matched, let expected):
                ResumePrompt(model: model, matched: matched, expected: expected)
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

/// The photo with the overlay from R16: filename, decision, ♥, position and counts.
struct BrowseView: View {
    let model: CullModel

    var body: some View {
        if model.isGrid {
            grid
        } else {
            single
        }
    }

    /// Grid view (R15): the same keys act on the selected cell, which is the cursor.
    private var grid: some View {
        VStack(spacing: 0) {
            FilmstripView(
                model: model, style: .grid, onKey: handle, session: model.session,
                thumbnailRevision: model.thumbnailRevision)
            if let frame = model.currentFrame {
                StatusBar(
                    frame: frame, mark: model.currentMark, counts: model.session.counts, position: model.position,
                    exif: model.showsExif ? model.currentExif.map(ExifLine.parts) : nil
                )
                .padding(10)
            }
        }
    }

    private var single: some View {
        VStack(spacing: 0) {
            viewer
            if !model.frames.isEmpty {
                FilmstripView(model: model, session: model.session, thumbnailRevision: model.thumbnailRevision)
                    .frame(height: FilmstripView.stripHeight)
            }
        }
    }

    private var viewer: some View {
        ZStack(alignment: .bottom) {
            ViewerRepresentable(
                image: model.currentImage, zoomImage: model.zoomImage, zoomScale: model.zoomScale,
                pixelSize: model.currentPixelSize, onZoom: { model.setZoom($0) },
                onImageShown: { model.imageShown() }, onKeyUp: { model.keyReleased() },
                dimmed: model.currentMark.decision == .reject, onKey: handle)
            if let frame = model.currentFrame {
                StatusBar(
                    frame: frame, mark: model.currentMark, counts: model.session.counts, position: model.position,
                    zoom: model.zoomScale.map { "\(Int(($0 * 100).rounded()))%" + (model.zoomImage == nil ? "…" : "") },
                    exif: model.showsExif ? model.currentExif.map(ExifLine.parts) : nil
                )
                .padding(14)
            } else if model.session.undecidedOnly && !model.frames.isEmpty {
                EmptyFilterMessage()
            } else {
                Text("No photos found in \(model.sourceName).").foregroundStyle(.secondary).padding(40)
            }
            if model.session.undecidedOnly, model.currentFrame != nil {
                Text("Showing undecided only, \(model.position.count) left")
                    .font(.system(size: 12)).foregroundStyle(Color(red: 0.62, green: 0.8, blue: 1))
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 12)
            }
            DecisionFlash(flash: model.flash)
            if model.showsTimings {
                Text(model.timingText.isEmpty ? "Timings: move to another photo" : model.timingText)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        let press = KeyPress(
            keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "",
            shift: flags.contains(.shift), command: flags.contains(.command), control: flags.contains(.control),
            option: flags.contains(.option))
        guard let action = KeyMap.action(for: press) else { return false }
        if action == .fitToWindow, !model.canPerform(action) { return false }
        model.perform(action)
        return true
    }
}

private struct StatusBar: View {
    let frame: Frame
    let mark: FrameMark
    let counts: CullCounts
    let position: (index: Int, count: Int)
    /// The zoom level while zoomed, e.g. "100%", with "…" while the full-resolution image loads.
    var zoom: String?
    /// The EXIF line (R17), shown while I is on.
    var exif: [String]?

    var body: some View {
        HStack(spacing: 10) {
            Text(BrowseView.filename(of: frame)).font(.system(size: 12, design: .monospaced))
            DecisionChip(mark: mark)
            if let zoom { Text(zoom).foregroundStyle(Color.accentColor) }
            if frame.isUnpaired {
                Text(frame.jpg == nil ? "RAF only" : "JPG only")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.yellow)
            }
            Spacer()
            if let exif {
                HStack(spacing: 14) { ForEach(exif, id: \.self) { Text($0) } }
                    .foregroundStyle(Color(white: 0.85))
                Spacer()
            }
            Text("\(counts.keep) kept").foregroundStyle(Color(red: 0.19, green: 0.82, blue: 0.35))
            Text("\(counts.reject) rejected").foregroundStyle(Color(red: 1, green: 0.27, blue: 0.23))
            Text("\(counts.undecided) undecided").foregroundStyle(.secondary)
            Text("\(position.index) / \(position.count)").padding(.leading, 6)
        }
        .font(.system(size: 12, design: .monospaced))
        .monospacedDigit()
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DecisionChip: View {
    let mark: FrameMark

    var body: some View {
        let (label, colour): (String, Color) =
            switch mark.decision {
            case .keep: ("Keep", Color(red: 0.19, green: 0.82, blue: 0.35))
            case .reject: ("Reject", Color(red: 1, green: 0.27, blue: 0.23))
            case .undecided: ("Undecided", Color(white: 0.78))
            }
        HStack(spacing: 4) {
            if mark.isFavourite { Text("♥").foregroundStyle(Color(red: 1, green: 0.22, blue: 0.37)) }
            Text(label)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(colour)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(colour.opacity(0.16), in: Capsule())
    }
}

/// A brief ✓ / ✕ / ♥ after a decision, so a keypress is acknowledged even before the next frame loads.
private struct DecisionFlash: View {
    let flash: (symbol: String, id: Int)?
    @State private var visible = false

    var body: some View {
        Text(flash?.symbol ?? "")
            .font(.system(size: 46, weight: .medium))
            .foregroundStyle(colour)
            .frame(width: 92, height: 92)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 22))
            .opacity(visible ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .onChange(of: flash?.id) {
                visible = true
                withAnimation(.easeOut(duration: 0.4).delay(0.08)) { visible = false }
            }
    }

    private var colour: Color {
        switch flash?.symbol {
        case "✓": Color(red: 0.19, green: 0.82, blue: 0.35)
        case "✕": Color(red: 1, green: 0.27, blue: 0.23)
        default: Color(red: 1, green: 0.22, blue: 0.37)
        }
    }
}

private struct EmptyFilterMessage: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("Every frame has a decision").font(.system(size: 16, weight: .semibold))
            Text("Press ' to show all frames again.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension BrowseView {
    static func filename(of frame: Frame) -> String {
        let path = frame.jpg?.relativePath ?? frame.raf?.relativePath ?? frame.id.rawValue
        return (path as NSString).lastPathComponent
    }
}

/// Shown when only part of the saved session still matches the card (SR4).
struct ResumePrompt: View {
    let model: CullModel
    let matched: Int
    let expected: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("This card has changed since your last session").font(.system(size: 18, weight: .semibold))
            Text(
                "\(matched.formatted()) of \(expected.formatted()) decisions from your last session on \(model.sourceName) still match the photos on the card. The others belong to photos that have been deleted or replaced."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Start Fresh") { Task { await model.startFresh() } }
                Spacer()
                Button("Resume") { model.resumeSession() }.keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 460)
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
