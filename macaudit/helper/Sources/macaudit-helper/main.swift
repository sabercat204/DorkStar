import Foundation

// ---------------------------------------------------------------------------
// macaudit-helper — batch plist processing accelerator
//
// Reads plist paths from stdin (one per line) or from --input <file>.
// For each path, computes dual hashes, detects format, extracts xattrs,
// and optionally projects launch keys or security-critical keys.
// Emits one compact JSON object per line on stdout.
//
// Exit codes:
//   0 — all paths processed (per-file errors reported inline as JSON)
//   1 — fatal error (invalid arguments, stdin read failure)
// ---------------------------------------------------------------------------

let version = "0.2.0"

// -- Argument parsing --------------------------------------------------------

var inputFile: String? = nil
var projection: Projection = .none
var args = CommandLine.arguments.dropFirst() // skip argv[0]

while let arg = args.first {
    args = args.dropFirst()
    switch arg {
    case "--version":
        print("macaudit-helper \(version)")
        exit(0)
    case "--help", "-h":
        let usage = """
        Usage: macaudit-helper [OPTIONS]

        OPTIONS:
          --input <file>                Read paths from file instead of stdin
          --projection launch-keys      Include Tier 1 launch-key content
          --projection security-keys    Include security-critical key content
          --domain <domain>             Domain for security-keys projection
          --version                     Print version and exit
          --help                        Print usage and exit

        STDIN:
          One absolute file path per line, UTF-8, newline-terminated.

        STDOUT:
          One compact JSON object per line (JSONL), UTF-8, newline-terminated.
        """
        print(usage)
        exit(0)
    case "--input":
        guard let next = args.first else {
            fputs("macaudit-helper: --input requires a value\n", stderr)
            exit(1)
        }
        inputFile = String(next)
        args = args.dropFirst()
    case "--projection":
        guard let next = args.first else {
            fputs("macaudit-helper: --projection requires a value\n", stderr)
            exit(1)
        }
        let projValue = String(next)
        args = args.dropFirst()
        switch projValue {
        case "launch-keys":
            projection = .launchKeys
        case "security-keys":
            projection = .securityKeys(domain: "") // domain set below
        default:
            fputs("macaudit-helper: unknown projection '\(projValue)'\n", stderr)
            exit(1)
        }
    case "--domain":
        guard let next = args.first else {
            fputs("macaudit-helper: --domain requires a value\n", stderr)
            exit(1)
        }
        let domain = String(next)
        args = args.dropFirst()
        // Update projection if it was security-keys
        if case .securityKeys = projection {
            projection = .securityKeys(domain: domain)
        }
    default:
        fputs("macaudit-helper: unknown argument '\(arg)'\n", stderr)
        exit(1)
    }
}

// -- Input source ------------------------------------------------------------

let lines: [String]
if let inputPath = inputFile {
    guard let content = try? String(contentsOfFile: inputPath, encoding: .utf8) else {
        fputs("macaudit-helper: unable to read input file '\(inputPath)'\n", stderr)
        exit(1)
    }
    lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
} else {
    // Read from stdin
    var stdinLines: [String] = []
    while let line = readLine(strippingNewline: true) {
        if !line.isEmpty {
            stdinLines.append(line)
        }
    }
    lines = stdinLines
}

// -- Process each path -------------------------------------------------------

for path in lines {
    let result = processPlist(path: path, projection: projection)
    emitJSON(result)
}

exit(0)
