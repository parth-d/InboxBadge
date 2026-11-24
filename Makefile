APP := InboxBadge.app
BUNDLE_ID := io.github.parth-d.InboxBadge
TESTING_PLUGINS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
TEST_FLAGS := $(shell [ -d $(TESTING_PLUGINS) ] && echo -Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

SIGN_NAME := InboxBadge Local Signing
SIGN_KC := $(HOME)/Library/Keychains/inboxbadge-signing.keychain-db
SIGN_PW := $(HOME)/.inboxbadge-signing-pw

.PHONY: test build app install run logs clean signing-identity

test:
	swift test $(TEST_FLAGS)

build:
	swift build -c release

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/InboxBadge $(APP)/Contents/MacOS/InboxBadge
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	@if [ -f "$(SIGN_KC)" ] && [ -f "$(SIGN_PW)" ]; then \
	  security unlock-keychain -p "$$(cat $(SIGN_PW))" "$(SIGN_KC)" && \
	  codesign --force --sign "$(SIGN_NAME)" --keychain "$(SIGN_KC)" --options runtime --entitlements Resources/InboxBadge.entitlements $(APP); \
	else \
	  echo "no signing identity (make signing-identity): ad-hoc signing"; \
	  codesign --force --sign - --options runtime --entitlements Resources/InboxBadge.entitlements $(APP); \
	fi

install: app
	-pkill -x InboxBadge
	mkdir -p $(HOME)/Applications
	rm -rf $(HOME)/Applications/$(APP)
	ditto $(APP) $(HOME)/Applications/$(APP)

run:
	open $(HOME)/Applications/$(APP)

logs:
	log show --last 15m --info --debug --predicate 'subsystem == "$(BUNDLE_ID)"'

signing-identity:
	tools/create-signing-identity.sh

clean:
	rm -rf .build $(APP)
