/*
 * nix-linux-builder — store filesystem capability tests
 * Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
 * Apache License 2.0
 */

#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#import "store_volume.h"

static int check_volume(const char *path, BOOL expected_case_sensitive)
{
    @autoreleasepool {
        NSString *volumePath = [NSString stringWithUTF8String:path];
        NSString *reason = nil;
        BOOL supportsCaseSensitiveNames =
            nlb_store_path_supports_case_sensitive_names(volumePath, &reason);
        if (supportsCaseSensitiveNames != expected_case_sensitive) {
            fprintf(stderr, "case-sensitivity query mismatch for %s: %s\n",
                    path, reason.UTF8String ?: "unexpected result");
            return 1;
        }

        char probe_template[PATH_MAX];
        int written = snprintf(probe_template, sizeof(probe_template),
                               "%s/nlb-store-case.XXXXXX", path);
        if (written < 0 || (size_t)written >= sizeof(probe_template)) {
            fprintf(stderr, "test path too long: %s\n", path);
            return 1;
        }
        char *probe_dir = mkdtemp(probe_template);
        if (!probe_dir) {
            fprintf(stderr, "mkdtemp under %s: %s\n", path, strerror(errno));
            return 1;
        }

        char upper_path[PATH_MAX];
        char lower_path[PATH_MAX];
        written = snprintf(upper_path, sizeof(upper_path), "%s/CaseProbe", probe_dir);
        if (written < 0 || (size_t)written >= sizeof(upper_path))
            goto fail;
        written = snprintf(lower_path, sizeof(lower_path), "%s/caseprobe", probe_dir);
        if (written < 0 || (size_t)written >= sizeof(lower_path))
            goto fail;

        int upper_fd = open(upper_path, O_CREAT | O_EXCL | O_WRONLY, 0600);
        if (upper_fd < 0) {
            fprintf(stderr, "create %s: %s\n", upper_path, strerror(errno));
            goto fail;
        }
        if (close(upper_fd) != 0) {
            fprintf(stderr, "close %s: %s\n", upper_path, strerror(errno));
            unlink(upper_path);
            goto fail;
        }

        errno = 0;
        int lower_fd = open(lower_path, O_CREAT | O_EXCL | O_WRONLY, 0600);
        int lower_errno = errno;
        if (expected_case_sensitive) {
            if (lower_fd < 0) {
                fprintf(stderr, "case-sensitive volume rejected distinct name: %s\n",
                        strerror(lower_errno));
                unlink(upper_path);
                goto fail;
            }
            if (close(lower_fd) != 0) {
                fprintf(stderr, "close %s: %s\n", lower_path, strerror(errno));
                unlink(upper_path);
                unlink(lower_path);
                goto fail;
            }
            struct stat upper_stat;
            struct stat lower_stat;
            if (stat(upper_path, &upper_stat) != 0
                || stat(lower_path, &lower_stat) != 0
                || (upper_stat.st_dev == lower_stat.st_dev
                    && upper_stat.st_ino == lower_stat.st_ino)) {
                fprintf(stderr, "case-sensitive names did not produce distinct files\n");
                unlink(upper_path);
                unlink(lower_path);
                goto fail;
            }
            unlink(lower_path);
        } else if (lower_fd >= 0 || lower_errno != EEXIST) {
            fprintf(stderr, "case-insensitive volume did not alias names (errno=%d)\n",
                    lower_errno);
            if (lower_fd >= 0) {
                close(lower_fd);
                unlink(lower_path);
            }
            unlink(upper_path);
            goto fail;
        } else {
            struct stat upper_stat;
            struct stat lower_stat;
            if (stat(upper_path, &upper_stat) != 0
                || stat(lower_path, &lower_stat) != 0
                || upper_stat.st_dev != lower_stat.st_dev
                || upper_stat.st_ino != lower_stat.st_ino) {
                fprintf(stderr, "case-insensitive names did not resolve to one file\n");
                unlink(upper_path);
                goto fail;
            }
        }

        unlink(upper_path);
        if (rmdir(probe_dir) != 0) {
            fprintf(stderr, "rmdir %s: %s\n", probe_dir, strerror(errno));
            return 1;
        }
        printf("PASS: %s reports and behaves as %s\n", path,
               expected_case_sensitive ? "case-sensitive" : "case-insensitive");
        return 0;

fail:
        rmdir(probe_dir);
        return 1;
    }
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: %s <case-insensitive-volume> <case-sensitive-volume>\n",
                    argv[0]);
            return 2;
        }

        int failed = check_volume(argv[1], NO);
        failed |= check_volume(argv[2], YES);

        NSString *missing = [NSString stringWithFormat:@"%s/nlb-missing-%@",
                             argv[2], NSUUID.UUID.UUIDString];
        NSString *reason = nil;
        if (nlb_store_path_supports_case_sensitive_names(missing, &reason)
            || reason.length == 0) {
            fprintf(stderr, "missing store path was not rejected with a diagnostic\n");
            failed = 1;
        } else {
            puts("PASS: unknown filesystem capability fails closed");
        }

        return failed ? 1 : 0;
    }
}
