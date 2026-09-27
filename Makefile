.PHONY: all build test bundle sign doctor cert cert-help clean install-ingest uninstall-ingest

APP        := SpeechLocal
BUNDLE_ID  := dev.kilanii.speechlocal
CONFIG     := release
BUILD_DIR  := .build/$(CONFIG)
APP_DIR    := dist/$(APP).app
# Stable self-signed identity. Ad-hoc signing (`-`) mints a NEW identity every
# build, so macOS drops the Accessibility grant and stops re-prompting. See
# `make cert-help`.
IDENTITY   ?= SpeechLocal Dev

all: bundle sign

build:
	swift build -c $(CONFIG)

# Swift Testing, not XCTest — XCTest ships only with Xcode and this project
# builds against Command Line Tools. The framework and its interop dylib live in
# two *different* CLT directories, and SwiftPM adds neither automatically, so
# both a search path and two rpaths are required or the bundle fails to dlopen.
TESTING_FW  := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
TESTING_LIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib

# Only when the active toolchain IS Command Line Tools. With Xcode selected
# (`xcode-select -p` under Xcode.app), Swift Testing ships with the compiler,
# and pointing it at the CLT copy fails in the @Test macro expansion
# ("module 'Testing' has no member named '__SourceBounds'") — seen 2026-09-27
# after Xcode became the selected toolchain.
DEVELOPER_DIR_ACTIVE := $(shell xcode-select -p)

test:
ifneq (,$(findstring CommandLineTools,$(DEVELOPER_DIR_ACTIVE)))
	swift test \
		-Xswiftc -F -Xswiftc "$(TESTING_FW)" \
		-Xlinker -rpath -Xlinker "$(TESTING_FW)" \
		-Xlinker -rpath -Xlinker "$(TESTING_LIB)"
else
	swift test
endif

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
	@codesign --force --options runtime --entitlements build/SpeechLocal.entitlements \
		--sign "$(IDENTITY)" "$(APP_DIR)"
	@codesign --verify --strict --verbose=2 "$(APP_DIR)"
	@codesign -dvvv "$(APP_DIR)" 2>&1 | grep -E 'Identifier|Authority' || true
	@echo "signed with '$(IDENTITY)'"

cert:
	@./build/make-cert.sh "$(IDENTITY)"

# Launched via `open`, NOT as a terminal child. A process started from the shell
# inherits Terminal's TCC grants, so AXIsProcessTrusted() returns true whether or
# not SpeechLocal itself was ever approved — a false pass. Only a Finder/launchd
# launch runs under the app's own identity, so results are read back from the log.
doctor: sign
	@rm -f "$(HOME)/Library/Logs/SpeechLocal/doctor.log"
	@# -n forces a NEW instance: without it `open` merely fronts the running
	@# listener and the diagnostics argument is ignored.
	@open -n "$(APP_DIR)" --args --diagnostics
	@sleep 6
	@cat "$(HOME)/Library/Logs/SpeechLocal/doctor.log" 2>/dev/null || echo "no diagnostics output"
	@grep -q "ALL CHECKS PASS" "$(HOME)/Library/Logs/SpeechLocal/doctor.log" 2>/dev/null

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

# --- Meetings reach the wiki (decision 13) ----------------------------------
# A launchd agent runs tools/ingest-meetings.sh every 30 minutes. The app is not
# involved and stays offline; the script hands each new raw/meetings/ file to a
# `claude -p` session that ingests it by the vault's own rules.
#
# The plist is rendered, not copied verbatim: launchd expands neither `~` nor
# $HOME, so __HOME__ and __REPO__ are filled in here. The agent runs the script
# from THIS checkout, so install from the main checkout — a worktree is deleted
# later and the agent would point at nothing.
#
# ingest-since is written once, with today's date: the first install ingests
# meetings filed from today on, never the backlog. Reinstalling keeps the date.
# To take the backlog, run the script by hand with --since all.
INGEST_LABEL := dev.kilanii.speechlocal.ingest
INGEST_PLIST := $(HOME)/Library/LaunchAgents/$(INGEST_LABEL).plist
INGEST_STATE := $(HOME)/Library/Application Support/SpeechLocal

install-ingest:
	@case "$(CURDIR)" in */.claude/worktrees/*) \
		echo "ERROR: run this from the main checkout, not a worktree ($(CURDIR))."; exit 1;; esac
	@mkdir -p "$(HOME)/Library/LaunchAgents" "$(INGEST_STATE)" "$(HOME)/Library/Logs/SpeechLocal"
	@test -f "$(INGEST_STATE)/ingest-since" || date +%Y-%m-%d > "$(INGEST_STATE)/ingest-since"
	@sed -e 's|__REPO__|$(CURDIR)|g' -e 's|__HOME__|$(HOME)|g' \
		tools/$(INGEST_LABEL).plist > "$(INGEST_PLIST)"
	@plutil -lint "$(INGEST_PLIST)"
	@launchctl bootout gui/$$(id -u)/$(INGEST_LABEL) 2>/dev/null || true
	@launchctl bootstrap gui/$$(id -u) "$(INGEST_PLIST)"
	@echo "installed $(INGEST_LABEL): every 30 min, meetings filed since $$(cat "$(INGEST_STATE)/ingest-since")"
	@echo "log:     ~/Library/Logs/SpeechLocal/ingest.log"
	@echo "run now: launchctl kickstart gui/$$(id -u)/$(INGEST_LABEL)"

uninstall-ingest:
	@launchctl bootout gui/$$(id -u)/$(INGEST_LABEL) 2>/dev/null || true
	@rm -f "$(INGEST_PLIST)"
	@echo "removed $(INGEST_LABEL). State kept: $(INGEST_STATE)/ingested.txt, ingest-since"
