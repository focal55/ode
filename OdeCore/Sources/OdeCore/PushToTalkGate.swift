/// Decides what each Space press means. A press we start is always finished by its release or by losing focus,
/// whatever happens in between, so the mic can never be left on.
public struct PushToTalkGate: Sendable {
    public enum Action: Equatable, Sendable { case start, finish, swallow, pass }

    public private(set) var holding = false

    public init() {}

    public mutating func keyDown(isSpace: Bool, isRepeat: Bool, hasModifiers: Bool, inTextField: Bool, inMainWindow: Bool) -> Action {
        guard isSpace else { return .pass }
        if holding { return .swallow }
        guard !isRepeat, !hasModifiers, !inTextField, inMainWindow else { return .pass }
        holding = true
        return .start
    }

    public mutating func keyUp(isSpace: Bool) -> Action {
        guard isSpace, holding else { return .pass }
        holding = false
        return .finish
    }

    public mutating func lostFocus() -> Action {
        guard holding else { return .pass }
        holding = false
        return .finish
    }
}
