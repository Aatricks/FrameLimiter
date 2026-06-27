FPS ?= 80

.PHONY: build run-minimal run-uncapped clean

build:
	./scripts/build.sh

run-minimal: build
	FRAME_LIMIT_LOG=1 ./scripts/run-minimal.sh $(FPS)

run-uncapped: build
	./scripts/run-minimal.sh

clean:
	rm -rf build
