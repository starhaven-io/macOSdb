# Build

# Build the Swift package
build:
    swift build

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
        EXCLUDED_ARCHS=x86_64 \
        build

# Clean build artifacts
clean:
    swift package clean
    xcodebuild clean \
        -project macOSdb.xcodeproj \
        -scheme macOSdb

# Test

# Run Swift tests
test:
    swift test

# Run tests with xcodebuild (matches CI)
test-xcode:
    xcodebuild test \
        -workspace . \
        -scheme macOSdb-Package \
        -destination 'platform=macOS' \
        -enableCodeCoverage YES \
        EXCLUDED_ARCHS=x86_64

# Lint

# Audit GitHub Actions workflows
audit:
    zizmor .github/workflows/

# Run SwiftLint
lint:
    swiftlint --strict

# Validate JSON data files
lint-json:
    python3 scripts/lint-json.py

# Scan for unused code (uses .periphery.yml)
periphery:
    periphery scan

# Check for typos
typos:
    typos

# Site

# Build the site
site-build:
    cd site && npm run build

# Start the site dev server
site-dev:
    cd site && npm run dev

# Format site files with Prettier
site-format:
    cd site && npm run format

# Check site formatting
site-format-check:
    cd site && npm run format:check

# Install site dependencies
site-install:
    cd site && npm install

# Preview the built site
site-preview:
    cd site && npm run preview

# Check

# Run all checks
check:
    #!/usr/bin/env bash
    set -euo pipefail
    failed=0
    skipped=()
    run() {
        echo "--- $1 ---"
        if ! "$@"; then
            failed=1
        fi
    }
    skip() {
        echo "--- $1 --- skipped ($2 not found)"
        skipped+=("$2 (brew install $3)")
    }
    if command -v swiftlint &>/dev/null; then
        run swiftlint --strict
    else
        skip lint swiftlint swiftlint
    fi
    run python3 scripts/lint-json.py
    if command -v typos &>/dev/null; then
        run typos
    else
        skip typos typos typos-cli
    fi
    if command -v zizmor &>/dev/null; then
        run zizmor .github/workflows/
    else
        skip audit zizmor zizmor
    fi
    run swift test
    echo "--- site-format-check ---"
    (cd site && npm run format:check) || failed=1
    echo "--- site-build ---"
    (cd site && npm run build) || failed=1
    if [ ${#skipped[@]} -gt 0 ]; then
        echo ""
        echo "Checks skipped due to missing tools:"
        for tool in "${skipped[@]}"; do
            echo "  - $tool"
        done
        failed=1
    fi
    exit $failed
