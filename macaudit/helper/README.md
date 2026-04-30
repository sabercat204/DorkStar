# macaudit-helper — Compiled Swift Plist Processor

Batch plist processing accelerator for macaudit. Replaces the per-file
fork loop in `lib/baseline.sh` with a single compiled binary invocation.

## Requirements

- **macOS 13+** (Ventura or later)
- **Xcode** (not just Command Line Tools — SPM manifest compilation
  requires the full Xcode toolchain on Swift 6.x due to a known
  `libPackageDescription.dylib` linker issue with CLT-only installs)
- **Swift 5.9+** (ships with Xcode 15+)

## Build

```bash
cd macaudit/helper
swift build -c release
```

The binary lands at `.build/release/macaudit-helper`.

## Usage

```bash
# Process plists from stdin
find ~/Library/LaunchAgents -name '*.plist' | macaudit-helper

# Process from a file
macaudit-helper --input paths.txt

# With launch-key projection (Tier 1)
macaudit-helper --projection launch-keys < paths.txt

# With security-key projection (Tier 2)
macaudit-helper --projection security-keys --domain com.apple.alf < paths.txt
```

## Integration

When `macaudit-helper` is on PATH or at `macaudit/helper/.build/release/macaudit-helper`,
`baseline.sh` uses it automatically. When absent, the existing per-fork loop runs unchanged.

## Known Issue: Command Line Tools Only

Swift Package Manager on macOS with only Command Line Tools (no Xcode)
may fail to link `Package.swift` with:

```
Undefined symbols: PackageDescription.Package.__allocating_init
```

This is a known Apple regression in Swift 6.x CLT. Install Xcode to resolve.
