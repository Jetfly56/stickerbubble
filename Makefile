APP      = StickerBubble
VERSION := $(shell grep 'currentVersion' Sources/StickerBubble/AppUpdater.swift | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
BUNDLE   = $(APP).app
ZIP      = $(APP)-$(VERSION).zip
BINARY   = .build/release/$(APP)

.PHONY: release build app zip clean

release: build app zip
	@echo "Ready: $(ZIP)"

build:
	swift build -c release

app: $(BINARY)
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp $(BINARY) $(BUNDLE)/Contents/MacOS/$(APP)
	@printf '<?xml version="1.0" encoding="UTF-8"?>\n\
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n\
<plist version="1.0"><dict>\n\
  <key>CFBundleExecutable</key>      <string>$(APP)</string>\n\
  <key>CFBundleIdentifier</key>      <string>com.stickerbubble.app</string>\n\
  <key>CFBundleName</key>            <string>$(APP)</string>\n\
  <key>CFBundleVersion</key>         <string>$(VERSION)</string>\n\
  <key>CFBundleShortVersionString</key><string>$(VERSION)</string>\n\
  <key>CFBundlePackageType</key>     <string>APPL</string>\n\
  <key>NSPrincipalClass</key>        <string>NSApplication</string>\n\
  <key>LSMinimumSystemVersion</key>  <string>13.0</string>\n\
</dict></plist>\n' > $(BUNDLE)/Contents/Info.plist

zip: $(BUNDLE)
	rm -f $(ZIP)
	zip -r $(ZIP) $(BUNDLE)

clean:
	rm -rf $(BUNDLE) $(APP)-*.zip .build
