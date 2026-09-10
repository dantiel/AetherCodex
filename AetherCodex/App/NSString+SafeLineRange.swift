import Foundation

extension NSString {
    /// Safe line range computation that NEVER calls Foundation's lineRange(for:).
    /// That method throws NSRangeException on boundary cases — we avoid it entirely.
    /// Scans backward/forward from range.location to find enclosing newlines.
    func safeLineRange(for range: NSRange) -> NSRange {
        guard range.location >= 0,
              range.location <= length,
              length > 0
        else { return NSRange(location: 0, length: 0) }

        let start = min(range.location, length - 1)

        // Scan backward for newline
        var lineStart = start
        while lineStart > 0 {
            let ch = character(at: lineStart - 1)
            if ch == 0x0A || ch == 0x0D { break }
            lineStart -= 1
        }

        // Scan forward for newline
        var lineEnd = start
        while lineEnd < length {
            let ch = character(at: lineEnd)
            if ch == 0x0A || ch == 0x0D { break }
            lineEnd += 1
        }
        // Include the newline character
        if lineEnd < length { lineEnd += 1 }

        return NSRange(location: lineStart, length: lineEnd - lineStart)
    }
}
