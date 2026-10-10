import FujiCullCore
import Testing

@testable import FujiCullImaging

@Test func imagingLinksAgainstCore() {
    #expect(FujiCullImaging.coreVersion == FujiCullCore.version)
}
