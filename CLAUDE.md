# nix-linux-builder

Open-source external builder for nix on macOS, using Apple Virtualization.framework.
Open-source alternative to the QEMU-based nix-darwin linux-builder.

## Architecture
- Pure C for CLI parsing and JSON handling (src/cli.c, src/build_json.c)
- Objective-C for Virtualization.framework integration (src/vm_config.m, src/vm_lifecycle.m)
- Minimal guest Linux kernel + initrd built with Nix (nix/kernel.nix, nix/initrd.nix)
- Guest init script in busybox sh (guest/init.sh)

## Protocol
- nix daemon writes `build.json` to `topTmpDir/` and exec's the builder with path as last arg
- Builder boots Linux VM with VirtioFS shares for /nix/store and buildroot
- Guest init parses build.json, sets up environment, signals `\2\n` on hvc0/stdout
- Guest detects host UID from VirtioFS mount, runs builder as that UID
- Exit code written to `topTmpDir/.exitcode`
- Host reads exit code and exits accordingly

## Build
- `nix develop -c make` to build and sign the host binary
- `nix build .#guest-kernel` for the Linux kernel
- `nix build .#guest-initrd` for the initrd
- Requires macOS with Apple Silicon (Virtualization.framework)

## Key Dependencies
- cJSON (vendored or from nixpkgs) for JSON parsing
- Apple Virtualization.framework (macOS 13+)
- Linux 6.1.x kernel with VirtioFS support
- busybox + jq for guest userspace

## VirtioFS UID Mapping
Apple's VirtioFS preserves host UIDs. macOS nix build users have UIDs 351-382
(not 30000). The guest init detects the actual UID by stat-ing the VirtioFS-mounted
build directory and patches /etc/passwd to match. This is essential for:
- Write access to the build scratch directory (mode 700)
- Correct file ownership in build outputs

## VirtioFS DAC_OVERRIDE Limitation
Apple's VirtioFS doesn't honor Linux DAC_OVERRIDE: guest root (UID 0) has no
special privileges on the host filesystem. Operations are performed as the host's
build user (nixbld). This means tools like `rsync -a` that preserve nix-store 555
(read-only) directory permissions create truly unwritable directories on VirtioFS.

**Solution**: /build uses a loop-mounted ext4 image stored on VirtioFS. The ext4
filesystem handles permissions within the guest kernel where DAC_OVERRIDE works
normally, while the underlying image file is host-disk-backed (no RAM limit).
The user namespace approach (feature/user-namespace-sandbox) does NOT fix this
because the host-side `mkdir()` still runs as the unprivileged nixbld user.

## Known Limitations
- x86_64-linux GHC builds fail under Rosetta: patchelf creates sub-0x400000 LOAD
  segments in ET_EXEC (non-PIE) ghc-binary binaries that Rosetta can't map correctly.
  Workaround: invoke via `ld-linux-x86-64.so.2` directly. Not a practical blocker
  since ghc-binary comes from cache.nixos.org (never needs to run locally).
  Only affects ghc-binary; all other patchelf'd binaries (PIE/ET_DYN) work fine.
