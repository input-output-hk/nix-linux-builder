# Changelog

All notable changes to nix-linux-builder are documented in this file.

## [Unreleased]

### Fixed
- **The code-signing entitlement now survives into the nix store.** The host
  binary was signed in `installPhase`, but stdenv's fixup re-signs Mach-O
  binaries afterwards (strip invalidates the signature) and that re-signature
  carries no entitlements. The store copy therefore arrived as
  `flags=0x20002(adhoc,linker-signed) hashes=24+0` — no
  `com.apple.security.virtualization`. Signing moved to `postFixup`, which runs
  after every fixup hook, so the store copy is now
  `flags=0x2(adhoc) hashes=24+5` with the entitlement present and
  `codesign --verify` clean.

### Changed
- **The darwin module runs the builder directly from the store path.** With the
  entitlement preserved there is no reason to copy the binary to
  `/usr/local/lib/nix-linux-builder` and re-sign it in an activation script, so
  that copy and its generated `entitlements.plist` are gone;
  `nix.settings.external-builders` and the `nix-linux-shell` wrapper now point
  at `${builder}/bin/nix-linux-builder`.

  Downstreams should also drop any activation script that re-signs the binary
  *in place* inside `/nix/store`. That mutates the path's contents so it no
  longer matches its recorded NAR hash: the path fails `nix-store --verify-path`
  and can never be copied to another machine. Nix short-circuits the "build"
  (the path is registered valid), exports the mutated bytes, and the receiving
  host rejects them with `hash mismatch importing path` — which breaks
  centrally-built deploys.

### Notes
- The derivation is byte-reproducible across macOS versions: `codesign` in the
  build is nixpkgs' pinned `darwin.sigtool`, not Apple's, and the same NAR hash
  is produced on macOS 15 and macOS 26 (verified with `nix build --rebuild`).

## [v0.2.0] — 2026-03-16

### Added
- **Interactive shell mode** (`--shell`): boot the builder VM and drop into a
  live Linux shell for interactive exploration and debugging.
  - *Bare shell* (`--shell` alone): busybox sh with `/nix/store` mounted.
  - *Build env shell* (`--shell <build.json>`): full derivation environment with
    interactive bash.
  - *Debug on failure* (`--shell --debug <build.json>`): run the build normally,
    drop to shell on failure for post-mortem inspection.
- **`nix-linux-shell` wrapper script**: resolves `.drv` paths or flake refs,
  builds dependencies, synthesizes `build.json`, and invokes the builder in
  shell mode — no manual assembly required.
- **Darwin module integration**: `nix-linux-shell` automatically installed to
  `environment.systemPackages` with store paths substituted.
- **Bidirectional serial I/O**: host stdin connected to guest hvc0 in shell mode.
- **Terminal raw mode**: keystrokes pass through to the guest without
  line-buffering; terminal restored via `atexit` handler.
- 10 new CLI tests covering `--shell`/`--debug` flag combinations, orthogonality
  with `--network`, and last-wins behaviour for duplicate flags.

### Fixed
- **Darwin module entitlement**: re-sign binary with `com.apple.security.virtualization`
  entitlement after the nix store strips code-signing during registration.
- **Shell/debug hardening**: namespace kernel cmdline flags to `nlb.shell`/`nlb.debug`
  to avoid conflicts with the kernel's own `debug` early_param; fix temp directory
  leak on `create_bare_shell_buildroot` failure; pass Ctrl-C (0x03) through to
  guest hvc0; warn when `--timeout` is set in `--shell` mode; add `snprintf`
  bounds check for bare `build.json` path.
- **Derivation JSON validation**: replace `2>/dev/null` with proper error capture
  in `nix-linux-shell`; validate expected derivation key exists before proceeding.
- **Guard `dispatch_source_create` against NULL** return on resource exhaustion;
  also guard `dispatch_source_cancel` calls.
- **Signal handler ordering**: move `signal(SIG_IGN)` after `dispatch_source_create`
  succeeds so that on failure the signal retains its default behaviour.
- Add `strerror(errno)` to `tcgetattr`/`tcsetattr` error messages.
- Standardize `--timeout=0` wording to "none" in README (matching USAGE.md and
  cli.c help text).

## [v0.1.0] — 2026-03-13

Initial release of nix-linux-builder — an open-source external builder for nix
on macOS using Apple Virtualization.framework.

### Added
- Pure C CLI with JSON-based derivation protocol (`build.json`).
- Objective-C integration with Virtualization.framework (macOS 13+, Apple Silicon).
- Minimal guest Linux kernel + initrd built with Nix.
- VirtioFS for `/nix/store` and build scratch directory sharing.
- Automatic UID detection and mapping for nix build users (UIDs 351–382).
- Loop-mounted ext4 image for `/build` to work around VirtioFS DAC_OVERRIDE
  limitation.
- Nix flake with `guest-kernel`, `guest-initrd`, and builder package outputs.
- nix-darwin module for one-line configuration.
- Pre-built guest components and CI release workflow.

[v0.2.0]: https://github.com/input-output-hk/nix-linux-builder/compare/v0.1.0...v0.2.0
[v0.1.0]: https://github.com/input-output-hk/nix-linux-builder/releases/tag/v0.1.0
