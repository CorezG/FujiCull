import Testing

@testable import FujiCullCore

/// Pre-flight warns when the archive drive is on a USB 2.0 link, where a copy takes several times longer.
struct CopyEstimateTests {
    @Test func aUSB2LinkIsSlow() {
        #expect(CopyEstimate.isSlowLink(bitsPerSecond: 480_000_000))
        #expect(CopyEstimate.isSlowLink(bitsPerSecond: 12_000_000))
    }

    @Test func aUSB3LinkIsNotSlow() {
        #expect(!CopyEstimate.isSlowLink(bitsPerSecond: 5_000_000_000))
        #expect(!CopyEstimate.isSlowLink(bitsPerSecond: 10_000_000_000))
    }

    @Test func aDriveWithNoKnownLinkSpeedIsNotCalledSlow() {
        #expect(!CopyEstimate.isSlowLink(bitsPerSecond: nil))
    }

    @Test func minutesOverASlowLinkUseTheMeasuredRateAndRoundUp() {
        // 17 MB/s, measured over a USB 2.0 link on 2026-11-16: 38 GB is a little over 37 minutes.
        #expect(CopyEstimate.minutesOverSlowLink(bytes: 38_000_000_000) == 38)
        #expect(CopyEstimate.minutesOverSlowLink(bytes: 1) == 1)
        #expect(CopyEstimate.minutesOverSlowLink(bytes: 0) == 0)
    }
}
