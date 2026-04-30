import Foundation

/// Detect plist format from the leading bytes of a file.
/// Returns one of: "binary", "xml", "json", "invalid".
func detectFormat(_ data: Data) -> String {
    guard !data.isEmpty else { return "invalid" }

    // Binary plist: starts with "bplist"
    if data.count >= 6 {
        let magic = String(data: data.prefix(6), encoding: .ascii) ?? ""
        if magic.hasPrefix("bplist") { return "binary" }
    }

    // Find first non-whitespace byte for XML/JSON detection
    let trimmed = data.drop(while: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D })
    guard let first = trimmed.first else { return "invalid" }

    switch first {
    case 0x3C: // '<' — XML plist (<?xml or <plist)
        return "xml"
    case 0x7B, 0x5B: // '{' or '[' — JSON
        return "json"
    default:
        return "invalid"
    }
}
