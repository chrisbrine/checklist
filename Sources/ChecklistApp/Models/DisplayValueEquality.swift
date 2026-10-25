import Foundation

/// Compare inert JSON-shaped display values without encoding them on the main
/// actor. String bytes remain exact (Foundation dictionary equality folds some
/// canonically equivalent strings). Unknown/non-finite values are never equal.
enum DisplayValueEquality {
    static func records(_ lhs: [Record], _ rhs: [Record]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { same($0.values, $1.values) }
    }
    static func same(_ lhs: Any, _ rhs: Any) -> Bool {
        if let a = lhs as? String, let b = rhs as? String { return a.utf8.elementsEqual(b.utf8) }
        if let a = lhs as? NSNumber, let b = rhs as? NSNumber {
            guard CFGetTypeID(a) == CFGetTypeID(b), a.doubleValue.isFinite, b.doubleValue.isFinite else { return false }
            return a == b
        }
        if lhs is NSNull { return rhs is NSNull }
        if let a = lhs as? [String:Any], let b = rhs as? [String:Any] {
            guard a.count == b.count else { return false }
            return a.allSatisfy { key,value in
                guard let otherKey = b.keys.first(where: { $0.utf8.elementsEqual(key.utf8) }), let other = b[otherKey] else { return false }
                return same(value, other)
            }
        }
        if let a = lhs as? [Any], let b = rhs as? [Any] { return a.count == b.count && zip(a,b).allSatisfy {same($0,$1)} }
        return false
    }
}
