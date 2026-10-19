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
    status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$sensitive_device" ]; then
        if ! hdiutil detach -quiet "$sensitive_device"; then
            echo "could not detach owned test image $sensitive_device; preserving $test_root" >&2
            status=1
        fi
    fi
    if [ -n "$insensitive_device" ]; then
        if ! hdiutil detach -quiet "$insensitive_device"; then
            echo "could not detach owned test image $insensitive_device; preserving $test_root" >&2
            status=1
        fi
    fi
    if [ "$status" -eq 0 ]; then
        rm -rf "$test_root"
    else
        echo "test artifacts were kept for manual cleanup: $test_root" >&2
    fi
    exit "$status"
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
