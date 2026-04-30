import Foundation

/// Process a single plist path: compute dual hashes, detect format,
/// extract xattrs, optionally project keys. Returns a PlistResult.
func processPlist(
    path: String,
    projection: Projection
) -> PlistResult {
    let url = URL(fileURLWithPath: path)

    // Resolve symlinks for reading but report the original path
    let resolvedPath = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        ? (try? URL(resolvingAliasFileAt: url).path) ?? path
        : path

    // Read file bytes
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolvedPath)) else {
        return PlistResult(
            path: path,
            sha256Raw: "",
            sha256Canonical: "",
            format: "invalid",
            sizeBytes: nil,
            mtime: "",
            xattrs: [:],
            content: nil,
            error: "File not found or unreadable"
        )
    }

    let sha256Raw = sha256Hex(data)
    let format = detectFormat(data)
    let sha256Canon = sha256Canonical(data)
    let xattrs = extractXattrs(path) // xattrs on the original path, not resolved

    // File metadata
    let attrs = try? FileManager.default.attributesOfItem(atPath: resolvedPath)
    let sizeBytes = (attrs?[.size] as? Int)
    let mtime: String
    if let modDate = attrs?[.modificationDate] as? Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        mtime = formatter.string(from: modDate)
    } else {
        mtime = ""
    }

    // Key projection (only when plist is valid and projection is requested)
    var content: [String: Any]? = nil
    switch projection {
    case .none:
        break
    case .launchKeys:
        if let plistObj = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) {
            content = projectKeys(plistObj, allowedKeys: launchKeySet) ?? [:]
        } else {
            content = [:]
        }
    case .securityKeys(let domain):
        if let allowedKeys = securityKeyMap[domain],
           let plistObj = try? PropertyListSerialization.propertyList(
               from: data, options: [], format: nil
           ) {
            content = projectKeys(plistObj, allowedKeys: allowedKeys) ?? [:]
        } else {
            content = [:]
        }
    }

    return PlistResult(
        path: path,
        sha256Raw: sha256Raw,
        sha256Canonical: sha256Canon,
        format: format,
        sizeBytes: sizeBytes,
        mtime: mtime,
        xattrs: xattrs,
        content: content,
        error: nil
    )
}

/// Projection mode for key filtering.
enum Projection {
    case none
    case launchKeys
    case securityKeys(domain: String)
}
