#!/bin/busybox sh
# nix-linux-builder — Guest init script
# Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
# Apache License 2.0
#
# This runs as PID 1 inside the initramfs. It:
#   1. Sets up a tmpfs root with minimal userspace
#   2. Mounts VirtioFS shares (nix-store, buildroot)
#   3. Parses build.json for builder, args, env, system
#   4. Optionally enables Rosetta for x86_64-linux builds
#   5. switch_root's into a generated init that runs the actual builder
#
# The generated post-switch_root init:
#   - Emits \2\n on hvc0 (stdout) to signal nix it can read build output
#   - Runs the builder as nixbld (UID detected from VirtioFS)
#   - Writes exit code to /build-info/.exitcode
#   - Powers off the VM
set -eux

# ── Cleanup: always power off on exit ─────────────────────────────────────

cleanup() {
    exec busybox poweroff -f
}
trap cleanup EXIT

# ── Clock fix ─────────────────────────────────────────────────────────────
# The VM clock can be slightly wrong, breaking tools like meson that
# do strict timestamp checks.
busybox date -u -s @"$(($(busybox date +%s) + 1))"

# ── Set up tmpfs root ─────────────────────────────────────────────────────

busybox mkdir -p /mnt/root
busybox mount -t tmpfs tmpfs /mnt/root

busybox mkdir -p /mnt/root/root
busybox mkdir -p /mnt/root/var/empty
busybox chmod 555 /mnt/root/var/empty
busybox mkdir -p /mnt/root/etc

# Minimal /etc/passwd and /etc/group for the nix build user.
# The actual UID/GID are determined later from the VirtioFS mount
# (see "Detect build user UID" section below) and patched in.
busybox cat >/mnt/root/etc/passwd <<EOF
root:!:0:0:System administrator:/root:
nixbld:x:NIXBLD_UID:NIXBLD_GID:Nix build user:/var/empty:
EOF

busybox cat >/mnt/root/etc/group <<EOF
root:x:0:
nixbld:x:NIXBLD_GID:
EOF

# Minimal nsswitch.conf — ensures NSS uses files, not NIS/LDAP/systemd.
# Some glibc-based builders call getpwnam() which consults nsswitch.conf.
busybox cat >/mnt/root/etc/nsswitch.conf <<EOF
passwd: files
group:  files
shadow: files
EOF

# Mount essential pseudo-filesystems
busybox mkdir -p /mnt/root/proc
busybox mount -t proc none /mnt/root/proc

busybox mkdir -p /mnt/root/dev
busybox mount -t devtmpfs devtmpfs /mnt/root/dev

busybox mkdir -p /mnt/root/tmp
# Default: /tmp via VirtioFS (host disk, no RAM limit).
# With --ramdisk-tmp: /tmp via tmpfs (fast, limited to VM RAM).
# Note: /proc is mounted at /mnt/root/proc (line 65), not /proc.
if busybox grep -q ramdisk_tmp /mnt/root/proc/cmdline 2>/dev/null; then
    busybox mount -t tmpfs tmpfs /mnt/root/tmp
else
    busybox mkdir -p /mnt/root/build-info/tmp
    busybox mount --bind /mnt/root/build-info/tmp /mnt/root/tmp
fi

busybox mkdir -p /mnt/root/dev/shm
busybox mount -t tmpfs tmpfs /mnt/root/dev/shm -o rw,nosuid,nodev

# Copy busybox into the new root (the initramfs will be freed by switch_root)
busybox mkdir -p /mnt/root/bin
busybox cp /bin/busybox /mnt/root/bin/busybox
busybox ln -sf ./busybox /mnt/root/bin/sh

# ── Networking (optional, only if eth0 exists) ────────────────────────────

busybox ip link set lo up

if busybox ip link show eth0 2>/dev/null; then
    busybox mkdir -p /mnt/root/etc
    echo "nameserver 8.8.8.8" > /mnt/root/etc/resolv.conf
    echo "nameserver 8.8.4.4" >> /mnt/root/etc/resolv.conf
    busybox ip link set eth0 up
    busybox udhcpc -i eth0 -s /bin/setup-network
fi

# ── Mount VirtioFS shares ─────────────────────────────────────────────────
# VirtioFS and FUSE are built into the kernel (=y), no module loading needed.

# nix-store: host /nix/store mounted read-write.
# The nix daemon ensures only the build user's scratch paths are writable.
busybox mkdir -p /mnt/root/nix/store
busybox mount -t virtiofs nix-store /mnt/root/nix/store

# buildroot: host topTmpDir, contains build.json.
# The guest writes .exitcode here on completion.
busybox mkdir -p /mnt/root/build-info
busybox mount -t virtiofs buildroot /mnt/root/build-info

# /build is the scratch space (TMPDIR) for the nix builder.
# We use a loop-mounted ext4 image on VirtioFS instead of direct VirtioFS
# because Apple's VirtioFS doesn't honor DAC_OVERRIDE: guest root is not
# host root, so operations are permission-checked as the host's build user.
# This breaks tools like rsync -a that preserve nix-store 555 (read-only)
# directory permissions — root can't create files inside 555 dirs on VirtioFS.
# With ext4 via loop mount, the kernel handles permissions normally and root
# has full DAC_OVERRIDE while still using host disk for storage (no RAM limit).
busybox mkdir -p /mnt/root/build

# Create a sparse ext4 image on VirtioFS. The image is sparse so it uses
# only as much host disk as the build actually writes (not the full 200G).
BUILD_IMG="/mnt/root/build-info/build.img"
busybox truncate -s 200G "$BUILD_IMG"
/bin/mke2fs -t ext4 -m 0 -q "$BUILD_IMG" 2>&1

# Set up loop device and mount. We use losetup + explicit mount rather than
# mount -o loop because the loop device node may not exist yet in the early
# initramfs environment.
# mknod may fail if /dev/loop0 already exists (devtmpfs) — that's fine.
busybox mknod -m 660 /dev/loop0 b 7 0 2>/dev/null || true
# losetup and mount are protected by set -e: failure aborts the script.
busybox losetup /dev/loop0 "$BUILD_IMG"
busybox mount -t ext4 /dev/loop0 /mnt/root/build

# Copy the initial build files from VirtioFS to the ext4 filesystem.
# The nix daemon places env-vars and .attr-* in topTmpDir/build/ which
# the builder (stdenv) needs to read.
busybox cp -a /mnt/root/build-info/build/. /mnt/root/build/

# ── Detect build user UID/GID from the VirtioFS mount ──────────────────
# VirtioFS preserves host UIDs. The nix daemon creates the build directory
# owned by the build user (e.g., _nixbld1 UID 351 on macOS). We detect
# the actual UID/GID from the VirtioFS source (build-info/build/) BEFORE
# it's overlaid by the ext4 loop mount. This ensures setuidgid drops to
# the correct UID that owns the host-side build directory.
BUILD_UID=$(busybox stat -c '%u' /mnt/root/build-info/build)
BUILD_GID=$(busybox stat -c '%g' /mnt/root/build-info/build)

# Validate that stat returned numeric values (defends against busybox quirks).
case "$BUILD_UID" in
    ''|*[!0-9]*) echo "ERROR: non-numeric BUILD_UID: '$BUILD_UID'" >&2; exit 1 ;;
esac
case "$BUILD_GID" in
    ''|*[!0-9]*) echo "ERROR: non-numeric BUILD_GID: '$BUILD_GID'" >&2; exit 1 ;;
esac

busybox sed -i "s/NIXBLD_UID/$BUILD_UID/g; s/NIXBLD_GID/$BUILD_GID/g" /mnt/root/etc/passwd
busybox sed -i "s/NIXBLD_GID/$BUILD_GID/g" /mnt/root/etc/group

# Set ownership on the ext4 /build so the builder (run via setuidgid) can write.
# This is a no-op when BUILD_UID=0, but necessary when VirtioFS reports a non-zero UID.
busybox chown "$BUILD_UID:$BUILD_GID" /mnt/root/build

# ── Parse build.json ──────────────────────────────────────────────────────

BUILD_JSON="/mnt/root/build-info/build.json"
if [ ! -r "$BUILD_JSON" ]; then
    echo "build.json not found or not readable at $BUILD_JSON" >&2
    exit 1
fi

# Mount proc in initramfs context (for binfmt_misc below)
busybox mkdir -p /proc
busybox mount -t proc none /proc

# jq failures are caught by set -e — script aborts if build.json is malformed.
system="$(jq -r .system "$BUILD_JSON")"

# ── Rosetta setup (x86_64-linux only) ────────────────────────────────────
# On Apple Silicon, the VM runs an aarch64 kernel. For x86_64-linux builds,
# we use Apple's Rosetta 2 via binfmt_misc to transparently translate
# x86_64 ELF binaries.

if [ "$system" = "x86_64-linux" ]; then
    busybox mount -t binfmt_misc none /proc/sys/fs/binfmt_misc

    # The rosetta VirtioFS share provides the Rosetta binary translator.
    # The 'F' flag means the interpreter is opened at registration time,
    # so it's available even after switch_root (the initramfs is freed).
    busybox mkdir -p /rosetta
    busybox mount -t virtiofs rosetta /rosetta
    # Register Rosetta as binfmt handler for x86_64 ELF binaries.
    # Redirect failure is caught by set -e (e.g., if binfmt_misc not mounted).
    echo ':rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/rosetta/rosetta:POCF' > /proc/sys/fs/binfmt_misc/register
fi

# ── Extract builder command and environment ───────────────────────────────

# jq failures are caught by set -e — script aborts if build.json is malformed.
builder="$(jq -r '.builder' "$BUILD_JSON")"
# Build args as a shell-safe string for the generated init
args_str="$(jq -r '.args | map(@sh) | join(" ")' "$BUILD_JSON")"
# Export environment variables to a sourceable file
jq -r '.env | to_entries[] | "\(.key)=\(.value | @sh)"' "$BUILD_JSON" > /mnt/root/execenv
busybox chmod 400 /mnt/root/execenv

# ── Generate post-switch_root init ────────────────────────────────────────
# This script runs as PID 1 after switch_root. It emits the \2\n signal
# that tells nix to start reading build output, then runs the builder.

busybox cat > /mnt/root/init <<INITEOF
#!/bin/busybox env -i /bin/sh
set -eux

cleanup() {
    exec /bin/busybox poweroff -f
}
trap cleanup EXIT

# Remove ourselves (we're in tmpfs, no longer needed)
/bin/busybox rm /init
/bin/busybox ln -sf /proc/self/fd /dev/fd

cd /build

set +x
# Signal nix that build output starts now.
# \2 (STX) on a line by itself tells the nix daemon to start
# capturing everything after this as build log output.
/bin/busybox printf '\2\n'

# Source the environment variables extracted from build.json
set -a
. /execenv
set +a
/bin/busybox rm /execenv

# Run the actual builder as the nix build user.
# The nixbld UID matches the host's build user (detected from VirtioFS).
# stdin is /dev/null because nix builds are non-interactive.
# Note: $builder is a nix store path (no shell metacharacters) — safe to use unquoted.
set +e
/bin/busybox setuidgid nixbld $builder $args_str < /dev/null
echo \$? > /build-info/.exitcode
INITEOF

busybox chmod 500 /mnt/root/init

# Silence kernel messages during the build
echo 0 > /proc/sys/kernel/printk

# ── Switch root ───────────────────────────────────────────────────────────
# Replace the initramfs with our tmpfs root. The kernel frees all initramfs
# pages and pivots to /mnt/root, running /init as the new PID 1.
exec busybox switch_root /mnt/root /init
