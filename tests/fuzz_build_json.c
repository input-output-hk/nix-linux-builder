/*
 * nix-linux-builder — libFuzzer harness for build.json parser
 * Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
 * Apache License 2.0
 *
 * Feeds random bytes through nlb_build_spec_parse_buf() to find crashes
 * in cJSON + field extraction logic.
 *
 * Build:  nix develop -c make fuzz
 * Run:    .build/fuzz_build_json tests/fixtures/ [-max_total_time=60]
 *
 * The seed corpus is the tests/fixtures/ JSON files.
 */

#include "../src/build_json.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Required by log.h macros. */
int nlb_verbose = 0;

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    /* NUL-terminate the input — cJSON requires it. */
    char *buf = malloc(size + 1);
    if (!buf) return 0;
    memcpy(buf, data, size);
    buf[size] = '\0';

    nlb_build_spec spec;
    if (nlb_build_spec_parse_buf(buf, "<fuzz>", &spec) == 0)
        nlb_build_spec_free(&spec);

    free(buf);
    return 0;
}
