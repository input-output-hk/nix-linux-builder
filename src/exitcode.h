/*
 * nix-linux-builder — Exit code reading
 * Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
 * Apache License 2.0
 */

#ifndef NLB_EXITCODE_H
#define NLB_EXITCODE_H

/*
 * Read the integer exit code from the file written by the guest init.
 * Returns the exit code (>= 0) on success, or -1 if the file is
 * missing, empty, or contains non-numeric content.
 */
int nlb_read_exitcode(const char *path);

#endif /* NLB_EXITCODE_H */
