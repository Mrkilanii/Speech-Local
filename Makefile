.PHONY: all build test bundle sign doctor cert cert-help clean

APP        := FlowLocal
BUNDLE_ID  := dev.kilanii.flowlocal
CONFIG     := release
BUILD_DIR  := .build/$(CONFIG)
APP_DIR    := dist/$(APP).app
# Stable self-signed identity. Ad-hoc signing (`-`) mints a NEW identity every
# build, so macOS drops the Accessibility grant and stops re-prompting. See
# `make cert-help`.
IDENTITY   ?= FlowLocal Dev

all: bundle sign

build:
	swift build -c $(CONFIG)

# Swift Testing, not XCTest — XCTest ships only with Xcode and this project
# builds against Command Line Tools. The framework and its interop dylib live in
# two *different* CLT directories, and SwiftPM adds neither automatically, so
# both a search path and two rpaths are required or the bundle fails to dlopen.
TESTING_FW  := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
TESTING_LIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib

test:
	swift test \
		-Xswiftc -F -Xswiftc "$(TESTING_FW)" \
		-Xlinker -rpath -Xlinker "$(TESTING_FW)" \
		-Xlinker -rpath -Xlinker "$(TESTING_LIB)"

# Assemble a real .app. A bare SPM binary crashes on NSStatusBar
# (CGSConnectionByID assertion) — the bundle is mandatory, not cosmetic.
bundle: build
	@rm -rf "$(APP_DIR)"
	@mkdir -p "$(APP_DIR)/Contents/MacOS" "$(APP_DIR)/Contents/Resources"
	@cp build/Info.plist "$(APP_DIR)/Contents/Info.plist"
	@cp "$(BUILD_DIR)/$(APP)" "$(APP_DIR)/Contents/MacOS/$(APP)"
	@printf 'APPL????' > "$(APP_DIR)/Contents/PkgInfo"
	@echo "bundled -> $(APP_DIR)"

# Sign inside-out: nested code first, the bundle last. Signing the outer bundle
# before its nested frameworks produces a signature that fails --strict.
# NOTE: `find-identity -v` filters to *trusted* identities and will show zero
# here. A self-signed root is untrusted by default, but trust governs signature
# *verification*, not signing — codesign only needs the private key. Do not
# "fix" this by adding trust; it triggers an admin prompt and buys nothing.
sign: bundle
	@if ! security find-identity -p codesigning | grep -q "$(IDENTITY)"; then \
		echo "ERROR: no codesigning identity named '$(IDENTITY)'."; \
		echo "Run 'make cert' to create one."; \
		exit 1; \
	fi
	@# Extended attributes make codesign refuse with "resource fork, Finder
	@# information, or similar detritus not allowed". Must run after every copy.
	@xattr -cr "$(APP_DIR)"
	@find "$(APP_DIR)/Contents" \( -name '*.dylib' -o -name '*.framework' \) -print0 \
		| xargs -0 -I{} codesign --force --options runtime --sign "$(IDENTITY)" "{}" 2>/dev/null || true
	@# The hardened runtime (--options runtime) denies microphone access SILENTLY
	@# without com.apple.security.device.audio-input: no TCC prompt appears, the
	@# status stays notDetermined, and an audio engine starts and yields silence.
	@# NOTE: keep the entitlements file free of XML comments — AMFI's parser
	@# rejects them ("AMFIUnserializeXML: syntax error").
	@codesign --force --options runtime --entitlements build/FlowLocal.entitlements \
		--sign "$(IDENTITY)" "$(APP_DIR)"
	@codesign --verify --strict --verbose=2 "$(APP_DIR)"
	@codesign -dvvv "$(APP_DIR)" 2>&1 | grep -E 'Identifier|Authority' || true
	@echo "signed with '$(IDENTITY)'"

cert:
	@./build/make-cert.sh "$(IDENTITY)"

# Runs the checks under the app's OWN TCC identity. A CLI cannot substitute:
# AXIsProcessTrusted() inherits the terminal's grant and reports a false pass.
doctor: sign
	@"$(APP_DIR)/Contents/MacOS/$(APP)" --diagnostics

cert-help:
	@echo "One-time: create a stable self-signed code-signing certificate."
	@echo ""
	@echo "  1. Open Keychain Access"
	@echo "  2. Menu: Keychain Access > Certificate Assistant > Create a Certificate..."
	@echo "  3. Name:            $(IDENTITY)"
	@echo "     Identity Type:   Self Signed Root"
	@echo "     Certificate Type: Code Signing"
	@echo "  4. Create, then verify with:  security find-identity -v -p codesigning"
	@echo ""
	@echo "Why: ad-hoc signing generates a new identity per build, so macOS treats"
	@echo "each build as a different app and silently drops Accessibility."
	@echo "Self-signed is sufficient here — this app is built and run locally."

clean:
	rm -rf .build dist
