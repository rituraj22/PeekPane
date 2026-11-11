SHELL := /bin/bash
APP_NAME := PeekPane
VERSION := $(shell tr -d '[:space:]' < VERSION 2>/dev/null || echo "1.0")

.PHONY: all build test lint analyze format app universal release install clean

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

release:
	./scripts/package_release.sh $(VERSION)

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP_NAME).app" "/Applications/$(APP_NAME).app"
	@echo "Installed $(APP_NAME).app to /Applications/$(APP_NAME).app"

clean:
	swift package clean
	rm -rf .build "$(APP_NAME).app" dist
