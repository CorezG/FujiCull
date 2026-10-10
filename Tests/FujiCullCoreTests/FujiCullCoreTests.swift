import Testing

@testable import FujiCullCore

@Test func versionIsSemantic() {
    let parts = FujiCullCore.version.split(separator: ".")
    #expect(parts.count == 3)
    #expect(parts.allSatisfy { Int($0) != nil })
}
