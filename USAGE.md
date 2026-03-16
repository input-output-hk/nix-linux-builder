# nix-linux-builder Usage

## Building

```bash
# Enter nix development shell and build
nix develop -c make build

# Build and codesign (required for Virtualization.framework)
nix develop -c make sign

# Build guest kernel and initrd via nix
nix build .#guest-kernel
nix build .#guest-initrd
```

## Command Line

```
nix-linux-builder [OPTIONS] <build.json>
nix-linux-builder --shell [OPTIONS] [<build.json>]

Options:
  --kernel <path>         Path to Linux ARM64 kernel Image (required)
  --initrd <path>         Path to initrd CPIO archive (required)
  --memory-size <bytes>   VM memory in bytes (default: 8589934592 = 8GiB)
  --cpu-count <n>         Number of vCPUs (default: host CPU count)
  --timeout <seconds>     Build timeout, 0 = none (default: 0)
  --network               Enable NAT networking in guest
  --ramdisk-tmp           Use tmpfs for /tmp instead of VirtioFS (faster, limited by RAM)
  --shell                 Interactive shell mode (build.json optional)
  --debug                 Drop to shell on build failure (requires --shell and build.json)
  -v, --verbose           Enable verbose logging
  -h, --help              Show help message

Positional:
  <build.json>            Path to nix build specification JSON file
```

## Interactive Shell (nix-linux-shell)

```bash
# Plain shell with /nix/store mounted
nix-linux-shell

# Shell with a derivation's build environment
nix-linux-shell /nix/store/...-foo.drv

# Debug: run the build, drop to shell on failure
nix-linux-shell --debug /nix/store/...-foo.drv

# From a flake ref (resolved to .drv automatically)
nix-linux-shell nixpkgs#hello
```

### Direct invocation (without wrapper)

```bash
# Bare shell (no build.json needed)
sudo .build/nix-linux-builder --shell --kernel /path/to/Image --initrd /path/to/initrd --network

# Shell with build environment
sudo .build/nix-linux-builder --shell --kernel /path/to/Image --initrd /path/to/initrd --network build.json

# Debug mode: run build, drop to shell on failure
sudo .build/nix-linux-builder --shell --debug --kernel /path/to/Image --initrd /path/to/initrd --network build.json
```

## nix.conf Configuration

```nix
extra-experimental-features = external-builders
external-builders = [
  {
    "systems": ["aarch64-linux", "x86_64-linux"],
    "program": "/path/to/nix-linux-builder",
    "args": [
      "--kernel", "/path/to/guest-kernel/Image",
      "--initrd", "/path/to/guest-initrd/initrd"
    ]
  }
]
```

## Testing

```bash
# Build a simple Linux package (aarch64)
nix build nixpkgs#legacyPackages.aarch64-linux.hello

# Build a simple Linux package (x86_64, via Rosetta)
nix build nixpkgs#legacyPackages.x86_64-linux.hello
```
