# nix-linux-builder — Open-source Linux VM builder for nix on macOS
# Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
# Apache License 2.0
{
  description = "Open-source Linux VM builder for nix on macOS using Virtualization.framework";

  inputs = {
    # 25.05 ships apple-sdk-14.4 which includes Virtualization.framework
    # headers (VirtioFS, Rosetta, etc). The 24.11 SDK 11.3 is too old.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs }:
    let
      # Host system (macOS on Apple Silicon)
      darwinSystem = "aarch64-darwin";
      # Guest system (Linux on ARM64)
      linuxSystem = "aarch64-linux";

      darwinPkgs = nixpkgs.legacyPackages.${darwinSystem};
      linuxPkgs = nixpkgs.legacyPackages.${linuxSystem};

      # cJSON source (single-file C JSON library)
      cjson-src = darwinPkgs.fetchFromGitHub {
        owner = "DaveGamble";
        repo = "cJSON";
        rev = "v1.7.18";
        sha256 = "sha256-UgUWc/+Zie2QNijxKK5GFe4Ypk97EidG8nTiiHhn5Ys=";
      };

      # Unity test framework (single-file C test runner)
      unity-src = darwinPkgs.fetchFromGitHub {
        owner = "ThrowTheSwitch";
        repo = "Unity";
        rev = "v2.6.1";
        sha256 = "sha256-g0ubq7RxGQmL1R6vz9RIGJpVWYsgrZhsTWSrL1ySEug=";
      };

      # Linux kernel version for the guest
      linuxVersion = "6.1.128";
      linuxSrc = darwinPkgs.fetchurl {
        url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${linuxVersion}.tar.xz";
        sha256 = "sha256-h01n0xgVcOaaxrM4U/BEjwX8kNTPPkuqrcSpzt58UPM=";
      };

    in {
      # ── Host binary (macOS) ─────────────────────────────────────────────
      # Uses the system Xcode SDK because Virtualization.framework requires
      # macOS 13+ headers (VirtioFS, Rosetta, etc.) not present in the
      # nixpkgs Apple SDK 11.3.
      packages.${darwinSystem} = {
        default = self.packages.${darwinSystem}.nix-linux-builder;

        nix-linux-builder = darwinPkgs.stdenv.mkDerivation {
          pname = "nix-linux-builder";
          version = "0.1.0";
          src = ./.;

          nativeBuildInputs = [
            darwinPkgs.gnumake
            darwinPkgs.darwin.sigtool  # provides codesign in sandbox
          ];

          buildInputs = [
            darwinPkgs.apple-sdk_14
          ];

          # Vendor cJSON into the source tree before building
          preBuild = ''
            mkdir -p src/cjson
            cp ${cjson-src}/cJSON.c src/cjson/cJSON.c
            cp ${cjson-src}/cJSON.h src/cjson/cJSON.h
            mkdir -p tests/unity
            cp ${unity-src}/src/unity.c tests/unity/unity.c
            cp ${unity-src}/src/unity.h tests/unity/unity.h
            cp ${unity-src}/src/unity_internals.h tests/unity/unity_internals.h
          '';

          buildPhase = ''
            runHook preBuild
            make build
            runHook postBuild
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp .build/nix-linux-builder $out/bin/
            codesign --sign - --entitlements entitlements.plist --force $out/bin/nix-linux-builder
          '';

          meta = {
            description = "Open-source Linux VM builder for nix on macOS";
            license = nixpkgs.lib.licenses.asl20;
            platforms = [ "aarch64-darwin" ];
          };
        };
      };

      # ── Guest components (Linux) ────────────────────────────────────────
      packages.${linuxSystem} = {
        guest-kernel = import ./nix/kernel.nix {
          pkgs = linuxPkgs;
          inherit linuxVersion linuxSrc;
        };

        guest-initrd = import ./nix/initrd.nix {
          pkgs = linuxPkgs;
          guestInit = ./guest/init.sh;
        };
      };

      # ── nix-darwin module ────────────────────────────────────────────────
      darwinModules.default = import ./nix/darwin-module.nix { inherit self; };

      # ── Development shell (macOS) ───────────────────────────────────────
      # Minimal shell: just vendor cJSON and point to the system SDK.
      # We intentionally avoid pulling in nixpkgs Apple SDK frameworks.
      devShells.${darwinSystem}.default = darwinPkgs.mkShellNoCC {
        buildInputs = let llvmPkgs = darwinPkgs.llvmPackages; in [
          darwinPkgs.clang-tools    # clang-tidy, scan-build
          llvmPkgs.clang            # LLVM clang with libFuzzer for fuzz target
        ];
        shellHook = ''
          # Use system Xcode SDK and system clang for Virtualization.framework.
          # The nixpkgs Apple SDK 11.3 predates VirtioFS/Rosetta classes.
          export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
          unset SDKROOT
          export SDKROOT=$(/usr/bin/xcrun --show-sdk-path)
          export CC=/usr/bin/clang
          export OBJC=/usr/bin/clang

          if [ ! -f src/cjson/cJSON.c ]; then
            mkdir -p src/cjson
            cp ${cjson-src}/cJSON.c src/cjson/cJSON.c
            cp ${cjson-src}/cJSON.h src/cjson/cJSON.h
            echo "Vendored cJSON into src/cjson/"
          fi

          # Export LLVM clang path for the fuzz target (Apple clang lacks libFuzzer).
          export FUZZ_CC="${darwinPkgs.llvmPackages.clang}/bin/clang"

          if [ ! -f tests/unity/unity.c ]; then
            mkdir -p tests/unity
            cp ${unity-src}/src/unity.c tests/unity/unity.c
            cp ${unity-src}/src/unity.h tests/unity/unity.h
            cp ${unity-src}/src/unity_internals.h tests/unity/unity_internals.h
            echo "Vendored Unity test framework into tests/unity/"
          fi
        '';
      };
    };
}
