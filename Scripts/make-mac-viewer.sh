#!/bin/bash
# Builds "RCL Viewer.app": the iPhone and iPad app, run on a Mac with Apple silicon as "Designed for
# iPad", to see and use another Mac from this one (#129: a MacBook watching a headless Mac mini).
# Nothing new to maintain: it is the same client, the same pairing and the same remote access.
#
#   Scripts/make-mac-viewer.sh            .build/RCL Viewer.app
#   Scripts/make-mac-viewer.sh --install  …then ~/Applications/RCL Viewer.app
#
# Signed with your Apple Development identity and team (the project's DEVELOPMENT_TEAM), so it runs
# on Macs registered to that team. The bundle Xcode makes for an iOS app has to sit inside a wrapper
# (Wrapper/ and a WrappedBundle link) for macOS to launch it, as the App Store installs such apps.
set -euo pipefail
cd "$(dirname "$0")/.."
install=0; [ "${1:-}" = "--install" ] && install=1
dd=.build/mac-viewer
xcodebuild -project iOSClient/Sill.xcodeproj -scheme Sill -configuration Release \
    -destination "platform=macOS,arch=arm64,variant=Designed for iPad" -derivedDataPath "$dd" \
    -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic build -quiet
app=".build/RCL Viewer.app"
rm -rf "$app"; mkdir -p "$app/Wrapper"
cp -R "$dd/Build/Products/Release-iphoneos/Sill.app" "$app/Wrapper/"
ln -s Wrapper/Sill.app "$app/WrappedBundle"
echo "Built $app"
if [ "$install" = 1 ]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/"RCL Viewer.app"
    cp -R "$app" ~/Applications/
    echo "Installed ~/Applications/RCL Viewer.app"
fi
