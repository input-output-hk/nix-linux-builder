/*
 * nix-linux-builder — Unit tests for CLI argument parsing
 * Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
 * Apache License 2.0
 */

#include "unity/unity.h"
#include "../src/cli.h"

#include <stdint.h>
#include <string.h>
#include <getopt.h>

/* Required by log.h macros */
int nlb_verbose = 0;

/* Reset getopt state between test cases (macOS/BSD-specific). */
static void reset_getopt(void)
{
    optind = 1;
#ifdef __APPLE__
    optreset = 1;
#endif
}

void setUp(void) { reset_getopt(); }
void tearDown(void) {}

/* ── Valid invocations ─────────────────────────────────────────────────── */

static void test_minimal_valid(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i", "build.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(6, argv, &opts);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_EQUAL_STRING("/k", opts.kernel_path);
    TEST_ASSERT_EQUAL_STRING("/i", opts.initrd_path);
    TEST_ASSERT_EQUAL_STRING("build.json", opts.build_json_path);
}

static void test_all_options(void)
{
    char *argv[] = {
        "nlb", "--kernel", "/k", "--initrd", "/i",
        "--memory-size", "4294967296", "--cpu-count", "2",
        "--timeout", "300", "--network", "--ramdisk-tmp",
        "-v", "build.json"
    };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(15, argv, &opts);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_EQUAL_UINT64(4294967296ULL, opts.memory_size);
    TEST_ASSERT_EQUAL_UINT32(2, opts.cpu_count);
    TEST_ASSERT_EQUAL_UINT32(300, opts.timeout_secs);
    TEST_ASSERT_TRUE(opts.network);
    TEST_ASSERT_TRUE(opts.ramdisk_tmp);
    TEST_ASSERT_TRUE(opts.verbose);
}

static void test_defaults(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(6, argv, &opts);
    TEST_ASSERT_EQUAL_INT(0, rc);
    /* Default memory: 8 GiB */
    TEST_ASSERT_EQUAL_UINT64(8ULL * 1024 * 1024 * 1024, opts.memory_size);
    /* Default CPU count: host CPU count (> 0) */
    TEST_ASSERT_TRUE(opts.cpu_count > 0);
    /* Default timeout: 0 (no timeout) */
    TEST_ASSERT_EQUAL_UINT32(0, opts.timeout_secs);
    TEST_ASSERT_FALSE(opts.network);
    TEST_ASSERT_FALSE(opts.ramdisk_tmp);
    TEST_ASSERT_FALSE(opts.verbose);
}

static void test_timeout_zero(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--timeout", "0", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(8, argv, &opts);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_EQUAL_UINT32(0, opts.timeout_secs);
}

/* ── --help ───────────────────────────────────────────────────────────── */

static void test_help_returns_1(void)
{
    char *argv[] = { "nlb", "--help" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(2, argv, &opts);
    TEST_ASSERT_EQUAL_INT(1, rc);
}

static void test_help_short_returns_1(void)
{
    char *argv[] = { "nlb", "-h" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(2, argv, &opts);
    TEST_ASSERT_EQUAL_INT(1, rc);
}

/* ── Missing required options ─────────────────────────────────────────── */

static void test_missing_kernel(void)
{
    char *argv[] = { "nlb", "--initrd", "/i", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(4, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_missing_initrd(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(4, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_missing_build_json(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(5, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_no_args(void)
{
    char *argv[] = { "nlb" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(1, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

/* ── Invalid numeric values ───────────────────────────────────────────── */

static void test_invalid_memory_size_letters(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--memory-size", "abc", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(8, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_invalid_memory_size_trailing_garbage(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--memory-size", "123abc", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(8, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_invalid_memory_size_zero(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--memory-size", "0", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(8, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_invalid_cpu_count_zero(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--cpu-count", "0", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(8, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_invalid_cpu_count_letters(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--cpu-count", "abc", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(8, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_invalid_cpu_count_trailing_garbage(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--cpu-count", "4abc", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(8, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_invalid_timeout_letters(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--timeout", "abc", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(8, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_invalid_timeout_trailing_garbage(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--timeout", "60abc", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(8, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_invalid_timeout_negative(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--timeout", "-1", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(8, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_invalid_memory_size_negative(void)
{
    /* strtoull silently wraps negative values — we must reject them. */
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--memory-size", "-1", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(8, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_invalid_cpu_count_negative(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--cpu-count", "-1", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(8, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

/* ── Empty string paths ───────────────────────────────────────────────── */

static void test_empty_kernel_path(void)
{
    char *argv[] = { "nlb", "--kernel", "", "--initrd", "/i", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(6, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_empty_initrd_path(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(6, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_empty_build_json_path(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i", "" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(6, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_extra_positional_args(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "b.json", "extra" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(7, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

/* ── Unknown option ───────────────────────────────────────────────────── */

static void test_unknown_option(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--bogus", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(7, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

/* ── Boolean flags ────────────────────────────────────────────────────── */

static void test_verbose_flag(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "-v", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(7, argv, &opts);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_TRUE(opts.verbose);
}

static void test_network_flag(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--network", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(7, argv, &opts);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_TRUE(opts.network);
}

static void test_ramdisk_tmp_flag(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--ramdisk-tmp", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(7, argv, &opts);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_TRUE(opts.ramdisk_tmp);
}

/* ── Boundary values ──────────────────────────────────────────────────── */

static void test_memory_size_large_valid(void)
{
    /* 18446744073709551615 = UINT64_MAX — valid (huge but parseable) */
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--memory-size", "18446744073709551615", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(8, argv, &opts);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_EQUAL_UINT64(UINT64_MAX, opts.memory_size);
}

static void test_memory_size_overflow(void)
{
    /* One more than UINT64_MAX — should fail with ERANGE */
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--memory-size", "18446744073709551616", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(8, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_cpu_count_max_uint32(void)
{
    /* 4294967295 = UINT32_MAX — valid */
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--cpu-count", "4294967295", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(8, argv, &opts);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_EQUAL_UINT32(UINT32_MAX, opts.cpu_count);
}

static void test_cpu_count_overflow(void)
{
    /* UINT32_MAX + 1 = 4294967296 — should fail */
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--cpu-count", "4294967296", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(8, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_timeout_max_uint32(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--timeout", "4294967295", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(8, argv, &opts);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_EQUAL_UINT32(UINT32_MAX, opts.timeout_secs);
}

static void test_timeout_overflow(void)
{
    char *argv[] = { "nlb", "--kernel", "/k", "--initrd", "/i",
                     "--timeout", "4294967296", "b.json" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(8, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

/* ── Missing option value ────────────────────────────────────────────── */

static void test_kernel_missing_value(void)
{
    /* --kernel as last arg with no value — getopt returns '?' */
    char *argv[] = { "nlb", "--kernel" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(2, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_memory_size_missing_value(void)
{
    char *argv[] = { "nlb", "--memory-size" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(2, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_initrd_missing_value(void)
{
    char *argv[] = { "nlb", "--initrd" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(2, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_cpu_count_missing_value(void)
{
    char *argv[] = { "nlb", "--cpu-count" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(2, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_timeout_missing_value(void)
{
    char *argv[] = { "nlb", "--timeout" };
    nlb_cli_opts opts;
    int rc = nlb_cli_parse(2, argv, &opts);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

/* ── Runner ───────────────────────────────────────────────────────────── */

int main(void)
{
    UNITY_BEGIN();

    /* Valid invocations */
    RUN_TEST(test_minimal_valid);
    RUN_TEST(test_all_options);
    RUN_TEST(test_defaults);
    RUN_TEST(test_timeout_zero);

    /* --help */
    RUN_TEST(test_help_returns_1);
    RUN_TEST(test_help_short_returns_1);

    /* Missing required options */
    RUN_TEST(test_missing_kernel);
    RUN_TEST(test_missing_initrd);
    RUN_TEST(test_missing_build_json);
    RUN_TEST(test_no_args);

    /* Invalid numeric values */
    RUN_TEST(test_invalid_memory_size_letters);
    RUN_TEST(test_invalid_memory_size_trailing_garbage);
    RUN_TEST(test_invalid_memory_size_zero);
    RUN_TEST(test_invalid_cpu_count_zero);
    RUN_TEST(test_invalid_cpu_count_letters);
    RUN_TEST(test_invalid_cpu_count_trailing_garbage);
    RUN_TEST(test_invalid_timeout_letters);
    RUN_TEST(test_invalid_timeout_trailing_garbage);
    RUN_TEST(test_invalid_timeout_negative);
    RUN_TEST(test_invalid_memory_size_negative);
    RUN_TEST(test_invalid_cpu_count_negative);

    /* Empty string paths */
    RUN_TEST(test_empty_kernel_path);
    RUN_TEST(test_empty_initrd_path);
    RUN_TEST(test_empty_build_json_path);
    RUN_TEST(test_extra_positional_args);

    /* Unknown option */
    RUN_TEST(test_unknown_option);

    /* Boolean flags */
    RUN_TEST(test_verbose_flag);
    RUN_TEST(test_network_flag);
    RUN_TEST(test_ramdisk_tmp_flag);

    /* Boundary values */
    RUN_TEST(test_memory_size_large_valid);
    RUN_TEST(test_memory_size_overflow);
    RUN_TEST(test_cpu_count_max_uint32);
    RUN_TEST(test_cpu_count_overflow);
    RUN_TEST(test_timeout_max_uint32);
    RUN_TEST(test_timeout_overflow);

    /* Missing option value */
    RUN_TEST(test_kernel_missing_value);
    RUN_TEST(test_memory_size_missing_value);
    RUN_TEST(test_initrd_missing_value);
    RUN_TEST(test_cpu_count_missing_value);
    RUN_TEST(test_timeout_missing_value);

    return UNITY_END();
}
