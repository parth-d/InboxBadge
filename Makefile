APP := InboxBadge.app
BUNDLE_ID := io.github.parth-d.InboxBadge
TESTING_PLUGINS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
TEST_FLAGS := $(shell [ -d $(TESTING_PLUGINS) ] && echo -Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

.PHONY: test build app install run logs clean

test:
	swift test $(TEST_FLAGS)

build:
	swift build -c release

app: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/InboxBadge $(APP)/Contents/MacOS/InboxBadge
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - --options runtime --entitlements Resources/InboxBadge.entitlements $(APP)

install: app
	-pkill -x InboxBadge
	mkdir -p $(HOME)/Applications
	rm -rf $(HOME)/Applications/$(APP)
	ditto $(APP) $(HOME)/Applications/$(APP)

run:
	open $(HOME)/Applications/$(APP)

logs:
	log show --last 15m --info --debug --predicate 'subsystem == "$(BUNDLE_ID)"'

clean:
	rm -rf .build $(APP)
