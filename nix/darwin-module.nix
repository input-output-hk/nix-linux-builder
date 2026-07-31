# nix-linux-builder — nix-darwin module
# Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
# Apache License 2.0
#
# Import this module in your nix-darwin configuration to enable
# nix-linux-builder as an external builder for Linux derivations.
#
# Usage in flake.nix:
#   inputs.nix-linux-builder.url = "github:input-output-hk/nix-linux-builder";
#   # then in darwinConfigurations modules:
#   nix-linux-builder.darwinModules.default
#   { services.nix-linux-builder.enable = true; }
#
{ self }:

{ config, lib, pkgs, ... }:

let
  cfg = config.services.nix-linux-builder;

  builder = self.packages.aarch64-darwin.nix-linux-builder;

  # Use prebuilt guest components (fetched on macOS, no linux builder needed)
  # when available. Falls back to building from source (requires an existing
  # aarch64-linux builder, e.g. a remote builder or previous bootstrap).
  hasPrebuilt = self.prebuiltGuest != null;
  usePrebuilt = cfg.usePrebuilt && hasPrebuilt;

  guest-kernel =
    if usePrebuilt
    then self.prebuiltGuest.guest-kernel
    else self.packages.aarch64-linux.guest-kernel;

  guest-initrd =
    if usePrebuilt
    then self.prebuiltGuest.guest-initrd
    else self.packages.aarch64-linux.guest-initrd;

  # The store binary is used directly: it is signed in the derivation's
  # postFixup with the com.apple.security.virtualization entitlement, which
  # survives stdenv's fixup re-signing (see flake.nix).  Earlier versions
  # copied it to /usr/local/lib and re-signed it at activation, because a
  # signature applied in installPhase was replaced by fixup and the entitlement
  # was lost.  Signing after fixup removes the need for that copy — and for
  # any activation script that re-signs a store path in place, which mutates
  # the path's content and permanently breaks `nix-store --verify` and any
  # attempt to copy it to another machine.
  builderBin = "${builder}/bin/nix-linux-builder";

  # Build the args list from module options.
  builderArgs = lib.concatLists [
    [ "--kernel" "${guest-kernel}/Image" ]
    [ "--initrd" "${guest-initrd}/initrd" ]
    (lib.optional (cfg.memorySize != null)
      [ "--memory-size" (toString cfg.memorySize) ])
    (lib.optional (cfg.cpuCount != null)
      [ "--cpu-count" (toString cfg.cpuCount) ])
    (lib.optional (cfg.timeout != 0)
      [ "--timeout" (toString cfg.timeout) ])
    (lib.optional cfg.network [ "--network" ])
    (lib.optional cfg.ramdiskTmp [ "--ramdisk-tmp" ])
    (lib.optional cfg.verbose [ "--verbose" ])
  ];
  # nix-linux-shell wrapper: substitutes kernel/initrd/builder paths
  # so users can interactively debug Linux builds without knowing
  # the store paths of guest components.
  # Uses writeShellApplication to declare runtime dependencies (jq)
  # and get shellcheck validation at build time.
  nixLinuxShellText =
    builtins.replaceStrings
      [ "@kernel@" "@initrd@" "@builder@" ]
      [ "${guest-kernel}/Image" "${guest-initrd}/initrd" builderBin ]
      (builtins.readFile ../scripts/nix-linux-shell);

  nixLinuxShell = pkgs.writeShellApplication {
    name = "nix-linux-shell";
    runtimeInputs = [ pkgs.jq ];
    # The script already has set -euo pipefail and a shebang;
    # writeShellApplication prepends its own, so the originals
    # become harmless comments/no-ops in the body.
    text = nixLinuxShellText;
  };
in {
  options.services.nix-linux-builder = {
    enable = lib.mkEnableOption "nix-linux-builder external builder for Linux derivations";

    usePrebuilt = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Use pre-built guest kernel and initrd from GitHub releases.
        This avoids the chicken-and-egg problem of needing an aarch64-linux
        builder to build the guest components that provide the builder.
        Set to false to build from source (requires an aarch64-linux builder).
      '';
    };

    systems = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "aarch64-linux" "x86_64-linux" ];
      description = "Linux systems this builder handles.";
    };

    memorySize = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "VM memory in bytes. Defaults to 8 GiB if unset.";
    };

    cpuCount = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Number of vCPUs. Defaults to host CPU count if unset.";
    };

    timeout = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "Build timeout in seconds. 0 means unlimited.";
    };

    network = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable NAT networking in the guest VM.
        Required for fixed-output derivations (fetchgit, fetchurl, etc.)
        that need network access during build. The nix external-builder
        protocol does not indicate whether a derivation needs network,
        so networking is enabled unconditionally.
      '';
    };

    ramdiskTmp = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use tmpfs for /tmp instead of VirtioFS (faster, limited by RAM).";
    };

    verbose = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable verbose debug logging.";
    };
  };

  config = lib.mkIf cfg.enable {
    # No activation script: the store binary already carries the
    # com.apple.security.virtualization entitlement (signed in postFixup), so
    # Virtualization.framework starts VMs straight from the store path.

    # Install nix-linux-shell wrapper for interactive debugging.
    environment.systemPackages = [ nixLinuxShell ];

    nix.settings = {
      extra-experimental-features = [ "external-builders" ];
      external-builders = builtins.toJSON [
        {
          systems = cfg.systems;
          program = builderBin;
          args = lib.flatten builderArgs;
        }
      ];
    };
  };
}
