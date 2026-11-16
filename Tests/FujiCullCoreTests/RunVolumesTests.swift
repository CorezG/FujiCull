import Foundation
import Testing

@testable import FujiCullCore

/// Only the card or the archive going away stops a running Apply. macOS mounts and unmounts volumes of its own
/// (the hidden Recovery volume, Time Machine snapshots, disk images) at any time, and those must not stop a copy.
struct RunVolumesTests {
    let card = URL(fileURLWithPath: "/Volumes/Fuji SD")
    let archive = URL(fileURLWithPath: "/Volumes/C&J Archive")

    @Test func theCardGoingAwayStopsTheRun() {
        #expect(RunVolumes.unmountStopsRun(URL(fileURLWithPath: "/Volumes/Fuji SD"), card: card, archive: archive))
    }

    @Test func theArchiveGoingAwayStopsTheRun() {
        #expect(
            RunVolumes.unmountStopsRun(URL(fileURLWithPath: "/Volumes/C&J Archive"), card: card, archive: archive))
    }

    @Test func aSystemVolumeGoingAwayDoesNotStopTheRun() {
        #expect(
            !RunVolumes.unmountStopsRun(URL(fileURLWithPath: "/System/Volumes/Recovery"), card: card, archive: archive))
        #expect(
            !RunVolumes.unmountStopsRun(URL(fileURLWithPath: "/Volumes/Some Installer"), card: card, archive: archive))
    }

    @Test func aTrailingSlashOrDotSegmentStillMatches() {
        #expect(RunVolumes.unmountStopsRun(URL(string: "file:///Volumes/Fuji%20SD/"), card: card, archive: archive))
        #expect(
            RunVolumes.unmountStopsRun(
                URL(fileURLWithPath: "/Volumes/./C&J Archive/"), card: card, archive: archive))
    }

    @Test func anUnmountThatDoesNotSayWhichVolumeStopsTheRunToBeSafe() {
        #expect(RunVolumes.unmountStopsRun(nil, card: card, archive: archive))
    }

    @Test func withNeitherDriveKnownNothingMatchesButAnUnnamedUnmountStillStops() {
        #expect(!RunVolumes.unmountStopsRun(URL(fileURLWithPath: "/Volumes/Fuji SD"), card: nil, archive: nil))
        #expect(RunVolumes.unmountStopsRun(nil, card: nil, archive: nil))
    }
}
