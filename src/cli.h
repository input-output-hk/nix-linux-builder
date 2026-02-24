/*
 * nix-linux-builder — CLI argument parsing
 * Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
 * Apache License 2.0
 */

#ifndef NLB_CLI_H
#define NLB_CLI_H

#include <stdint.h>
#include <stdbool.h>

/* Parsed command-line options. All string fields point into argv (no allocation). */
typedef struct {
    const char *kernel_path;      /* --kernel <path> (required) */
    const char *initrd_path;      /* --initrd <path> (required) */
    const char *build_json_path;  /* positional argument (required) */
    uint64_t    memory_size;      /* --memory-size <bytes> (default 8GiB) */
    uint32_t    cpu_count;        /* --cpu-count <n> (default host count) */
    uint32_t    timeout_secs;     /* --timeout <seconds> (0 = no timeout) */
    bool        network;          /* --network flag */
    bool        ramdisk_tmp;      /* --ramdisk-tmp flag */
    bool        verbose;          /* -v / --verbose */
} nlb_cli_opts;

/*
 * Parse argc/argv into opts. Returns 0 on success, -1 on error.
 * On error, a diagnostic is printed to stderr.
 * On --help, prints usage and returns 1 (caller should exit 0).
 */
int nlb_cli_parse(int argc, char *argv[], nlb_cli_opts *opts);

/* Print usage to stderr. */
void nlb_cli_usage(const char *prog);

#endif /* NLB_CLI_H */
