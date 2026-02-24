/*
 * nix-linux-builder — Minimal logging macros
 * Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
 * Apache License 2.0
 *
 * All log output goes to stderr to avoid polluting stdout,
 * which carries the guest's hvc0 serial console (build logs for nix).
 */

#ifndef NLB_LOG_H
#define NLB_LOG_H

#include <stdio.h>
#include <stdlib.h>

/* Global verbosity flag — set by CLI parsing. */
extern int nlb_verbose;

/* Use __VA_OPT__ (C23/GNU) to avoid the ## paste extension warning. */
#define LOG_ERR(fmt, ...) \
    fprintf(stderr, "nix-linux-builder: error: " fmt "\n" __VA_OPT__(,) __VA_ARGS__)

#define LOG_WARN(fmt, ...) \
    fprintf(stderr, "nix-linux-builder: warning: " fmt "\n" __VA_OPT__(,) __VA_ARGS__)

#define LOG_INFO(fmt, ...) \
    fprintf(stderr, "nix-linux-builder: " fmt "\n" __VA_OPT__(,) __VA_ARGS__)

#define LOG_DBG(fmt, ...) \
    do { if (nlb_verbose) fprintf(stderr, "nix-linux-builder: debug: " fmt "\n" __VA_OPT__(,) __VA_ARGS__); } while (0)

#define LOG_FATAL(fmt, ...) \
    do { LOG_ERR(fmt __VA_OPT__(,) __VA_ARGS__); exit(1); } while (0)

#endif /* NLB_LOG_H */
