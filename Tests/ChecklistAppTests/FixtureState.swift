/// Mutable synthetic transport inputs stay on the same actor as their readers.
@MainActor final class FixtureState<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
