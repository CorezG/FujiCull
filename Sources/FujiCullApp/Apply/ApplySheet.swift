import FujiCullCore
import SwiftUI

/// The Apply sheet: where to archive, what will happen, progress, the delete confirmation, and what was
/// done (REQUIREMENTS §4.6). One screen per stage of `ApplyModel`.
struct ApplySheet: View {
    @Bindable var model: ApplyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.stage {
            case .setup: SetupView(model: model)
            case .checking: Waiting(text: "Reading \(model.cardName) and the archive…")
            case .preflight(let preflight): PreflightView(model: model, preflight: preflight)
            case .copying: CopyingView(model: model)
            case .confirming(let report, let confirmation):
                ConfirmView(model: model, report: report, confirmation: confirmation)
            case .removing: Waiting(text: "Finishing…")
            case .summary(let summary): SummaryView(model: model, summary: summary)
            case .failed(let message): FailedView(model: model, message: message)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private func bytes(_ count: Int64) -> String { count.formatted(.byteCount(style: .file)) }

private func plural(_ count: Int, _ one: String, _ many: String) -> String {
    "\(count.formatted()) \(count == 1 ? one : many)"
}

private struct Title: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 20, weight: .semibold)).padding(.bottom, 14) }
}

private struct Waiting: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 90)
    }
}

/// One line of a summary: a figure, what it is, and what happens to it.
private struct Row: View {
    let figure: String
    let label: String
    var detail: String?
    var colour: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(figure).font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(colour)
                .frame(width: 64, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

private struct Note: View {
    let symbol: String
    let text: String
    var colour: Color = .yellow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(colour)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(colour.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 8)
    }
}

/// A list that stays short until opened, for file names.
private struct FileList: View {
    let title: String
    let names: [String]

    var body: some View {
        DisclosureGroup(title) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(names, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
        }
        .font(.system(size: 12))
        .padding(.top, 6)
    }
}

// MARK: Where

private struct SetupView: View {
    @Bindable var model: ApplyModel

    var body: some View {
        Title(text: "Apply")
        Text(
            "Keepers are copied to the archive and checked. Only then are rejects deleted from \(model.cardName), after you confirm."
        )
        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 16)

        Text("Archive drive").font(.system(size: 12, weight: .semibold))
        if model.volumes.isEmpty {
            Note(
                symbol: "externaldrive.badge.xmark",
                text: "No archive drive is connected. Plug it in, then press Refresh.")
            Button("Refresh") { model.refreshVolumes() }.padding(.top, 8)
        } else {
            Picker("", selection: $model.archiveUUID) {
                ForEach(model.volumes) { volume in
                    Text("\(volume.name)  (\(bytes(volume.freeBytes)) free)").tag(Optional(volume.uuid))
                }
            }
            .labelsHidden()
        }

        Text("Trip name").font(.system(size: 12, weight: .semibold)).padding(.top, 14)
        TextField("Japan 2026", text: $model.tripName)
            .textFieldStyle(.roundedBorder)
            .onSubmit { if model.canReview { Task { await model.review() } } }
        if let problem = model.tripNameProblem {
            Text(problem).font(.system(size: 12)).foregroundStyle(.red).padding(.top, 2)
        } else if let archive = model.archive, !model.tripName.isEmpty {
            Text("Photos go to \(archive.name) › \(model.tripName)").font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.top, 2)
        }

        HStack {
            Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
            Spacer()
            Button("Review") { Task { await model.review() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canReview)
        }
        .padding(.top, 22)
    }
}

// MARK: What will happen

private struct PreflightView: View {
    @Bindable var model: ApplyModel
    let preflight: ApplyRun.Preflight

    private var plan: ApplyPlan { preflight.plan }
    private var nothingToDo: Bool {
        plan.copies.isEmpty && plan.tagChanges.isEmpty && plan.removals.isEmpty && plan.cardDeletes.isEmpty
    }

    var body: some View {
        Title(text: "\(model.cardName) → \(model.archive?.name ?? "archive") › \(model.tripName)")

        Row(
            figure: preflight.keepers.formatted(),
            label: "to keep" + (preflight.favourites > 0 ? " (\(preflight.favourites) ♥)" : ""),
            detail: copyLine, colour: Color(red: 0.19, green: 0.82, blue: 0.35))
        if preflight.toEdit > 0 {
            Row(
                figure: preflight.toEdit.formatted(), label: "of them flagged for editing",
                detail: "Their RAW files go to RAW › Edit Me. Their JPGs are archived but left out of Google Photos.",
                colour: .orange)
        }
        if preflight.videos > 0 {
            Row(
                figure: preflight.videos.formatted(), label: "videos to copy",
                detail: "Copied to Videos. Never deleted from the card.")
        }
        Row(
            figure: preflight.rejects.formatted(), label: "to reject", detail: rejectLine,
            colour: Color(red: 1, green: 0.27, blue: 0.23))
        if !plan.removals.isEmpty {
            Row(
                figure: plan.removals.flatMap(\.files).count.formatted(),
                label: "archive files of frames you've since rejected",
                detail: "Moved to the archive drive's Trash, after you confirm.")
        }
        Row(
            figure: preflight.undecided.formatted(), label: "undecided",
            detail: "Left on the card, untouched and not archived.")

        if preflight.undecided > 0 || !plan.leftOnCard.otherFiles.isEmpty {
            Note(symbol: "exclamationmark.triangle.fill", text: leftOnCardWarning)
        }
        if !plan.leftOnCard.otherFiles.isEmpty {
            FileList(
                title: "Other files left on the card (\(plan.leftOnCard.otherFiles.count))",
                names: plan.leftOnCard.otherFiles)
        }
        if plan.notDeleted.contains(where: { $0.reason == .cardLocked }) {
            Note(
                symbol: "lock.fill",
                text: "\(model.cardName) is locked, so nothing will be deleted from it. Keepers are still copied.")
        }
        let undated = plan.notDeleted.count { $0.reason == .noCaptureDate }
        if undated > 0 {
            Note(
                symbol: "calendar.badge.exclamationmark",
                text:
                    "\(plural(undated, "reject has", "rejects have")) no capture date and won't be deleted. Delete them yourself if you want them gone."
            )
        }
        if !plan.unreachableDestinations.isEmpty {
            Note(
                symbol: "externaldrive.badge.questionmark",
                text:
                    "Keepers from an earlier run are in “\(plan.unreachableDestinations.map(\.folder).joined(separator: "”, “"))”, which can't be found. Nothing will be deleted from the card until it can be checked."
            )
        }
        if !plan.superseded.isEmpty {
            Note(
                symbol: "doc.on.doc",
                text:
                    "\(plural(plan.superseded.count, "file", "files")) will be copied again under a new name, because the original name is taken. The earlier copies stay where they are.",
                colour: .blue)
        }
        if !preflight.recovery.adopted.isEmpty || !preflight.recovery.released.isEmpty {
            Note(
                symbol: "arrow.clockwise",
                text:
                    "An earlier run was interrupted. FujiCull has tidied up after it and will carry on from where it stopped.",
                colour: .blue)
        }
        if !preflight.recovery.strayPartials.isEmpty {
            Toggle(
                "Remove \(plural(preflight.recovery.strayPartials.count, "leftover partial file", "leftover partial files")) from an earlier run",
                isOn: $model.removeLeftovers
            )
            .font(.system(size: 12)).padding(.top, 8)
        }
        if plan.destinationState == .existsNotOurs {
            Toggle("“\(model.tripName)” already exists on the archive. Add to it.", isOn: $model.addToExistingFolder)
                .font(.system(size: 12)).padding(.top, 8)
        }

        HStack {
            Button("Back") { model.back() }.keyboardShortcut(.cancelAction)
            Spacer()
            if nothingToDo {
                Text("Nothing to do.").foregroundStyle(.secondary)
                Button("Close") { model.close() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Start") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStart(preflight))
            }
        }
        .padding(.top, 22)
    }

    private var copyLine: String {
        let photos = plan.copies.count { $0.role != .video }
        if photos == 0 { return "Already on the archive." }
        let folder = plan.destinationState == .new ? "a new folder" : "the existing folder"
        return
            "\(plural(photos, "file", "files")) to copy (\(bytes(plan.copies.filter { $0.role != .video }.reduce(0) { $0 + $1.size }))) into \(folder), then checked."
    }

    private var rejectLine: String {
        if preflight.rejects == 0 { return "Nothing to delete." }
        let files = plan.cardDeletes.flatMap(\.paths)
        if files.isEmpty { return "Not deleted in this run." }
        let size = bytes(model.bytes(of: files))
        return plan.deleteMode == .permanent
            ? "\(plural(files.count, "file", "files")) (\(size)) deleted from the card once every keeper is checked, after you confirm."
            : "\(plural(files.count, "file", "files")) (\(size)) moved to the Trash once every keeper is checked, after you confirm."
    }

    private var leftOnCardWarning: String {
        var parts: [String] = []
        if preflight.undecided > 0 { parts.append(plural(preflight.undecided, "undecided frame", "undecided frames")) }
        if !plan.leftOnCard.otherFiles.isEmpty {
            parts.append(plural(plan.leftOnCard.otherFiles.count, "other file", "other files"))
        }
        let heif = plan.leftOnCard.otherFiles.contains {
            $0.lowercased().hasSuffix(".hif") || $0.lowercased().hasSuffix(".heic")
        }
        return
            "\(parts.joined(separator: " and ")) will stay on the card and won't be archived. Formatting the card loses them."
            + (heif ? " This includes HEIF photos, which FujiCull doesn't cull." : "")
    }
}

// MARK: Copying

private struct CopyingView: View {
    let model: ApplyModel

    var body: some View {
        Title(text: "Copying to \(model.archive?.name ?? "the archive")")
        ProgressView(value: Double(model.bytesDone), total: Double(max(model.bytesTotal, 1)))
        HStack {
            Text("\(bytes(model.bytesDone)) of \(bytes(model.bytesTotal))")
            Spacer()
            Text(remaining)
        }
        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 6)
        Text(
            "Each file is read back from the drive and compared before it counts. Nothing is deleted during this step. Keep both drives connected."
        )
        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(
            .top, 14)
        HStack {
            Spacer()
            Button("Cancel") { model.cancelCopy() }.keyboardShortcut(.cancelAction)
        }
        .padding(.top, 18)
    }

    private var remaining: String {
        guard let started = model.copyStarted, model.bytesDone > 0, model.bytesTotal > model.bytesDone else {
            return ""
        }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed > 2 else { return "" }
        let seconds = elapsed / Double(model.bytesDone) * Double(model.bytesTotal - model.bytesDone)
        if seconds < 60 { return "less than a minute left" }
        return "about \(Int((seconds / 60).rounded(.up))) min left"
    }
}

// MARK: Confirm (R22, R26)

private struct ConfirmView: View {
    let model: ApplyModel
    let report: ApplyRun.CopyReport
    let confirmation: ApplyExecutor.Confirmation

    var body: some View {
        Title(text: "Every keeper is on the archive")
        Text(
            "\(plural(report.check.keepersOnArchive, "keeper", "keepers")) checked on \(model.archive?.name ?? "the archive") just now."
        )
        .foregroundStyle(.secondary).padding(.bottom, 14)

        if !confirmation.toDelete.isEmpty {
            Text(deleteQuestion).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if confirmation.deleteMode == .permanent {
                Text("This cannot be undone.").foregroundStyle(.red).padding(.top, 2)
            }
            FileList(title: "Files to delete from the card", names: confirmation.toDelete)
        }
        if !confirmation.toTrash.isEmpty {
            Text(
                "Move \(plural(confirmation.toTrash.count, "archive file", "archive files")) of frames you rejected after archiving to \(model.archive?.name ?? "the archive")'s Trash?"
            )
            .font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            FileList(
                title: "Archive files to move to the Trash",
                names: confirmation.toTrash.map { ($0.subfolder.map { "\($0)/" } ?? "") + $0.name })
        }

        HStack {
            // The destructive button has no shortcut: Return and Esc both keep everything.
            Button(
                confirmation.deleteMode == .permanent || confirmation.toDelete.isEmpty ? "Delete" : "Move to Trash",
                role: .destructive
            ) {
                Task { await model.finish(confirmed: true) }
            }
            Spacer()
            Button("Keep Everything") { Task { await model.finish(confirmed: false) } }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 22)
    }

    private var deleteQuestion: String {
        let files = confirmation.toDelete
        let frames = Set(files.map { $0.split(separator: ".").dropLast().joined(separator: ".") }).count
        let verb = confirmation.deleteMode == .permanent ? "Delete" : "Move"
        let place = confirmation.deleteMode == .permanent ? "from \(model.cardName)" : "to the Trash"
        return
            "\(verb) \(plural(frames, "rejected frame", "rejected frames")) (\(plural(files.count, "file", "files")), \(bytes(model.bytes(of: files)))) \(place)?"
    }
}

// MARK: What happened

private struct SummaryView: View {
    let model: ApplyModel
    let summary: ApplySummary
    @State private var ejectMessage: String?

    var body: some View {
        Title(text: headline)

        Row(
            figure: summary.keepersOnArchive.formatted(), label: "keepers on the archive, checked just now",
            detail: summary.copiedFiles > 0
                ? "\(plural(summary.copiedFiles, "file", "files")) copied in this run (\(bytes(summary.copiedBytes)))."
                : "Nothing new needed copying.",
            colour: Color(red: 0.19, green: 0.82, blue: 0.35))
        Row(
            figure: summary.deletedFromCard.count.formatted(), label: "files deleted from the card",
            detail: deletedDetail,
            colour: summary.deletedFromCard.isEmpty ? .secondary : Color(red: 1, green: 0.27, blue: 0.23))
        if !summary.trashed.isEmpty {
            Row(figure: summary.trashed.count.formatted(), label: "archive files moved to the archive drive's Trash")
        }
        Row(
            figure: summary.leftOnCard.undecided.count.formatted(), label: "undecided frames left on the card",
            detail: summary.leftOnCard.otherFiles.isEmpty
                ? nil
                : "Plus \(plural(summary.leftOnCard.otherFiles.count, "other file", "other files")), not archived.")

        if let stopped = summary.stopped {
            Note(
                symbol: "exclamationmark.octagon.fill",
                text: ApplyModel.describe(stopped, card: model.cardName, archive: model.archive?.name ?? "the archive")
                    + " Run Apply again to carry on.", colour: .red)
        }
        if !summary.gateBlockers.isEmpty {
            Note(
                symbol: "hand.raised.fill",
                text:
                    "Nothing was deleted, because not every keeper could be confirmed on the archive (\(plural(summary.gateBlockers.count, "problem", "problems")))."
            )
        }
        if !summary.problems.isEmpty {
            FileList(
                title: "Keepers not confirmed on the archive (\(summary.problems.count))",
                names: summary.problems.map(Self.describe))
        }
        if !summary.skippedRemovals.isEmpty {
            FileList(
                title: "Rejects skipped (\(summary.skippedRemovals.count))",
                names: summary.skippedRemovals.map(Self.describe))
        }
        if !summary.duplicatesLeft.isEmpty {
            FileList(
                title: "Earlier copies left in place (\(summary.duplicatesLeft.count))",
                names: summary.duplicatesLeft.map(\.name))
        }
        if !summary.tagFailures.isEmpty {
            Note(
                symbol: "tag.slash",
                text:
                    "\(plural(summary.tagFailures.count, "Favourite tag", "Favourite tags")) couldn't be set. The next Apply will try again."
            )
        }
        if summary.leftOnCard.undecided.count > 0 || !summary.leftOnCard.otherFiles.isEmpty {
            Note(
                symbol: "exclamationmark.triangle.fill",
                text: "Some photos are still only on the card. Formatting it loses them.")
        }
        if let ejectMessage { Note(symbol: "eject", text: ejectMessage, colour: .red) }

        HStack {
            Button("Show Archive") { model.reveal() }
            Button("Show Google Photos") { model.reveal("Google Photos") }
            Spacer()
        }
        .padding(.top, 18)
        HStack {
            Button("Eject \(model.archive?.name ?? "Archive")") { ejectMessage = model.ejectArchive() }
            Button("Eject \(model.cardName)") {
                Task {
                    ejectMessage = await model.ejectCard()
                    if ejectMessage == nil { model.close() }
                }
            }
            Spacer()
            Button("Done") { model.close() }.keyboardShortcut(.defaultAction)
        }
        .padding(.top, 8)
        Text("Eject a drive before unplugging it, so everything is written to it.").font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }

    private var headline: String {
        if summary.stopped != nil { return "Apply stopped" }
        if summary.declined { return "Copied. Nothing deleted." }
        return summary.gateBlockers.isEmpty ? "Apply finished" : "Copied, with problems"
    }

    private var deletedDetail: String? {
        if summary.declined { return "You chose to keep everything." }
        if !summary.notDeleted.isEmpty && summary.deletedFromCard.isEmpty {
            return "Rejects were not deleted in this run."
        }
        return nil
    }

    private static func describe(_ problem: ApplyExecutor.FinalCheck.Problem) -> String {
        let who = problem.owner.id.split(separator: "/").last.map(String.init) ?? problem.owner.id
        switch problem.kind {
        case .notArchived(let role):
            return "\(who): its \(role == .raw ? "RAF" : role == .jpg ? "JPG" : "file") was not copied"
        case .missing(let location): return "\(location.name): missing from the archive"
        case .changed(let location): return "\(location.name): changed on the archive since it was copied"
        case .unreachable(let destination): return "\(who): its folder “\(destination.folder)” can't be found"
        }
    }

    private static func describe(_ skipped: ApplyExecutor.RemovalOutcome.SkippedFrame) -> String {
        let who = skipped.frame.rawValue.split(separator: "/").last.map(String.init) ?? skipped.frame.rawValue
        switch skipped.reason {
        case .notRejected, .notThisFramesFile: return "\(who): skipped, its decision didn't match"
        case .noCaptureDate: return "\(who): no capture date"
        case .cardLocked: return "\(who): the card is locked"
        case .archiveFileMissing(let location): return "\(who): \(location.name) is no longer on the archive"
        case .archiveFileChanged(let location):
            return "\(who): \(location.name) was changed on the archive, so it was left"
        case .trashFailed(let location): return "\(who): \(location.name) couldn't be moved to the Trash"
        case .cardFileChanged: return "\(who): changed on the card since it was scanned"
        case .cardFileLocked: return "\(who): locked on the card"
        case .deleteFailed: return "\(who): couldn't be deleted"
        case .pairSplit: return "\(who): only one of its two files was deleted; run Apply again"
        }
    }
}

private struct FailedView: View {
    let model: ApplyModel
    let message: String

    var body: some View {
        Title(text: "Apply can't continue")
        Text(message).fixedSize(horizontal: false, vertical: true)
        HStack {
            Button("Close") { model.close() }.keyboardShortcut(.cancelAction)
            Spacer()
            Button("Back") { model.back() }.keyboardShortcut(.defaultAction)
        }
        .padding(.top, 22)
    }
}
