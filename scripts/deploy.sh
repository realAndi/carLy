#!/bin/sh
# scripts/deploy.sh — copy the newest packages/*.deb to the phone's /var/mobile/Documents.
#
# This is the only thing the Mac does over ssh to the phone. Everything else happens here:
# edit/commit on the Mac, build with scripts/build-mac.sh, test with scripts/test-mac.sh. The user
# installs the deb on the phone (it needs root): Filza, or `sudo dpkg -i /var/mobile/Documents/<deb>`, then
# `killall CarPlayTemplateUIHost` while CarPlay is connected.
#
# CARLY_PHONE overrides the ssh host (default "iphone"). The path is absolute on purpose: on
# Dopamine the ssh user's home is the rootless /var/jb/var/mobile, which has no Documents folder.
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

deb=$(ls -t packages/*.deb 2>/dev/null | head -n 1)
if [ -z "$deb" ]; then
    echo "no deb in packages/ — run scripts/build-mac.sh first" >&2
    exit 1
fi
DEST=/var/mobile/Documents
scp -q "$deb" "${CARLY_PHONE:-iphone}:$DEST/"
name=$(basename "$deb")
echo "copied $name to $DEST on the phone"
echo "install on the phone:  sudo dpkg -i $DEST/$name && killall CarPlayTemplateUIHost"
