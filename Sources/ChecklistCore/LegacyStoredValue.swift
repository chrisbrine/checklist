/// The core writes and shows one spelling, "canceled". Records from older stores may still carry the
/// British spelling as a stored value; SQL predicates accept it through this one constant.
public enum LegacyStoredValue {
    public static let canceled = "cancelled"
}
