FPS ?= 80

.PHONY: build run-minimal run-uncapped clean install-app

build:
	./scripts/build.sh

# Install the self-contained menu-bar app to /Applications and register it so the game
# wrapper can launch it by bundle id (com.framelimiter.menu).
install-app: build
	rm -rf /Applications/FrameLimiter.app
	cp -R build/FrameLimiter.app /Applications/FrameLimiter.app
	/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f /Applications/FrameLimiter.app
	@echo "installed: /Applications/FrameLimiter.app"

run-minimal: build
	FRAME_LIMIT_LOG=1 ./scripts/run-minimal.sh $(FPS)

run-uncapped: build
	./scripts/run-minimal.sh

clean:
	rm -rf build
