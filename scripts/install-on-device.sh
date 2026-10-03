#!/bin/sh
# Build a Release ParcelPilot and install it on the first connected physical iPhone.
# With a free Personal Team the install expires after 7 days; run this again to renew it.
set -eu
cd "$(dirname "$0")/.."

DEVICE_ID="${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /connected/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')}"
if [ -z "$DEVICE_ID" ]; then
  echo "No connected iPhone found. Plug it in, unlock it and trust this Mac." >&2
  exit 1
fi

echo "Building for ${DEVICE_ID}…"
xcodebuild -project ParcelPilot.xcodeproj -scheme ParcelPilot -configuration Release \
  -destination "id=$DEVICE_ID" -derivedDataPath build/device -allowProvisioningUpdates -quiet build

echo "Installing…"
xcrun devicectl device install app --device "$DEVICE_ID" \
  build/device/Build/Products/Release-iphoneos/ParcelPilot.app
echo "Installed. First time only: Settings → General → VPN & Device Management → trust your Apple ID."
