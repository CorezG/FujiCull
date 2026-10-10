import Foundation
import Testing

@testable import FujiCullCore

// Finding camera cards and the identity base for a source (R1, SR1, SR2).
@Suite struct SourceLocatorTests {

    @Test func aVolumeWithAFujiFolderInDCIMIsACameraCard() throws {
        let tree = try TempTree()
        try tree.file("DCIM/124_FUJI/DSCF3403.JPG")

        #expect(SourceLocator.isCameraCard(tree.root))
    }

    @Test func anEmptyFujiFolderStillCounts() throws {
        let tree = try TempTree()
        try FileManager.default.createDirectory(at: tree.url("DCIM/123_FUJI"), withIntermediateDirectories: true)

        #expect(SourceLocator.isCameraCard(tree.root))
    }

    @Test func folderNamesAreMatchedCaseInsensitively() throws {
        let tree = try TempTree()
        try FileManager.default.createDirectory(at: tree.url("dcim/100_fuji"), withIntermediateDirectories: true)

        #expect(SourceLocator.isCameraCard(tree.root))
    }

    @Test func aDCIMFolderWithoutFujiSubfoldersIsNotACameraCard() throws {
        // Like the archive SSD, which has DCIM/ with JPGs directly inside it.
        let tree = try TempTree()
        try tree.file("DCIM/P1210034.JPG")

        #expect(SourceLocator.isCameraCard(tree.root) == false)
    }

    @Test func aFolderWithoutDCIMIsNotACameraCard() throws {
        let tree = try TempTree()
        try tree.file("Japan 2024/DSCF0001.JPG")

        #expect(SourceLocator.isCameraCard(tree.root) == false)
    }

    @Test func cameraCardsAreFilteredFromMountedVolumes() throws {
        let card = try TempTree()
        try card.file("DCIM/100_FUJI/DSCF0001.JPG")
        let archive = try TempTree()
        try archive.file("DCIM/P1210034.JPG")

        #expect(SourceLocator.cameraCards(among: [archive.root, card.root]) == [card.root])
    }

    @Test func aFolderOnTheInternalDiskIsItsOwnIdentityBase() throws {
        let tree = try TempTree()
        let folder = tree.url("Trip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        #expect(SourceLocator.identityBase(for: folder).standardizedFileURL == folder.standardizedFileURL)
    }
}
