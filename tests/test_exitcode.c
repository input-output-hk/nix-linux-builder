/*
 * nix-linux-builder — Unit tests for exit code reading
 * Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
 * Apache License 2.0
 */

#include "unity/unity.h"
#include "../src/exitcode.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Required by log.h macros */
int nlb_verbose = 0;

/* Helper: write content to a temp file, return its path. */
static char tmp_path[256];

static const char *write_tmp(const char *content)
{
    snprintf(tmp_path, sizeof(tmp_path), "/tmp/nlb_exitcode_XXXXXX");
    int fd = mkstemp(tmp_path);
    if (fd < 0) { TEST_FAIL_MESSAGE("mkstemp failed"); return NULL; }
    if (content && *content) {
        ssize_t n = write(fd, content, strlen(content));
        if (n < 0 || (size_t)n != strlen(content)) {
            close(fd);
            TEST_FAIL_MESSAGE("write failed");
            return NULL;
        }
    }
    close(fd);
    return tmp_path;
}

void setUp(void) {}
void tearDown(void) {}

/* ── Valid exit codes ─────────────────────────────────────────────────── */

static void test_exitcode_zero(void)
{
    const char *path = write_tmp("0\n");
    TEST_ASSERT_EQUAL_INT(0, nlb_read_exitcode(path));
    unlink(path);
}

static void test_exitcode_one(void)
{
    const char *path = write_tmp("1\n");
    TEST_ASSERT_EQUAL_INT(1, nlb_read_exitcode(path));
    unlink(path);
}

static void test_exitcode_255(void)
{
    const char *path = write_tmp("255\n");
    TEST_ASSERT_EQUAL_INT(255, nlb_read_exitcode(path));
    unlink(path);
}

static void test_exitcode_no_newline(void)
{
    const char *path = write_tmp("42");
    TEST_ASSERT_EQUAL_INT(42, nlb_read_exitcode(path));
    unlink(path);
}

static void test_exitcode_with_whitespace(void)
{
    const char *path = write_tmp("  7  \n");
    TEST_ASSERT_EQUAL_INT(7, nlb_read_exitcode(path));
    unlink(path);
}

/* ── Error cases ──────────────────────────────────────────────────────── */

static void test_exitcode_missing_file(void)
{
    TEST_ASSERT_EQUAL_INT(-1, nlb_read_exitcode("/nonexistent/path"));
}

static void test_exitcode_empty_file(void)
{
    const char *path = write_tmp("");
    TEST_ASSERT_EQUAL_INT(-1, nlb_read_exitcode(path));
    unlink(path);
}

static void test_exitcode_non_numeric(void)
{
    const char *path = write_tmp("hello\n");
    TEST_ASSERT_EQUAL_INT(-1, nlb_read_exitcode(path));
    unlink(path);
}

static void test_exitcode_negative(void)
{
    const char *path = write_tmp("-1\n");
    TEST_ASSERT_EQUAL_INT(-1, nlb_read_exitcode(path));
    unlink(path);
}

static void test_exitcode_256(void)
{
    /* 256 is beyond valid exit code range [0,255] */
    const char *path = write_tmp("256\n");
    TEST_ASSERT_EQUAL_INT(-1, nlb_read_exitcode(path));
    unlink(path);
}

static void test_exitcode_large_overflow(void)
{
    const char *path = write_tmp("99999999999\n");
    TEST_ASSERT_EQUAL_INT(-1, nlb_read_exitcode(path));
    unlink(path);
}

static void test_exitcode_null_path(void)
{
    TEST_ASSERT_EQUAL_INT(-1, nlb_read_exitcode(NULL));
}

static void test_exitcode_trailing_garbage(void)
{
    /* "1garbage" — fscanf reads 1, but trailing content should be rejected */
    const char *path = write_tmp("1garbage\n");
    TEST_ASSERT_EQUAL_INT(-1, nlb_read_exitcode(path));
    unlink(path);
}

static void test_exitcode_carriage_return(void)
{
    /* "5\r\n" — carriage return before newline should be accepted. */
    const char *path = write_tmp("5\r\n");
    TEST_ASSERT_EQUAL_INT(5, nlb_read_exitcode(path));
    unlink(path);
}

static void test_exitcode_multiple_numbers(void)
{
    /* "0 1 2" — only first number matters, second is trailing content.
     * Space after the number is tolerated (like "7  \n" test above). */
    const char *path = write_tmp("0 1 2\n");
    TEST_ASSERT_EQUAL_INT(0, nlb_read_exitcode(path));
    unlink(path);
}

static void test_exitcode_whitespace_only(void)
{
    /* File with only whitespace and no number should fail. */
    const char *path = write_tmp("   \n");
    TEST_ASSERT_EQUAL_INT(-1, nlb_read_exitcode(path));
    unlink(path);
}

static void test_exitcode_mixed_tab_space(void)
{
    /* Mixed tabs and spaces before the number should be accepted. */
    const char *path = write_tmp("\t  \t3\n");
    TEST_ASSERT_EQUAL_INT(3, nlb_read_exitcode(path));
    unlink(path);
}

static void test_exitcode_trailing_tab(void)
{
    /* Trailing tab after the number should be accepted. */
    const char *path = write_tmp("99\t\n");
    TEST_ASSERT_EQUAL_INT(99, nlb_read_exitcode(path));
    unlink(path);
}

static void test_exitcode_number_then_spaces_only(void)
{
    /* Number followed by only spaces (no newline) should be accepted. */
    const char *path = write_tmp("128   ");
    TEST_ASSERT_EQUAL_INT(128, nlb_read_exitcode(path));
    unlink(path);
}

static void test_exitcode_trailing_period(void)
{
    /* "42." — trailing period is not whitespace, should be rejected. */
    const char *path = write_tmp("42.\n");
    TEST_ASSERT_EQUAL_INT(-1, nlb_read_exitcode(path));
    unlink(path);
}

static void test_exitcode_trailing_semicolon(void)
{
    const char *path = write_tmp("7;\n");
    TEST_ASSERT_EQUAL_INT(-1, nlb_read_exitcode(path));
    unlink(path);
}

static void test_exitcode_is_directory(void)
{
    TEST_ASSERT_EQUAL_INT(-1, nlb_read_exitcode("/tmp"));
}

static void test_exitcode_permission_denied(void)
{
    const char *path = write_tmp("0\n");
    chmod(path, 0000);
    TEST_ASSERT_EQUAL_INT(-1, nlb_read_exitcode(path));
    chmod(path, 0600);
    unlink(path);
}

static void test_exitcode_leading_newline(void)
{
    /* strtol skips all leading whitespace including newlines, so a leading
     * newline before the number is accepted — the manual skip loop handles
     * spaces/tabs and strtol handles the rest. */
    const char *path = write_tmp("\n5\n");
    TEST_ASSERT_EQUAL_INT(5, nlb_read_exitcode(path));
    unlink(path);
}

/* ── Runner ───────────────────────────────────────────────────────────── */

int main(void)
{
    UNITY_BEGIN();

    /* Valid exit codes */
    RUN_TEST(test_exitcode_zero);
    RUN_TEST(test_exitcode_one);
    RUN_TEST(test_exitcode_255);
    RUN_TEST(test_exitcode_no_newline);
    RUN_TEST(test_exitcode_with_whitespace);

    /* Error cases */
    RUN_TEST(test_exitcode_missing_file);
    RUN_TEST(test_exitcode_empty_file);
    RUN_TEST(test_exitcode_non_numeric);
    RUN_TEST(test_exitcode_negative);
    RUN_TEST(test_exitcode_256);
    RUN_TEST(test_exitcode_large_overflow);
    RUN_TEST(test_exitcode_null_path);
    RUN_TEST(test_exitcode_trailing_garbage);
    RUN_TEST(test_exitcode_carriage_return);
    RUN_TEST(test_exitcode_multiple_numbers);
    RUN_TEST(test_exitcode_whitespace_only);
    RUN_TEST(test_exitcode_mixed_tab_space);
    RUN_TEST(test_exitcode_trailing_tab);
    RUN_TEST(test_exitcode_number_then_spaces_only);
    RUN_TEST(test_exitcode_trailing_period);
    RUN_TEST(test_exitcode_trailing_semicolon);
    RUN_TEST(test_exitcode_is_directory);
    RUN_TEST(test_exitcode_permission_denied);
    RUN_TEST(test_exitcode_leading_newline);

    return UNITY_END();
}
