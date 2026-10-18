#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <test-binary>" >&2
    exit 2
fi

test_binary=$1
test_root=$(mktemp -d "${TMPDIR:-/tmp}/nlb-case-volume.XXXXXX")
insensitive_image="$test_root/insensitive.sparsebundle"
sensitive_image="$test_root/sensitive.sparsebundle"
insensitive_mount="$test_root/insensitive"
sensitive_mount="$test_root/sensitive"
insensitive_device=
sensitive_device=

cleanup() {
    if [ -n "$sensitive_device" ]; then
        hdiutil detach -quiet "$sensitive_device" || true
    fi
    if [ -n "$insensitive_device" ]; then
        hdiutil detach -quiet "$insensitive_device" || true
    fi
    rm -rf "$test_root"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$insensitive_mount" "$sensitive_mount"
hdiutil create -quiet -size 64m -fs APFS -volname NLBInsensitive \
    -type SPARSEBUNDLE "$insensitive_image"
hdiutil create -quiet -size 64m -fs "Case-sensitive APFS" -volname NLBSensitive \
    -type SPARSEBUNDLE "$sensitive_image"

insensitive_attach=$(hdiutil attach -nobrowse -mountpoint "$insensitive_mount" \
    "$insensitive_image")
insensitive_device=$(printf '%s\n' "$insensitive_attach" | awk 'NR == 1 { print $1 }')
sensitive_attach=$(hdiutil attach -nobrowse -mountpoint "$sensitive_mount" \
    "$sensitive_image")
sensitive_device=$(printf '%s\n' "$sensitive_attach" | awk 'NR == 1 { print $1 }')

if [ -z "$insensitive_device" ] || [ -z "$sensitive_device" ]; then
    echo "could not identify attached test disk images for cleanup" >&2
    exit 1
fi

"$test_binary" "$insensitive_mount" "$sensitive_mount"
