import XCTest

/// No writes reach Foundation's persistent domains, including writes by owners
/// retained past teardown. Window tests reopen the same in-memory child store.
final class IsolatedDefaults {
    let suiteName: String
    let preferences: UserDefaults
    let plistURL: URL
    private var children: [UUID: MemoryDefaults] = [:]

    init(_ label: String) {
        suiteName = "Checklist.TestDefaults." + label + "." + UUID().uuidString
        preferences = MemoryDefaults()
        plistURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preferences", isDirectory: true)
            .appendingPathComponent(suiteName).appendingPathExtension("plist")
    }

    func childPreferences(_ id: UUID) -> UserDefaults {
        if let child = children[id] { return child }
        let child = MemoryDefaults()
        children[id] = child
        return child
    }

    func clean() throws {
        (preferences as! MemoryDefaults).clear()
        for child in children.values { child.clear() }
    }
}

/// Override the UserDefaults read/write primitives; Foundation's typed accessors
/// use these too. Never initialize a named persistent suite or synchronize one.
private final class MemoryDefaults: UserDefaults {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }
    override func object(forKey key: String) -> Any? {
        lock.withLock { values[key] ?? registered[key] }
    }
    override func set(_ value: Any?, forKey key: String) {
        lock.withLock { values[key] = value }
    }
    override func removeObject(forKey key: String) {
        lock.withLock { _ = values.removeValue(forKey: key) }
    }
    override func register(defaults: [String: Any]) {
        lock.withLock { registered.merge(defaults) { _, new in new } }
    }
    override func dictionaryRepresentation() -> [String: Any] {
        lock.withLock { registered.merging(values) { _, new in new } }
    }
    override func synchronize() -> Bool { true }
    func clear() {
        lock.withLock { values.removeAll(); registered.removeAll() }
    }
}

extension XCTestCase {
    func isolatedDefaults(_ label: String = "App") -> IsolatedDefaults {
        let suite = IsolatedDefaults(label)
        addTeardownBlock { try suite.clean() }
        return suite
    }
}
