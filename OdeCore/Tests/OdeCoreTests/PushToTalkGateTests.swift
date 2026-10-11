import Testing
@testable import OdeCore

@Suite struct PushToTalkGateTests {
    var gate = PushToTalkGate()

    mutating func down(repeat isRepeat: Bool = false, modifiers: Bool = false, textField: Bool = false,
                       mainWindow: Bool = true, space: Bool = true) -> PushToTalkGate.Action {
        gate.keyDown(isSpace: space, isRepeat: isRepeat, hasModifiers: modifiers, inTextField: textField, inMainWindow: mainWindow)
    }

    @Test mutating func aPlainPressStartsAndItsReleaseFinishes() {
        #expect(down() == .start)
        #expect(gate.keyUp(isSpace: true) == .finish)
    }

    @Test mutating func repeatsWhileHoldingAreSwallowed() {
        _ = down()
        #expect(down(repeat: true) == .swallow)
        #expect(down(repeat: true, textField: true) == .swallow)
    }

    @Test mutating func theReleaseOfOurPressAlwaysFinishes() {
        _ = down()
        #expect(down(repeat: true, modifiers: true) == .swallow)
        #expect(gate.keyUp(isSpace: true) == .finish)
    }

    @Test(arguments: [(true, false, true), (false, true, true), (false, false, false)])
    mutating func spaceIsJustASpaceInFieldsWithModifiersAndInSheets(_ textField: Bool, _ modifiers: Bool, _ mainWindow: Bool) {
        #expect(down(modifiers: modifiers, textField: textField, mainWindow: mainWindow) == .pass)
        #expect(gate.keyUp(isSpace: true) == .pass)
    }

    @Test mutating func aRepeatWeNeverSawStartIsPassedThrough() {
        #expect(down(repeat: true) == .pass)
    }

    @Test mutating func losingFocusWhileHoldingFinishes() {
        _ = down()
        #expect(gate.lostFocus() == .finish)
        #expect(gate.keyUp(isSpace: true) == .pass)
    }

    @Test mutating func losingFocusWhenIdleDoesNothing() {
        #expect(gate.lostFocus() == .pass)
    }

    @Test mutating func otherKeysPass() {
        #expect(down(space: false) == .pass)
        #expect(gate.keyUp(isSpace: false) == .pass)
    }
}
