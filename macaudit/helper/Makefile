# macaudit-helper build — works with Command Line Tools only (no Xcode required).
# Uses swiftc directly instead of SPM to avoid the libPackageDescription linker
# issue on Swift 6.x CLT-only installs.

SWIFT_FILES = \
	Sources/macaudit-helper/FormatDetector.swift \
	Sources/macaudit-helper/HashComputer.swift \
	Sources/macaudit-helper/XattrExtractor.swift \
	Sources/macaudit-helper/KeyProjection.swift \
	Sources/macaudit-helper/JSONOutput.swift \
	Sources/macaudit-helper/PlistProcessor.swift \
	Sources/macaudit-helper/main.swift

OUTPUT = .build/release/macaudit-helper

.PHONY: build clean

build: $(OUTPUT)

$(OUTPUT): $(SWIFT_FILES)
	@mkdir -p .build/release
	swiftc -O -module-name macaudit_helper $(SWIFT_FILES) -o $(OUTPUT)
	@printf 'Built %s\n' "$(OUTPUT)"

clean:
	rm -rf .build
