# nix-linux-builder — Guest initrd build
# Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
# Apache License 2.0
#
# Builds a minimal CPIO initrd containing:
#   - busybox (static, provides sh/mount/cp/setuidgid/poweroff/ip/etc.)
#   - jq (static, for parsing build.json)
#   - init script (guest/init.sh)
#
# VirtioFS and FUSE are built into the kernel (=y), so no modules or kmod needed.
#
# Output: $out/initrd (uncompressed CPIO archive)
{ pkgs, guestInit }:

let
  busybox = pkgs.pkgsStatic.busybox;
  jq = pkgs.pkgsStatic.jq;
  # Static mke2fs for formatting the /build scratch ext4 image.
  # VirtioFS doesn't honor DAC_OVERRIDE, so we loop-mount an ext4
  # image on VirtioFS to get proper kernel-level permission handling.
  e2fsprogs = pkgs.pkgsStatic.e2fsprogs;

in pkgs.stdenv.mkDerivation {
  pname = "nix-linux-builder-initrd";
  version = "0.1.0";

  # No source tree — we assemble the initrd from packages and the init script
  dontUnpack = true;

  nativeBuildInputs = [ pkgs.cpio ];

  buildPhase = ''
    runHook preBuild

    # Create initrd filesystem layout
    mkdir -p initrd-root/{bin,dev,proc,sys,mnt,tmp}
    mkdir -p initrd-root/nix/store

    # ── busybox (static binary, provides all shell utilities) ─────────
    cp ${busybox}/bin/busybox initrd-root/bin/busybox
    chmod 755 initrd-root/bin/busybox

    # ── jq (static binary, for parsing build.json) ──────────────────
    cp ${jq}/bin/jq initrd-root/bin/jq
    chmod 755 initrd-root/bin/jq

    # ── mke2fs (static, for formatting /build scratch image) ──────
    cp ${e2fsprogs}/bin/mke2fs initrd-root/bin/mke2fs
    chmod 755 initrd-root/bin/mke2fs

    # ── Network setup script (for optional --network support) ─────────
    cat > initrd-root/bin/setup-network <<'NETEOF'
#!/bin/busybox sh
case "$1" in
    bound|renew)
        busybox ip addr add $ip/$mask dev $interface
        [ -n "$router" ] && busybox ip route add default via $router
        ;;
    deconfig)
        busybox ip addr flush dev $interface
        ;;
esac
NETEOF
    chmod 755 initrd-root/bin/setup-network

    # ── Init script ──────────────────────────────────────────────────
    cp ${guestInit} initrd-root/init.script
    chmod 755 initrd-root/init.script
    # Create init symlink (PID 1 entry point)
    ln -sf /init.script initrd-root/init

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out

    # Create CPIO archive (newc format, uncompressed)
    cd initrd-root
    find . -print0 | sort -z | cpio --null -o -H newc --reproducible > $out/initrd

    runHook postInstall
  '';

  meta = {
    description = "Minimal initrd for nix-linux-builder guest VM";
    license = pkgs.lib.licenses.asl20;
    platforms = [ "aarch64-linux" ];
  };
}
