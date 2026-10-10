import Testing

@testable import FujiCullCore

// The one-handed keymap (REQUIREMENTS §4.3). macOS key codes: ← 123, → 124, ↓ 125, ↑ 126, Return 36, ⌫ 51.
@Suite struct KeyMapTests {

    @Test(arguments: [
        (KeyPress(keyCode: 126), KeyAction.cull(.keep)),
        (KeyPress(keyCode: 125), .cull(.reject)),
        (KeyPress(keyCode: 123), .cull(.previous)),
        (KeyPress(keyCode: 124), .cull(.next)),
        (KeyPress(keyCode: 123, shift: true), .cull(.jump(-10))),
        (KeyPress(keyCode: 124, shift: true), .cull(.jump(10))),
        (KeyPress(keyCode: 44, characters: "/"), .cull(.toggleFavourite)),
        (KeyPress(keyCode: 47, characters: "."), .cull(.reset)),
        (KeyPress(keyCode: 36), .toggleZoom),
        (KeyPress(keyCode: 39, characters: "'"), .cull(.toggleUndecidedFilter)),
        (KeyPress(keyCode: 51), .cull(.undo)),
        (KeyPress(keyCode: 5, characters: "g"), .toggleGrid),
        (KeyPress(keyCode: 34, characters: "i"), .toggleExif),
    ])
    func everyKeymapRowMapsToItsAction(press: KeyPress, action: KeyAction) {
        #expect(KeyMap.action(for: press) == action)
    }

    @Test func lettersMatchInEitherCase() {
        #expect(KeyMap.action(for: KeyPress(keyCode: 5, characters: "G", shift: true)) == .toggleGrid)
        #expect(KeyMap.action(for: KeyPress(keyCode: 34, characters: "I", shift: true)) == .toggleExif)
    }

    @Test func keysWithCommandControlOrOptionAreLeftForTheMenus() {
        #expect(KeyMap.action(for: KeyPress(keyCode: 126, command: true)) == nil)
        #expect(KeyMap.action(for: KeyPress(keyCode: 5, characters: "g", control: true)) == nil)
        #expect(KeyMap.action(for: KeyPress(keyCode: 44, characters: "/", option: true)) == nil)
    }

    @Test func unmappedKeysDoNothing() {
        #expect(KeyMap.action(for: KeyPress(keyCode: 0, characters: "a")) == nil)
        #expect(KeyMap.action(for: KeyPress(keyCode: 49, characters: " ")) == nil)
    }

    @Test func slashAndFullStopAreRecognisedByCharacterOnOtherKeyboardLayouts() {
        // On some layouts "/" isn't on key 44; the typed character decides.
        #expect(KeyMap.action(for: KeyPress(keyCode: 26, characters: "/")) == .cull(.toggleFavourite))
        #expect(KeyMap.action(for: KeyPress(keyCode: 43, characters: ".")) == .cull(.reset))
    }
}
