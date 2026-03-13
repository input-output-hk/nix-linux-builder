# nix-linux-builder

Open-source Linux builder for [Nix](https://nixos.org) on macOS, using Apple's
[Virtualization.framework](https://developer.apple.com/documentation/virtualization).

Boots a lightweight Linux VM on Apple Silicon to execute `aarch64-linux` and
`x86_64-linux` (via Rosetta) derivations natively. Open-source alternative to
the QEMU-based nix-darwin linux-builder.

## Requirements

| Requirement | Minimum |
|---|---|
| **Hardware** | Apple Silicon Mac (M1 or later) |
| **macOS** | 13.0 Ventura or later |
| **Xcode** | 15.0+ with Command Line Tools |
| **Nix** | 2.32.0 or later (introduces `external-builders` experimental feature) |

Nix 2.32.0 ([release notes](https://nix.dev/manual/nix/2.32/release-notes/rl-2.32.html))
added the `external-builders` feature ([PR #14145](https://github.com/NixOS/nix/pull/14145))
which defines the JSON-based protocol this builder implements.

## Quick Start

### 1. Build

The nix-darwin module (below) handles everything automatically, including
fetching pre-built guest kernel and initrd from GitHub releases. No
aarch64-linux builder needed for initial setup.

To build from source instead:

```bash
# Build the host binary (macOS)
nix build .#nix-linux-builder

# Build the guest kernel and initrd (requires aarch64-linux builder)
nix build .#packages.aarch64-linux.guest-kernel
nix build .#packages.aarch64-linux.guest-initrd
```

### 2. Configure Nix

#### nix-darwin module (recommended)

The flake provides a `darwinModules.default` that handles everything:

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nix-darwin.url = "github:LnL7/nix-darwin";
    nix-linux-builder.url = "github:input-output-hk/nix-linux-builder";
  };

  outputs = { nixpkgs, nix-darwin, nix-linux-builder, ... }: {
    darwinConfigurations.my-mac = nix-darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      modules = [
        nix-linux-builder.darwinModules.default
        {
          services.nix-linux-builder.enable = true;

          # Optional settings (showing defaults):
          # services.nix-linux-builder.usePrebuilt = true;  # fetch from GitHub releases
          # services.nix-linux-builder.systems = [ "aarch64-linux" "x86_64-linux" ];
          # services.nix-linux-builder.memorySize = null;  # 8 GiB default
          # services.nix-linux-builder.cpuCount = null;    # host CPU count
          # services.nix-linux-builder.timeout = 0;        # unlimited
          # services.nix-linux-builder.network = false;
          # services.nix-linux-builder.ramdiskTmp = false;
          # services.nix-linux-builder.verbose = false;
        }
      ];
    };
  };
}
```

#### Manual (nix.conf)

Add to `/etc/nix/nix.conf`:

```ini
extra-experimental-features = external-builders

external-builders = [{"systems": ["aarch64-linux", "x86_64-linux"], "program": "/path/to/nix-linux-builder", "args": ["--kernel", "/path/to/guest-kernel/Image", "--initrd", "/path/to/guest-initrd/initrd"]}]
```

Then restart the Nix daemon:

```bash
sudo launchctl stop org.nixos.nix-daemon
sudo launchctl start org.nixos.nix-daemon
```

### 3. Test

```bash
# Build a simple Linux package (aarch64-linux, native)
nix build nixpkgs#legacyPackages.aarch64-linux.hello

# Build a simple Linux package (x86_64-linux, via Rosetta)
nix build nixpkgs#legacyPackages.x86_64-linux.hello
```

## Bootstrapping (Pre-built Guest Components)

The guest kernel and initrd are aarch64-linux derivations, but you need this
builder to build aarch64-linux derivations -- a chicken-and-egg problem.

The module solves this by default (`usePrebuilt = true`): it fetches pre-built
kernel and initrd binaries from [GitHub Releases](https://github.com/input-output-hk/nix-linux-builder/releases)
using `fetchurl` on macOS. No aarch64-linux builder is needed for initial setup.

To build from source instead (e.g., if you already have a linux builder or want
to verify reproducibility), set `services.nix-linux-builder.usePrebuilt = false`.

## How It Works

```
nix daemon                        nix-linux-builder (macOS)               Guest VM (Linux)
    │                                     │                                     │
    ├─ writes build.json ────────────────►│                                     │
    ├─ exec's builder with path ─────────►│                                     │
    │                                     ├─ parse build.json                   │
    │                                     ├─ configure VM (VirtioFS, kernel)    │
    │                                     ├─ boot VM ──────────────────────────►│
    │                                     │                                     ├─ mount /nix/store (VirtioFS)
    │                                     │                                     ├─ mount /build (ext4 on VirtioFS)
    │                                     │                                     ├─ detect host UID from VirtioFS
    │                                     │                                     ├─ emit \2\n on hvc0 (ready)
    │◄──── build logs on stdout ──────────┤◄──── hvc0 serial output ────────────┤
    │                                     │                                     ├─ run builder as nixbld user
    │                                     │                                     ├─ write exit code to .exitcode
    │                                     │                                     ├─ poweroff
    │                                     ├─ read .exitcode ◄───────────────────┤
    │◄──── exit with builder's code ──────┤                                     │
```

### VirtioFS Shares

The VM mounts three VirtioFS shares from the host:

| Tag | Host Path | Guest Mount | Purpose |
|---|---|---|---|
| `nix-store` | `/nix/store` | `/nix/store` | Nix store (build inputs and outputs) |
| `buildroot` | `topTmpDir` | `/build-info` | Build scratch space, build.json, .exitcode |
| `rosetta` | (system) | `/rosetta` | Rosetta x86_64 translator (x86_64-linux only) |

### ext4 Loop Mount for /build

Apple's VirtioFS does not honor Linux `DAC_OVERRIDE` -- guest root has no special
privileges on the host filesystem. Tools like `rsync -a` that preserve nix-store
`555` (read-only) directory permissions create truly unwritable directories.

Solution: `/build` uses a loop-mounted ext4 image stored on VirtioFS. The ext4
layer handles permissions within the guest kernel where `DAC_OVERRIDE` works
normally, while the underlying image file is host-disk-backed (sparse, no RAM limit).

### UID Mapping

Apple's VirtioFS preserves host UIDs without translation. macOS Nix build users
have UIDs 351-382 (not the Linux convention of 30000+). The guest init detects the
actual UID by `stat`-ing the VirtioFS-mounted build directory and patches
`/etc/passwd` to match, ensuring correct write access and file ownership.

## Command Line

```
nix-linux-builder [OPTIONS] <build.json>

Required:
  --kernel <path>         Path to Linux ARM64 kernel Image
  --initrd <path>         Path to initrd CPIO archive

Optional:
  --memory-size <bytes>   VM memory in bytes (default: 8 GiB)
  --cpu-count <n>         Number of vCPUs (default: host CPU count)
  --timeout <seconds>     Build timeout, 0 = unlimited (default: 0)
  --network               Enable NAT networking in guest
  --ramdisk-tmp           Use tmpfs for /tmp (faster, limited by RAM)
  -v, --verbose           Enable verbose debug logging
  -h, --help              Show help message

Positional:
  <build.json>            Path to nix build specification (written by nix daemon)
```

### Exit Codes

| Code | Meaning |
|---|---|
| 0-255 | Builder's exit code (read from `.exitcode` file) |
| 253 | VM stopped by SIGTERM or SIGINT |
| 254 | Build timed out |
| 255 | VM start failure, crash, or exit code unreadable |

## Development

### Prerequisites

- Nix with flakes enabled
- Xcode 15+ installed at `/Applications/Xcode.app`

### Building and Testing

```bash
# Enter development shell (sets up SDK, vendors dependencies)
nix develop

# Available make targets:
nix develop -c make help

# Build
nix develop -c make build       # compile
nix develop -c make sign        # codesign with virtualization entitlement
nix develop -c make check       # build + sanity check (--help)

# Test (99 unit tests)
nix develop -c make test        # run unit tests
nix develop -c make test-asan   # run with AddressSanitizer
nix develop -c make test-ubsan  # run with UndefinedBehaviorSanitizer

# Static analysis
nix develop -c make lint        # clang-tidy
nix develop -c make analyze     # Clang static analyzer (scan-build)

# Fuzzing (libFuzzer harness for build.json parser)
nix develop -c make fuzz

# CI pipeline (build + test)
nix develop -c make ci

# Clean
nix develop -c make clean
```

### Project Structure

```
src/
  main.m              Entry point
  cli.c / cli.h       CLI argument parsing (pure C)
  build_json.c / .h   build.json parser (pure C, uses cJSON)
  exitcode.c / .h     Exit code file reading (pure C)
  vm_config.m / .h    VM configuration (Objective-C, Virtualization.framework)
  vm_lifecycle.m / .h VM boot/signal/shutdown (Objective-C)
  log.h               Logging macros
  cjson/               Vendored cJSON v1.7.18

guest/
  init.sh             Guest init script (busybox sh, PID 1)

nix/
  kernel.nix          Guest Linux kernel build (6.1.x, ARM64, minimal config)
  initrd.nix          Guest initrd (busybox + jq + mke2fs)

tests/
  test_cli.c          CLI parsing tests (40 tests)
  test_build_json.c   JSON parser tests (35 tests)
  test_exitcode.c     Exit code tests (24 tests)
  fuzz_build_json.c   libFuzzer harness
  unity/              Vendored Unity test framework v2.6.1
  fixtures/           Test JSON fixtures
```

### Guest Kernel

Minimal ARM64 Linux 6.1.x kernel built with only the features needed:

- VirtioFS (FUSE_FS, VIRTIO_FS, DAX)
- Virtio console (hvc0), entropy, balloon, networking
- ext4 + loop device (for /build)
- binfmt_misc (for Rosetta x86_64 support)
- No sound, USB, GPU, WiFi, Bluetooth, or debug features

Output: uncompressed `Image` (required by Virtualization.framework).

### Guest Initrd

CPIO archive containing statically-linked:

- **busybox** -- shell, mount, cp, setuidgid, poweroff, networking
- **jq** -- build.json parsing
- **mke2fs** -- ext4 formatting for /build image
- **init.sh** -- guest init script

## Known Limitations

- **x86_64 GHC under Rosetta**: `patchelf` creates sub-`0x400000` LOAD segments in
  non-PIE `ghc-binary` executables that Rosetta cannot map. Not a practical blocker
  since `ghc-binary` comes from `cache.nixos.org` (never built locally). All other
  patchelf'd binaries (PIE/ET_DYN) work fine.

## License

Apache License 2.0 -- see [LICENSE](LICENSE).

Copyright 2025, Input Output Group.
