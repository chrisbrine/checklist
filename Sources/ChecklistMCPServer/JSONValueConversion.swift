import Foundation
import MCP

/// Builds the MCP `Value` of a JSON object tree without a second pass through JSON text (CL-444).
///
/// `Value`'s decoder tries each case in turn and tests every string against a newly
/// built regular expression. For one 184 KB `service_info` reply that took 78 ms of
/// CPU in every new CLI process. On a saturated CPU the process loses the CPU many
/// times in that interval. This walk takes below 3 ms and gives the same value.
/// A number whose JSON text form the walk does not reproduce exactly goes through
/// the decoder alone (JSONSerialization reads some long decimals as NSDecimalNumber).
/// The walk returns nil for input that is no JSON tree; `mcpValue` then uses the
/// decoder for the whole input, so the result and the error never differ.
enum JSONValueConversion {
    /// 2^53: every whole number up to this size is exact in a Double, and
    /// JSONSerialization writes it as plain digits that the decoder reads as Int.
    private static let largestExactWholeNumber = 9_007_199_254_740_992.0
    private static let dataURLPrefix = Array("data:".utf8)

    static func value(_ any: Any) -> Value? {
        switch any {
        case is NSNull:
            return .null
        case let string as String:
            return self.string(string)
        case let number as NSNumber:
            return self.number(number)
        case let array as [Any]:
            var values: [Value] = []
            values.reserveCapacity(array.count)
            for element in array {
                guard let converted = value(element) else { return nil }
                values.append(converted)
            }
            return .array(values)
        case let object as [String: Any]:
            var values: [String: Value] = [:]
            values.reserveCapacity(object.count)
            for (key, element) in object {
                guard let converted = value(element) else { return nil }
                values[key] = converted
            }
            return .object(values)
        default:
            return nil
        }
    }

    /// The decoder's own rule: a string that parses as a data URL becomes `.data`.
    /// Only a string that starts with "data:" can match that expression.
    private static func string(_ string: String) -> Value {
        if string.utf8.starts(with: dataURLPrefix), Data.isDataURL(string: string),
           case let (mimeType, data)? = Data.parseDataURL(string) {
            return .data(mimeType: mimeType, data)
        }
        return .string(string)
    }

    private static func number(_ number: NSNumber) -> Value? {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
        if number is NSDecimalNumber { return decoded(number) }
        switch UInt8(bitPattern: number.objCType.pointee) {
        case UInt8(ascii: "c"), UInt8(ascii: "s"), UInt8(ascii: "i"), UInt8(ascii: "l"), UInt8(ascii: "q"),
             UInt8(ascii: "C"), UInt8(ascii: "S"), UInt8(ascii: "I"), UInt8(ascii: "L"):
            return .int(number.intValue)
        case UInt8(ascii: "Q"):
            let unsigned = number.uint64Value
            return unsigned <= UInt64(Int.max) ? .int(Int(unsigned)) : decoded(number)
        case UInt8(ascii: "d"):
            let double = number.doubleValue
            guard double.isFinite else { return nil }
            guard double.rounded(.towardZero) == double else { return .double(double) }
            return abs(double) <= largestExactWholeNumber ? .int(Int(double)) : decoded(number)
        default:
            return decoded(number)
        }
    }

    /// The decoder's result for one number is the same at the top level and inside a tree.
    private static func decoded(_ number: NSNumber) -> Value? {
        try? mcpValueByDecoding(number)
    }
}
