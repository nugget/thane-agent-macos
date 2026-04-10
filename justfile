set dotenv-load

app            := "thane-agent-macos"
build-dir      := "build"
notary-profile := env("NOTARYTOOL_PROFILE", "notarytool")
deploy-path    := env("DEPLOY_PATH", "Applications")

export DEVELOPER_DIR := env("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")

# List available recipes
default:
    @just --list

# --- Build ---

# Build for local development
[group('build')]
build:
    xcodebuild -scheme {{app}} -destination 'platform=macOS' build

# Archive for distribution
[group('build')]
archive:
    rm -rf {{build-dir}}
    xcodebuild archive \
        -scheme {{app}} \
        -destination 'generic/platform=macOS' \
        -archivePath {{build-dir}}/{{app}}.xcarchive

# Export Developer ID-signed .app from archive
[group('build')]
export: archive
    xcodebuild -exportArchive \
        -archivePath {{build-dir}}/{{app}}.xcarchive \
        -exportPath {{build-dir}}/export \
        -exportOptionsPlist ExportOptions.plist
    @echo "Exported: {{build-dir}}/export/{{app}}.app"

# Clean build artifacts
[group('build')]
clean:
    rm -rf {{build-dir}}

# --- Test ---

# Build and run unit tests
[group('test')]
test:
    xcodebuild test \
        -scheme {{app}} \
        -destination 'platform=macOS'

# --- CI ---

# Full local CI gate — run before every push
[group('ci')]
ci: build test

# --- Release ---

# Notarize and staple the exported .app (runs export first)
[group('release-engineering')]
notarize: export
    ditto -c -k --keepParent \
        {{build-dir}}/export/{{app}}.app \
        {{build-dir}}/{{app}}-notarize.zip
    xcrun notarytool submit {{build-dir}}/{{app}}-notarize.zip \
        --keychain-profile "{{notary-profile}}" \
        --wait
    xcrun stapler staple {{build-dir}}/export/{{app}}.app
    @echo "Notarized and stapled."

# Deploy notarized .app to a remote macOS host via rsync
[doc("Operator path: build, notarize, and deploy the companion app to a remote host")]
[group('deploy')]
deploy-agent-macos host deploy_path=deploy-path: notarize
    #!/usr/bin/env bash
    set -euo pipefail
    host="{{host}}"
    app="{{app}}"
    deploy_path="{{deploy_path}}"
    build_dir="{{build-dir}}"

    echo "Stopping ${app} on ${host}..."
    ssh "$host" "pkill -x '${app}' 2>/dev/null || true"
    sleep 2

    echo "Deploying to ${host}:~/${deploy_path}/${app}.app..."
    ssh "$host" "mkdir -p '${deploy_path}' && rm -rf '${deploy_path}/${app}.app'"
    rsync -av \
        "${build_dir}/export/${app}.app" \
        "${host}:${deploy_path}/"
    echo "Deployed."

    echo "Starting ${app} on ${host}..."
    ssh "$host" "open '${deploy_path}/${app}.app'"
    echo "Done."
