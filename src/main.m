/*
 * nix-linux-builder — Entry point
 * Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
 * Apache License 2.0
 *
 * Wires together: CLI parsing → build.json parsing → VM config → VM run → exit.
 *
 * The nix daemon invokes us as:
 *   nix-linux-builder --kernel <K> --initrd <I> <path/to/build.json>
 *
 * We boot a lightweight Linux VM, share /nix/store and the build root
 * via VirtioFS, and stream the guest's hvc0 serial console to stdout
 * (which nix reads as build logs). The guest init signals readiness
 * with \2\n on hvc0, runs the builder, writes .exitcode, and powers off.
 * We read .exitcode and exit with the builder's exit code.
 *
 * In --shell mode, stdin is connected to the guest's hvc0 for interactive
 * use. The terminal is set to raw mode so keystrokes pass through directly.
 */

#import <Foundation/Foundation.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>

#include "cli.h"
#include "build_json.h"
#include "log.h"
#import "vm_config.h"
#import "vm_lifecycle.h"

/* Global verbosity flag used by LOG_DBG macro. */
int nlb_verbose = 0;

/* ── Terminal raw mode for --shell ──────────────────────────────────────── */

static struct termios orig_termios;
static bool termios_saved = false;

/* Restore terminal to its original state (registered via atexit). */
static void restore_terminal(void)
{
    if (termios_saved)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig_termios);
}

/* Switch stdin to raw mode so keystrokes pass through to the guest
 * without line-buffering or echo. Returns 0 on success, -1 on error. */
static int enable_raw_mode(void)
{
    if (!isatty(STDIN_FILENO))
        return 0; /* not a terminal — nothing to configure */

    if (tcgetattr(STDIN_FILENO, &orig_termios) != 0) {
        LOG_ERR("tcgetattr failed");
        return -1;
    }
    termios_saved = true;
    atexit(restore_terminal);

    struct termios raw = orig_termios;
    cfmakeraw(&raw);
    /* Fully raw: all bytes including Ctrl-C (0x03) pass through to the
     * guest's hvc0. The user exits by typing 'exit' or 'poweroff' in
     * the guest shell. External signals (kill -TERM/-INT from another
     * terminal) still work via GCD dispatch sources in vm_lifecycle.m. */
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0) {
        LOG_ERR("tcsetattr failed");
        return -1;
    }
    return 0;
}

/* ── Bare shell: synthesize a minimal build.json in a temp dir ──────────── */

/* Write a minimal build.json that just runs /bin/sh, so the guest init
 * can proceed through its normal setup path. Returns 0 on success. */
static int create_bare_shell_buildroot(char *tmpdir, size_t tmpdir_size)
{
    /* mkdtemp needs a mutable template */
    int n = snprintf(tmpdir, tmpdir_size,
                     "/tmp/nix-linux-shell.XXXXXX");
    if (n < 0 || (size_t)n >= tmpdir_size)
        return -1;

    if (!mkdtemp(tmpdir)) {
        LOG_ERR("mkdtemp failed: %s", strerror(errno));
        return -1;
    }

    /* The guest init expects build.json in the buildroot and a build/ subdir
     * for the ext4 overlay. Create both. */
    char path[PATH_MAX];
    n = snprintf(path, sizeof(path), "%s/build", tmpdir);
    if (n < 0 || (size_t)n >= sizeof(path))
        return -1;
    if (mkdir(path, 0755) != 0) {
        LOG_ERR("mkdir %s failed: %s", path, strerror(errno));
        return -1;
    }

    n = snprintf(path, sizeof(path), "%s/build.json", tmpdir);
    if (n < 0 || (size_t)n >= sizeof(path))
        return -1;

    /* Minimal build.json: system=aarch64-linux, builder=/bin/sh.
     * The guest init detects "shell" on the kernel cmdline and uses
     * this as a signal to drop to an interactive shell instead. */
    FILE *f = fopen(path, "w");
    if (!f) {
        LOG_ERR("fopen %s: %s", path, strerror(errno));
        return -1;
    }
    fprintf(f,
        "{\n"
        "  \"version\": 1,\n"
        "  \"system\": \"aarch64-linux\",\n"
        "  \"builder\": \"/bin/sh\",\n"
        "  \"args\": [],\n"
        "  \"env\": {},\n"
        "  \"inputPaths\": [],\n"
        "  \"outputs\": {},\n"
        "  \"topTmpDir\": \"%s\",\n"
        "  \"tmpDir\": \"%s/build\",\n"
        "  \"tmpDirInSandbox\": \"/build\",\n"
        "  \"storeDir\": \"/nix/store\",\n"
        "  \"realStoreDir\": \"/nix/store\"\n"
        "}\n", tmpdir, tmpdir);
    fclose(f);

    return 0;
}

/* Recursively remove a directory tree.
 * Uses NSFileManager instead of system("rm -rf ...") to avoid shell
 * injection, PATH_MAX truncation, and unnecessary subprocess overhead. */
static void rmrf(const char *path)
{
    @autoreleasepool {
        NSString *nsPath = [[NSString alloc] initWithUTF8String:path];
        if (!nsPath) {
            LOG_ERR("rmrf: invalid UTF-8 path");
            return;
        }
        NSError *error = nil;
        if (![[NSFileManager defaultManager] removeItemAtPath:nsPath error:&error]) {
            /* Silently ignore "file not found" — mirrors rm -f behaviour. */
            if ([error.domain isEqualToString:NSCocoaErrorDomain]
                && error.code == NSFileNoSuchFileError)
                return;
            LOG_ERR("rmrf %s: %s", path, error.localizedDescription.UTF8String);
        }
    }
}

int main(int argc, char *argv[])
{
    @autoreleasepool {
        /* ── 1. Parse CLI arguments ──────────────────────────────────── */
        nlb_cli_opts opts;
        int rc = nlb_cli_parse(argc, argv, &opts);
        if (rc == 1) return 0;  /* --help */
        if (rc != 0) return 1;

        nlb_verbose = opts.verbose;

        LOG_DBG("kernel: %s", opts.kernel_path);
        LOG_DBG("initrd: %s", opts.initrd_path);
        LOG_DBG("build.json: %s", opts.build_json_path ? opts.build_json_path : "(none, bare shell)");

        /* ── 1b. Shell mode: set up raw terminal + temp buildroot ──── */
        char bare_tmpdir[PATH_MAX] = {0};
        char bare_build_json[PATH_MAX] = {0};

        if (opts.shell) {
            if (enable_raw_mode() != 0)
                return 1;

            /* If no build.json was provided, create a minimal one in a
             * temp directory so the guest init can proceed. */
            if (!opts.build_json_path) {
                if (create_bare_shell_buildroot(bare_tmpdir, sizeof(bare_tmpdir)) != 0) {
                    if (bare_tmpdir[0]) rmrf(bare_tmpdir);
                    return 1;
                }
                int nb = snprintf(bare_build_json, sizeof(bare_build_json),
                                  "%s/build.json", bare_tmpdir);
                if (nb < 0 || (size_t)nb >= sizeof(bare_build_json)) {
                    LOG_ERR("bare shell build.json path too long");
                    rmrf(bare_tmpdir);
                    return 1;
                }
                opts.build_json_path = bare_build_json;
                LOG_DBG("bare shell: created temp buildroot at %s", bare_tmpdir);
            }
        }

        /* ── 2. Parse build.json ─────────────────────────────────────── */
        nlb_build_spec spec;
        if (nlb_build_spec_parse(opts.build_json_path, &spec) != 0) {
            if (bare_tmpdir[0]) rmrf(bare_tmpdir);
            return 1;
        }

        LOG_DBG("system: %s", spec.system);
        LOG_DBG("builder: %s", spec.builder);
        LOG_DBG("topTmpDir: %s", spec.top_tmp_dir);
        if (nlb_build_spec_needs_rosetta(&spec))
            LOG_DBG("x86_64-linux build: Rosetta will be enabled");

        /* ── 3. Create VM configuration ──────────────────────────────── */
        VZVirtualMachineConfiguration *vmConfig =
            nlb_create_vm_config(&opts, &spec);
        if (!vmConfig) {
            nlb_build_spec_free(&spec);
            if (bare_tmpdir[0]) rmrf(bare_tmpdir);
            return 1;
        }

        /* ── 4. Build the .exitcode path ─────────────────────────────── */
        /* The guest writes its exit code to topTmpDir/.exitcode via
         * the buildroot VirtioFS share. */
        char exitcode_path[PATH_MAX];
        int n = snprintf(exitcode_path, sizeof(exitcode_path),
                         "%s/.exitcode", spec.top_tmp_dir);
        if (n < 0 || (size_t)n >= sizeof(exitcode_path)) {
            LOG_ERR("exitcode path too long (topTmpDir=%s)", spec.top_tmp_dir);
            nlb_build_spec_free(&spec);
            if (bare_tmpdir[0]) rmrf(bare_tmpdir);
            return 1;
        }

        /* ── 5. Run the VM ───────────────────────────────────────────── */
        int exit_code = nlb_vm_run(vmConfig, exitcode_path, opts.timeout_secs);

        LOG_DBG("VM exited with code %d", exit_code);

        /* ── 6. Cleanup and exit ─────────────────────────────────────── */
        nlb_build_spec_free(&spec);
        if (bare_tmpdir[0]) rmrf(bare_tmpdir);

        /* In shell mode the exit code is informational (the user typed 'exit'),
         * not a build result — always succeed. */
        if (opts.shell && !opts.debug)
            return 0;

        return exit_code;
    }
}
