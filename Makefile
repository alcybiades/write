APP    := Write
BUNDLE := dist/$(APP).app
BIN    := .build/release/$(APP)

.PHONY: build app run install clean test benchmark-gallery

test:
	@mkdir -p .build/tests
	@swiftc -o .build/tests/behavior \
		Sources/Write/Theme.swift \
		Sources/Write/Workspace.swift \
		Sources/Write/ReferencePicker.swift \
		Sources/Write/MarkdownHighlighter.swift \
		Sources/Write/EditorTextView.swift \
		Support/BehaviorTests/main.swift
	@.build/tests/behavior
	@swiftc -o .build/tests/workspace $(filter-out Sources/Write/main.swift,$(wildcard Sources/Write/*.swift)) Support/WorkspaceTests/main.swift
	@.build/tests/workspace
	@swiftc -o .build/tests/images Sources/Write/ImageLoader.swift Support/ImageTests/main.swift
	@.build/tests/images

benchmark-gallery:
	@mkdir -p .build/tests
	@swiftc -O -whole-module-optimization -o .build/tests/gallery-benchmark $(filter-out Sources/Write/main.swift,$(wildcard Sources/Write/*.swift)) Support/GalleryBenchmark/main.swift
	@.build/tests/gallery-benchmark "$(GALLERY)"

build:
	swift build -c release

app: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Support/Info.plist $(BUNDLE)/Contents/Info.plist
	cp Support/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	codesign --force --sign - $(BUNDLE)

run: app
	open $(BUNDLE)

install: app
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/

clean:
	rm -rf .build dist
