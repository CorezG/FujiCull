import SwiftUI

@main
struct FujiCullApp: App {
    var body: some Scene {
        // One window, one source at a time (DESIGN §5.5). Dark so the photo is the brightest thing on screen (R18).
        Window("FujiCull", id: "main") {
            Color.black
                .ignoresSafeArea()
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(.dark)
        }
    }
}
