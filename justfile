# Clean build artifacts
clean:
    swift package clean
    xcodebuild clean \
        -project macOSdb.xcodeproj \
        -scheme macOSdb

# Build the Swift package
build:
    swift build

# Run Swift tests
test:
    swift test

# Run SwiftLint
lint:
    swiftlint --strict

# Validate JSON data files
lint-json:
    find data -name '*.json' -type f -exec jq empty {} +

# Audit GitHub Actions workflows
audit:
    zizmor .github/workflows/

# Build the app with xcodebuild
build-app:
    xcodebuild \
        -project macOSdb.xcodeproj \
        -scheme macOSdb \
        -destination 'generic/platform=macOS' \
        -configuration Debug \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        build

# Run tests with xcodebuild (matches CI)
test-xcode:
    xcodebuild test \
        -workspace . \
        -scheme macOSdb-Package \
        -destination 'platform=macOS' \
        -enableCodeCoverage YES

# Start the site dev server
site-dev:
    cd site && npm run dev

# Build the site
site-build:
    cd site && npm run build

# Preview the built site
site-preview:
    cd site && npm run preview

# Format site files with Prettier
site-format:
    cd site && npm run format

# Check site formatting
site-format-check:
    cd site && npm run format:check

# Install site dependencies
site-install:
    cd site && npm install

# Run all checks (lint, test, site formatting, site build)
check: lint lint-json test audit site-format-check site-build
