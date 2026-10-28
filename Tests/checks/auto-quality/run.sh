#!/bin/bash
# AutoQuality (iOSClient/AutoQuality.swift, RCL): when the device lowers the Mac's quality by itself
# and brings it back, compiled with StreamProtocol's HostSettings.swift.
#   Tests/checks/auto-quality/run.sh   compile and run the check
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
swiftc -O iOSClient/AutoQuality.swift Sources/StreamProtocol/HostSettings.swift "$here/main.swift" -o "$out/check"
"$out/check"
