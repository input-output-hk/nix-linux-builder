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
 */

#import <Foundation/Foundation.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

#include "cli.h"
#include "build_json.h"
#include "log.h"
#import "vm_config.h"
#import "vm_lifecycle.h"

/* Global verbosity flag used by LOG_DBG macro. */
int nlb_verbose = 0;

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
        LOG_DBG("build.json: %s", opts.build_json_path);

        /* ── 2. Parse build.json ─────────────────────────────────────── */
        nlb_build_spec spec;
        if (nlb_build_spec_parse(opts.build_json_path, &spec) != 0)
            return 1;

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
            return 1;
        }

        /* ── 5. Run the VM ───────────────────────────────────────────── */
        int exit_code = nlb_vm_run(vmConfig, exitcode_path, opts.timeout_secs);

        LOG_DBG("VM exited with code %d", exit_code);

        /* ── 6. Cleanup and exit ─────────────────────────────────────── */
        nlb_build_spec_free(&spec);
        return exit_code;
    }
}
