import Foundation

// Grammar only. Lookup text is not a routable identity.
enum OrdinaryMentionTokens {
    static let version = "ordinary-mentions-1"
    struct Token: Equatable {
        let start: Int
        let end: Int
        let query: String
        static func == (a: Self, b: Self) -> Bool {
            a.start == b.start && a.end == b.end && a.query.utf8.elementsEqual(b.query.utf8)
        }
    }
    enum Failure: Error, Equatable { case tooLarge, tooMany, malformed(Int) }

    // Bare: @CL-12 / @session-id / @worker. Spaces or punctuation in an exact
    // label use @{Target worker}. An odd run of backslashes escapes a marker.
    // Small literal rule: backtick code spans and line-start backtick/tilde
    // fences are skipped, without interpreting other Markdown constructs.
    static func parse(_ body: String) throws -> [Token] {
        guard body.utf8.count <= 65536 else { throw Failure.tooLarge }
        let scalars = Array(body.unicodeScalars)
        var offsets = [0]
        for scalar in scalars { offsets.append(offsets.last! + scalar.utf8.count) }
        var result: [Token] = [], i = 0
        while i < scalars.count {
            if scalars[i] == "`" || scalars[i] == "~" && fenceStart(scalars, at: i), !escaped(scalars, at: i) {
                let count = run(scalars, at: i)
                if scalars[i] == "`" || count >= 3 {
                    i = literalEnd(scalars, at: i, count: count)
                    continue
                }
            }
            guard scalars[i] == "@" else { i += 1; continue }
            var before = i, slashes = 0
            while before > 0 && scalars[before - 1] == "\\" { before -= 1; slashes += 1 }
            let boundary = before == 0 || CharacterSet.whitespacesAndNewlines.contains(scalars[before - 1])
                || "([{\"'".unicodeScalars.contains(scalars[before - 1])
            guard boundary, slashes % 2 == 0 else { i += 1; continue }
            let start = i
            i += 1
            guard i < scalars.count else { throw Failure.malformed(offsets[start]) }
            let queryStart: Int, queryEnd: Int
            if scalars[i] == "{" {
                i += 1; queryStart = i
                while i < scalars.count && scalars[i] != "}" {
                    guard scalars[i] != "{", scalars[i] != "\\",
                          !CharacterSet.newlines.contains(scalars[i]) else { throw Failure.malformed(offsets[start]) }
                    i += 1
                }
                guard i < scalars.count, i > queryStart,
                      !CharacterSet.whitespacesAndNewlines.contains(scalars[queryStart]),
                      !CharacterSet.whitespacesAndNewlines.contains(scalars[i - 1]) else { throw Failure.malformed(offsets[start]) }
                queryEnd = i; i += 1
            } else {
                queryStart = i
                while i < scalars.count && bare(scalars[i]) { i += 1 }
                guard i > queryStart else { throw Failure.malformed(offsets[start]) }
                queryEnd = i
            }
            let query = String(String.UnicodeScalarView(scalars[queryStart..<queryEnd]))
            guard query.utf8.count <= 4000 else { throw Failure.malformed(offsets[start]) }
            result.append(.init(start: offsets[start], end: offsets[i], query: query))
            guard result.count <= 50 else { throw Failure.tooMany }
        }
        return result
    }

    private static func bare(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
            || scalar == "_" || scalar == "-"
    }

    private static func escaped(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        var i = index, count = 0
        while i > 0 && scalars[i - 1] == "\\" { i -= 1; count += 1 }
        return count % 2 != 0
    }
    private static func run(_ scalars: [Unicode.Scalar], at index: Int) -> Int {
        var end = index
        while end < scalars.count && scalars[end] == scalars[index] { end += 1 }
        return end - index
    }
    private static func fenceStart(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        var i = index, spaces = 0
        while i > 0 && scalars[i - 1] == " " { i -= 1; spaces += 1 }
        return spaces <= 3 && (i == 0 || CharacterSet.newlines.contains(scalars[i - 1]))
    }
    private static func literalEnd(_ scalars: [Unicode.Scalar], at start: Int, count: Int) -> Int {
        let marker = scalars[start], fenced = count >= 3 && fenceStart(scalars, at: start)
        var i = start + count
        while i < scalars.count {
            guard scalars[i] == marker else { i += 1; continue }
            let length = run(scalars, at: i)
            if fenced {
                if length >= count && fenceStart(scalars, at: i) {
                    var end = i + length
                    while end < scalars.count && scalars[end] == " " { end += 1 }
                    if end == scalars.count || CharacterSet.newlines.contains(scalars[end]) { return i + length }
                }
            } else if length == count { return i + length }
            i += length
        }
        return scalars.count // unfinished code remains literal, never a route
    }
}
