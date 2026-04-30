import CryptoKit
import Foundation

/// Compute the lowercase 64-hex SHA-256 of raw bytes.
func sha256Hex(_ data: Data) -> String {
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Compute sha256_canonical: deserialize plist, re-serialize as sorted-keys
/// JSON, then SHA-256 the result. Returns empty string on any failure.
///
/// The canonical pipeline must match Phase 1's:
///   plutil -convert json -o - <file> | jq -cS '.'
///
/// Foundation's JSONSerialization with .sortedKeys produces the same
/// sorted-key compact JSON that jq -cS does, with one caveat: numeric
/// signed-zero (-0.0) handling. Phase 1 normalises -0.0 → 0 via a jq
/// walk filter. We replicate that by walking the deserialised plist and
/// replacing any NSNumber whose doubleValue == 0.0 with NSNumber(value: 0).
func sha256Canonical(_ data: Data) -> String {
    guard !data.isEmpty else { return "" }

    // Deserialize plist (accepts binary, XML, or JSON)
    guard let plistObj = try? PropertyListSerialization.propertyList(
        from: data, options: [], format: nil
    ) else {
        return ""
    }

    // Normalise signed zeros then serialize as sorted-keys JSON
    let normalised = normaliseZeros(plistObj)
    guard var jsonData = try? JSONSerialization.data(
        withJSONObject: normalised,
        options: [.sortedKeys, .fragmentsAllowed]
    ) else {
        return ""
    }

    // Foundation's JSONSerialization escapes forward slashes (/ → \/)
    // which is valid JSON but produces different bytes than jq/plutil.
    // Phase 1's pipeline (plutil -convert json | jq -cS) does NOT escape
    // forward slashes. We must unescape them so the hashes match.
    if var jsonString = String(data: jsonData, encoding: .utf8) {
        jsonString = jsonString.replacingOccurrences(of: "\\/", with: "/")
        jsonData = Data(jsonString.utf8)
    }

    // jq -cS always appends a trailing newline to its output. The Phase 1
    // pipeline hashes that newline as part of the canonical form:
    //   plutil -convert json | jq -cS '.' | shasum -a 256
    // We must include the same trailing newline so the hashes match.
    jsonData.append(0x0A) // '\n'
    return sha256Hex(jsonData)
}

/// Recursively walk a plist object tree and replace any numeric 0 / -0
/// with a canonical positive 0. This matches Phase 1's jq filter:
///   walk(if . == 0 then 0 else . end)
private func normaliseZeros(_ obj: Any) -> Any {
    if let dict = obj as? [String: Any] {
        return dict.mapValues { normaliseZeros($0) }
    }
    if let arr = obj as? [Any] {
        return arr.map { normaliseZeros($0) }
    }
    if let num = obj as? NSNumber {
        // Check if it's a boolean first (NSNumber wraps bools too)
        if CFGetTypeID(num) == CFBooleanGetTypeID() {
            return num
        }
        if num.doubleValue == 0.0 {
            return NSNumber(value: 0)
        }
    }
    return obj
}
