.PHONY: build install test qa verify icon clean

build:            ## Build build/Tangelo.app
	./scripts/build.sh

install:          ## Build, copy to ~/Applications and launch
	./scripts/build.sh --install

test:             ## Run the end-to-end conversion tests and the WebP encoder self-test
	swift build -c release --product tangelo-cli
	.build/release/tangelo-cli selftest-webp
	.build/release/tangelo-cli test-all

qa:               ## Deep QA: every action on every sample file, checking the results are correct
	swift build -c release --product tangelo-cli
	.build/release/tangelo-cli qa

verify:           ## Everything: builds, deep QA, WebP self-test, ring drags, leak test, memory profile
	./scripts/verify.sh

icon:             ## Regenerate the app icon
	swift scripts/make_icon.swift Resources/AppIcon.icns

clean:
	rm -rf .build build
