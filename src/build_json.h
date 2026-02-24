/*
 * nix-linux-builder — build.json parser
 * Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
 * Apache License 2.0
 *
 * Parses the build specification JSON written by the nix daemon's
 * external-derivation-builder. See:
 *   nix/src/libstore/unix/build/external-derivation-builder.cc
 *
 * JSON schema (version 1):
 * {
 *   "version":         1,
 *   "builder":         "/nix/store/.../bin/bash",
 *   "args":            ["-e", "/nix/store/.../builder.sh"],
 *   "env":             { "HOME": "...", "out": "...", ... },
 *   "inputPaths":      ["/nix/store/..."],
 *   "outputs":         { "out": "/nix/store/..." },
 *   "topTmpDir":       "/private/tmp/nix-build-...",
 *   "tmpDir":          "/private/tmp/nix-build-.../build",
 *   "tmpDirInSandbox": "/build",
 *   "storeDir":        "/nix/store",
 *   "realStoreDir":    "/nix/store",
 *   "system":          "aarch64-linux"
 * }
 */

#ifndef NLB_BUILD_JSON_H
#define NLB_BUILD_JSON_H

#include <stdbool.h>

/* Key-value pair for environment variables. */
typedef struct {
    const char *key;
    const char *value;
} nlb_env_var;

/* Output name-path pair. */
typedef struct {
    const char *name;
    const char *path;
} nlb_output;

/* Parsed build specification.
 * All string pointers are owned by the cJSON tree (freed via nlb_build_spec_free). */
typedef struct {
    int          version;
    const char  *builder;
    const char  *system;
    const char  *top_tmp_dir;
    const char  *tmp_dir;
    const char  *tmp_dir_in_sandbox;
    const char  *store_dir;
    const char  *real_store_dir;

    /* Builder arguments (args[0..nargs-1]) */
    const char **args;
    int          nargs;

    /* Environment variables */
    nlb_env_var *env;
    int          nenv;

    /* Input store paths */
    const char **input_paths;
    int          ninputs;

    /* Output name → path */
    nlb_output  *outputs;
    int          noutputs;

    /* Opaque handle to the cJSON parse tree (for lifetime management) */
    void        *_json;
} nlb_build_spec;

/*
 * Parse a build.json file at the given path.
 * Returns 0 on success, -1 on error (diagnostic printed to stderr).
 * On success, caller must eventually call nlb_build_spec_free().
 */
int nlb_build_spec_parse(const char *path, nlb_build_spec *spec);

/*
 * Parse a build spec from a NUL-terminated buffer (no file I/O).
 * Used by the fuzzing harness for efficient in-memory parsing.
 * Returns 0 on success, -1 on error.
 */
int nlb_build_spec_parse_buf(const char *buf, const char *label,
                             nlb_build_spec *spec);

/* Free all resources associated with a parsed build spec. */
void nlb_build_spec_free(nlb_build_spec *spec);

/* Returns true if the build targets an x86_64-linux system (needs Rosetta). */
bool nlb_build_spec_needs_rosetta(const nlb_build_spec *spec);

#endif /* NLB_BUILD_JSON_H */
