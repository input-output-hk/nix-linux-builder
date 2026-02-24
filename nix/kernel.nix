# nix-linux-builder — Guest Linux kernel build
# Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
# Apache License 2.0
#
# Builds a minimal Linux ARM64 kernel with only the features needed
# for the nix build VM: VirtioFS, Virtio console, binfmt_misc, tmpfs.
# Everything else (sound, USB, GPU, WiFi, etc.) is disabled.
#
# Output: $out/Image (uncompressed ARM64 kernel, required by Virtualization.framework)
{ pkgs, linuxVersion, linuxSrc }:

let
  # Minimal kernel config for the nix build guest VM.
  # Everything is built-in (=y), no modules. This avoids needing
  # kmod/modprobe in the initrd and speeds up boot.
  kernelConfig = pkgs.writeText "nix-linux-builder-kernel-config" ''
    # ── Base config ───────────────────────────────────────────────────
    CONFIG_LOCALVERSION="-nix-linux-builder"
    CONFIG_DEFAULT_HOSTNAME="nix-builder"
    CONFIG_SYSVIPC=y
    CONFIG_POSIX_MQUEUE=y
    CONFIG_NO_HZ_IDLE=y
    CONFIG_HIGH_RES_TIMERS=y
    CONFIG_PREEMPT_VOLUNTARY=y
    CONFIG_BLK_DEV_INITRD=y
    CONFIG_INITRAMFS_COMPRESSION_NONE=y
    CONFIG_CC_OPTIMIZE_FOR_SIZE=y
    CONFIG_EXPERT=y

    # ── Architecture: ARM64 ───────────────────────────────────────────
    CONFIG_ARM64=y
    CONFIG_64BIT=y

    # ── Filesystems ───────────────────────────────────────────────────
    CONFIG_PROC_FS=y
    CONFIG_PROC_SYSCTL=y
    CONFIG_SYSFS=y
    CONFIG_TMPFS=y
    CONFIG_DEVTMPFS=y
    CONFIG_DEVTMPFS_MOUNT=y

    # VirtioFS (built-in, no module loading needed)
    CONFIG_FUSE_FS=y
    CONFIG_VIRTIO_FS=y
    CONFIG_DAX=y
    CONFIG_DAX_DRIVER=y
    CONFIG_FS_DAX=y

    # ── Virtio (PCI transport for Virtualization.framework) ───────────
    CONFIG_VIRTIO=y
    CONFIG_VIRTIO_PCI=y
    CONFIG_VIRTIO_PCI_LEGACY=y
    CONFIG_VIRTIO_MMIO=y

    # Virtio console (hvc0 for serial output to host)
    CONFIG_VIRTIO_CONSOLE=y
    CONFIG_HVC_DRIVER=y

    # Virtio entropy (guest /dev/random)
    CONFIG_HW_RANDOM=y
    CONFIG_HW_RANDOM_VIRTIO=y

    # Virtio memory balloon
    CONFIG_VIRTIO_BALLOON=y

    # Virtio network (optional, for --network)
    CONFIG_VIRTIO_NET=y
    CONFIG_NET=y
    CONFIG_INET=y
    CONFIG_PACKET=y
    CONFIG_UNIX=y

    # ── binfmt_misc (for Rosetta x86_64 emulation) ───────────────────
    CONFIG_BINFMT_ELF=y
    CONFIG_BINFMT_SCRIPT=y
    CONFIG_BINFMT_MISC=y

    # ── TTY / Console ─────────────────────────────────────────────────
    CONFIG_TTY=y
    CONFIG_VT=n
    CONFIG_SERIAL_EARLYCON=y
    CONFIG_PRINTK=y

    # ── Disable everything we don't need ──────────────────────────────
    CONFIG_SOUND=n
    CONFIG_DRM=n
    CONFIG_USB_SUPPORT=n
    CONFIG_WLAN=n
    CONFIG_BLUETOOTH=n
    CONFIG_INPUT_KEYBOARD=n
    CONFIG_INPUT_MOUSE=n
    CONFIG_INPUT_TOUCHSCREEN=n
    CONFIG_HWMON=n
    CONFIG_THERMAL=n
    CONFIG_MEDIA_SUPPORT=n
    CONFIG_LOGO=n
    CONFIG_FB=n
    CONFIG_FRAMEBUFFER_CONSOLE=n
    CONFIG_WIRELESS=n
    CONFIG_NFS_FS=n
    CONFIG_CIFS=n
    CONFIG_SECURITY_SELINUX=n
    CONFIG_SECURITY_APPARMOR=n
    CONFIG_AUDIT=n
    CONFIG_PROFILING=n
    CONFIG_DEBUG_INFO=n
    CONFIG_FTRACE=n
    CONFIG_CRYPTO_HW=n

    # ── PCI (required by virtio-pci) ──────────────────────────────────
    CONFIG_PCI=y
    CONFIG_PCI_HOST_GENERIC=y

    # ── Block layer ────────────────────────────────────────────────────
    CONFIG_BLOCK=y
    CONFIG_BLK_DEV=y
    CONFIG_BLK_DEV_LOOP=y

    # ext4 filesystem for the /build scratch space.
    # VirtioFS doesn't honor DAC_OVERRIDE (guest root is not host root),
    # so tools like rsync -a that preserve nix-store 555 permissions
    # create unwritable directories. We use a loop-mounted ext4 image
    # on VirtioFS instead — ext4 respects kernel capabilities normally.
    CONFIG_EXT4_FS=y

    # ── EFI stub (not needed, Virtualization.framework uses direct boot)
    CONFIG_EFI=n

    # ── Multiuser support ─────────────────────────────────────────────
    CONFIG_MULTIUSER=y
  '';

in pkgs.stdenv.mkDerivation {
  pname = "nix-linux-builder-kernel";
  version = linuxVersion;
  src = linuxSrc;

  depsBuildBuild = [ pkgs.stdenv.cc ];
  nativeBuildInputs = with pkgs; [
    bc
    bison
    flex
    perl
    openssl
    elfutils
    ncurses
    pkg-config
  ];

  # Generate .config from our minimal config fragment
  configurePhase = ''
    runHook preConfigure

    # Start with the default ARM64 defconfig, then overlay our settings
    make ARCH=arm64 defconfig

    # Apply our minimal config on top
    scripts/kconfig/merge_config.sh -m .config ${kernelConfig}

    # Resolve any unset config symbols
    make ARCH=arm64 olddefconfig

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild

    # Build the uncompressed kernel Image (required by Virtualization.framework)
    make ARCH=arm64 -j$NIX_BUILD_CORES Image

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out
    cp arch/arm64/boot/Image $out/Image
    cp System.map $out/System.map

    runHook postInstall
  '';

  # Don't strip the kernel image
  dontStrip = true;

  meta = {
    description = "Minimal Linux ARM64 kernel for nix-linux-builder guest VM";
    license = pkgs.lib.licenses.gpl2Only;
    platforms = [ "aarch64-linux" ];
  };
}
