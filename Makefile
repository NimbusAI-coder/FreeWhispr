APP_NAME  ?= FreeWhispr
BUILD_DIR  = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
CONTENTS   = $(APP_BUNDLE)/Contents
MACOS_DIR  = $(CONTENTS)/MacOS
RESOURCES  = $(CONTENTS)/Resources
EXEC       = $(MACOS_DIR)/$(APP_NAME)

SOURCES = $(shell find Sources -name '*.swift' -type f | LC_ALL=C sort)
SDK     = $(shell xcrun --show-sdk-path)
ARCH   ?= $(shell uname -m)

.PHONY: all clean run install

all: $(EXEC)

$(EXEC): $(SOURCES) Info.plist
	@mkdir -p "$(MACOS_DIR)" "$(RESOURCES)"
	swiftc \
		-parse-as-library \
		-swift-version 5 \
		-O \
		-o "$(EXEC)" \
		-sdk $(SDK) \
		-target $(ARCH)-apple-macosx26.0 \
		-framework AppKit \
		-framework AVFoundation \
		-framework Speech \
		$(SOURCES)
	@cp Info.plist "$(CONTENTS)/Info.plist"
	@codesign --force --deep --sign - \
		--entitlements FreeWhispr.entitlements \
		"$(APP_BUNDLE)" 2>/dev/null || \
		codesign --force --deep --sign - "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

run: all
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@open "$(APP_BUNDLE)"

# Copy into /Applications. Accessibility permission is keyed to the binary's
# location and signature, so re-granting is expected after the first install.
install: all
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(APP_BUNDLE)" /Applications/
	@echo "Installed to /Applications/$(APP_NAME).app"

clean:
	rm -rf $(BUILD_DIR)
