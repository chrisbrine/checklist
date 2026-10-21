import Foundation

/// A dash reads a bounded JSON argument from a separate CLI input stream.
public enum CallArgumentInput {
    public static let limit = 1_048_576

    public static func read(_ argument: String, input: FileHandle = .standardInput) throws -> Data {
        let data: Data
        if argument == "-" {
            var collected = Data()
            while collected.count <= limit {
                guard let part = try input.read(upToCount: limit + 1 - collected.count), !part.isEmpty else { break }
                collected.append(part)
            }
            data = collected
        } else { data = Data(argument.utf8) }
        guard data.count <= limit else {
            throw ChecklistError("TOO_LARGE", "Input exceeds 1 MiB; no command ran.", details: ["command_outcome": "not_sent", "command_executed": false])
        }
        return data
    }
}
