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

# Sign with a stable identity when one exists, so macOS keeps treating
# rebuilds as the same app and the Accessibility grant survives. Ad-hoc
# signing ("-") changes the signature every build, which silently
# invalidates the grant while System Settings still shows it as on.
# Create one with: openssl + `security import` + add-trusted-cert
# (see README), named "FreeWhispr Local Signing".
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -o '"FreeWhispr Local Signing"' | head -1 | tr -d '"')
ifeq ($(SIGN_IDENTITY),)
SIGN_IDENTITY = -
endif

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
	@codesign --force --deep --sign "$(SIGN_IDENTITY)" \
		--entitlements FreeWhispr.entitlements \
		"$(APP_BUNDLE)" 2>/dev/null || \
		codesign --force --deep --sign "$(SIGN_IDENTITY)" "$(APP_BUNDLE)"
	@if [ "$(SIGN_IDENTITY)" = "-" ]; then \
		echo "note: ad-hoc signed; Accessibility must be re-granted after each rebuild"; \
	fi
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
