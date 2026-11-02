# Build, test and install AI Usage Viewer.
#
#   make test           run the unit tests (UsageCore)
#   make install        test, build Release, replace /Applications copy, relaunch
#   make install-feed   turn on live updates from Claude Code's status line
#   make uninstall-feed turn them off and restore your previous status line

APP      := AI Usage Viewer
PROJECT  := $(APP).xcodeproj
BUILD    := build
PRODUCT  := $(BUILD)/Build/Products/Release/$(APP).app
DEST     := /Applications/$(APP).app
# The app's name before it covered Gemini and OpenAI; install removes it.
OLD_APP  := Claude Usage Viewer
# Build number = commit count, so About shows exactly what's installed.
BUILD_NO := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

.PHONY: test build install install-feed uninstall-feed clean

test:
	swift test

build:
	xcodebuild -quiet -project "$(PROJECT)" -scheme "$(APP)" -configuration Release \
		-derivedDataPath "$(BUILD)" CURRENT_PROJECT_VERSION=$(BUILD_NO) build

install: test build
	-osascript -e 'quit app "$(APP)"' 2>/dev/null
	-pkill -x "$(APP)"
	-osascript -e 'quit app "$(OLD_APP)"' 2>/dev/null
	-pkill -x "$(OLD_APP)"
	rm -rf "$(DEST)" "/Applications/$(OLD_APP).app"
	ditto "$(PRODUCT)" "$(DEST)"
	open "$(DEST)"
	@echo "Installed $(DEST) (build $(BUILD_NO))"

install-feed:
	"$(DEST)/Contents/MacOS/$(APP)" --install-statusline-feed

uninstall-feed:
	"$(DEST)/Contents/MacOS/$(APP)" --uninstall-statusline-feed

clean:
	rm -rf "$(BUILD)" .build
