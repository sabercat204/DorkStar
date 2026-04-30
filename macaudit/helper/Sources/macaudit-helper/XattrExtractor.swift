import Foundation

/// Extract all extended attributes from a file path.
/// Returns a dictionary mapping attribute names to base64-encoded values.
/// Empty dictionary when no xattrs are present or on any error.
func extractXattrs(_ path: String) -> [String: String] {
    // List attribute names
    let namesBufSize = listxattr(path, nil, 0, 0)
    guard namesBufSize > 0 else { return [:] }

    var namesBuf = [CChar](repeating: 0, count: namesBufSize)
    let namesLen = listxattr(path, &namesBuf, namesBufSize, 0)
    guard namesLen > 0 else { return [:] }

    // Parse the null-separated name list
    let namesData = Data(bytes: namesBuf, count: namesLen)
    let names = namesData.split(separator: 0).compactMap { segment -> String? in
        String(data: segment, encoding: .utf8)
    }

    var result: [String: String] = [:]
    for name in names {
        // Get attribute value size
        let valSize = getxattr(path, name, nil, 0, 0, 0)
        guard valSize >= 0 else { continue }

        if valSize == 0 {
            result[name] = ""
            continue
        }

        var valBuf = [UInt8](repeating: 0, count: valSize)
        let readLen = getxattr(path, name, &valBuf, valSize, 0, 0)
        guard readLen >= 0 else { continue }

        let valData = Data(bytes: valBuf, count: readLen)
        result[name] = valData.base64EncodedString()
    }

    return result
}
