SHELL := /bin/bash
DEV_APP_NAME := PeekPaneDev
PROD_APP_NAME := PeekPane
VERSION := $(shell tr -d '[:space:]' < VERSION 2>/dev/null || echo "1.0")

.PHONY: all build test lint analyze format app universal prod-app release firefox-zip firefox-sign install clean

all: lint test app

build:
	swift build

test:
	swift test

lint:
	./lint.sh

analyze:
	./lint.sh --analyze

format:
	swift format format --configuration .swift-format --in-place --recursive Sources Tests Package.swift

app:
	./build_app.sh --version=$(VERSION)

universal:
	./build_app.sh --universal --version=$(VERSION)

prod-app:
	./build_app.sh --release --version=$(VERSION)

release:
	./scripts/package_release.sh $(VERSION)

firefox-zip:
	./scripts/package_firefox_extension.sh

firefox-sign:
	./scripts/package_firefox_extension.sh --sign --channel=unlisted

install: app
	rm -rf "/Applications/$(DEV_APP_NAME).app"
	cp -R "$(DEV_APP_NAME).app" "/Applications/$(DEV_APP_NAME).app"
	@echo "Installed $(DEV_APP_NAME).app to /Applications/$(DEV_APP_NAME).app"

clean:
	swift package clean
	rm -rf .build "$(DEV_APP_NAME).app" "$(PROD_APP_NAME).app" dist
