# Build

# Build the Swift package
build:
    swift build

# Clean build artifacts
clean:
    swift package clean

# Test

# Run Swift tests
test:
    swift test

# Run tests with code coverage
test-cov:
    swift test --enable-code-coverage

# Lint

# Audit GitHub Actions workflows
audit:
    zizmor --persona auditor .github/workflows/

# Run SwiftLint
lint:
    swiftlint --strict

# Validate JSON data files
lint-json:
    python3 scripts/lint-json.py

# Scan for unused code. native build system (deprecated): swiftbuild emits no index store Periphery can find.
periphery:
    swift build --build-tests --build-system native
    periphery scan --skip-build --index-store-path "$(find .build -path '*/debug/index/store' -type d | head -1)"

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
    cd site && npm ci --strict-allow-scripts

# Preview the built site
site-preview:
    cd site && npm run preview

# Check for broken links in the built site and README
lychee: site-build
    cd site && lychee --config ../lychee.toml --root-dir "$(pwd)/dist/client" 'dist/client/**/*.html' ../README.md

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
        run zizmor --persona auditor .github/workflows/
    else
        skip audit zizmor zizmor
    fi
    if command -v periphery &>/dev/null; then
        # native build system (deprecated): swiftbuild emits no index store Periphery can find
        run swift build --build-tests --build-system native
        run periphery scan --strict --disable-update-check --skip-build --index-store-path "$(find .build -path '*/debug/index/store' -type d | head -1)"
    else
        skip periphery periphery periphery
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

# Install git hooks (DCO sign-off + pre-push checks) — run once per clone
install-hooks:
    git config core.hooksPath .githooks
