# Changelog

All notable changes to nix-linux-builder are documented in this file.

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
