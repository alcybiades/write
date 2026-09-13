APP    := Write
BUNDLE := dist/$(APP).app
BIN    := .build/release/$(APP)

.PHONY: build app run install clean test

test:
	@mkdir -p .build/tests
	@swiftc -o .build/tests/behavior \
		Sources/Write/Theme.swift \
		Sources/Write/MarkdownHighlighter.swift \
		Sources/Write/EditorTextView.swift \
		Support/BehaviorTests/main.swift
	@.build/tests/behavior

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
