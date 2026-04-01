app           := "thane-agent-macos"
deploy-host   := "pocket.hollowoak.net"
deploy-path   := "/Applications"
build-dir     := "build"

# Set via: export NOTARYTOOL_PROFILE=your-profile-name
notary-profile := env("NOTARYTOOL_PROFILE", "notarytool")

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
[group('release')]
notarize: export
    ditto -c -k --keepParent \
        {{build-dir}}/export/{{app}}.app \
        {{build-dir}}/{{app}}-notarize.zip
    xcrun notarytool submit {{build-dir}}/{{app}}-notarize.zip \
        --keychain-profile "{{notary-profile}}" \
        --wait
    xcrun stapler staple {{build-dir}}/export/{{app}}.app
    @echo "Notarized and stapled."

# Deploy notarized .app to pocket (runs full notarize pipeline first)
[group('release')]
deploy: notarize
    rsync -av --delete \
        {{build-dir}}/export/{{app}}.app \
        {{deploy-host}}:{{deploy-path}}/
    @echo "Deployed to {{deploy-host}}:{{deploy-path}}/{{app}}.app"
    @echo "Restart the app on {{deploy-host}} to pick up the new build."
