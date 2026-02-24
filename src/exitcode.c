/*
 * nix-linux-builder — Exit code reading
 * Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
 * Apache License 2.0
 */

#include "exitcode.h"
#include "log.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int nlb_read_exitcode(const char *path)
{
    if (!path) {
        LOG_ERR("NULL exitcode path");
        return -1;
    }

    FILE *f = fopen(path, "r");
    if (!f) {
        LOG_ERR("cannot read exit code from %s: %s", path, strerror(errno));
        return -1;
    }

    /* Read the entire file (small — just a number + newline). */
    char buf[32];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);

    if (n == 0) {
        LOG_ERR("cannot parse exit code from %s", path);
        return -1;
    }
    buf[n] = '\0';

    /* Skip leading whitespace. */
    const char *p = buf;
    while (*p == ' ' || *p == '\t')
        p++;

    /* Parse with strtol — defined overflow behavior (sets errno=ERANGE). */
    char *endptr;
    errno = 0;
    long val = strtol(p, &endptr, 10);

    if (errno != 0 || endptr == p || val < 0 || val > 255) {
        LOG_ERR("cannot parse exit code from %s", path);
        return -1;
    }

    /* Reject trailing content (e.g. "1garbage"). The guest writes a bare
     * integer, so anything beyond the number + optional whitespace/newline
     * indicates a malformed file. Check only the first trailing character
     * to match the expected protocol format. */
    if (*endptr != '\n' && *endptr != '\0' &&
        *endptr != ' '  && *endptr != '\t' && *endptr != '\r') {
        LOG_ERR("unexpected trailing content in exit code file: %s", path);
        return -1;
    }

    return (int)val;
}
