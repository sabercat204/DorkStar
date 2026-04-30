import Foundation

/// The output model for a successfully processed plist.
struct PlistResult {
    let path: String
    let sha256Raw: String
    let sha256Canonical: String
    let format: String
    let sizeBytes: Int?
    let mtime: String
    let xattrs: [String: String]
    let content: [String: Any]?
    let error: String?
}

/// Serialize a PlistResult as a single compact JSON line on stdout.
/// Uses JSONSerialization (not Codable) because `content` is [String: Any].
func emitJSON(_ result: PlistResult) {
    var dict: [String: Any] = [
        "path": result.path,
        "sha256_raw": result.sha256Raw,
        "sha256_canonical": result.sha256Canonical,
        "format": result.format,
        "xattrs": result.xattrs
    ]

    if let size = result.sizeBytes {
        dict["size_bytes"] = size
    } else {
        dict["size_bytes"] = NSNull()
    }

    dict["mtime"] = result.mtime

    if let err = result.error {
        dict["error"] = err
    }

    if let content = result.content {
        dict["content"] = content
    }

    guard let data = try? JSONSerialization.data(
        withJSONObject: dict,
        options: [.sortedKeys]
    ) else {
        // Fallback: emit a minimal error JSON
        let fallback = "{\"path\":\(jsonEscape(result.path)),\"error\":\"JSON serialization failed\",\"sha256_raw\":\"\",\"sha256_canonical\":\"\",\"format\":\"invalid\"}"
        print(fallback)
        return
    }

    if let line = String(data: data, encoding: .utf8) {
        print(line)
    }
}

/// JSON-escape a string for manual fallback serialization.
private func jsonEscape(_ s: String) -> String {
    let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    return "\"\(escaped)\""
}
