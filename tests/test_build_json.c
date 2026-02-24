/*
 * nix-linux-builder — Unit tests for build.json parser
 * Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
 * Apache License 2.0
 */

#include "unity/unity.h"
#include "../src/build_json.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Required by log.h macros */
int nlb_verbose = 0;

/* Helper: path to a test fixture relative to the test binary's location.
 * We assume tests are run from the project root via make. */
static char fixture_path[1024];

static const char *fixture(const char *name)
{
    snprintf(fixture_path, sizeof(fixture_path), "tests/fixtures/%s", name);
    return fixture_path;
}

/* Helper: write a temporary JSON file and return its path.
 * Caller must unlink the file. */
static char tmp_path[256];

static const char *write_tmp_json(const char *content)
{
    snprintf(tmp_path, sizeof(tmp_path), "/tmp/nlb_test_XXXXXX");
    int fd = mkstemp(tmp_path);
    if (fd < 0) { TEST_FAIL_MESSAGE("mkstemp failed"); return NULL; }
    ssize_t n = write(fd, content, strlen(content));
    close(fd);
    if (n < 0 || (size_t)n != strlen(content)) {
        TEST_FAIL_MESSAGE("write failed");
        return NULL;
    }
    return tmp_path;
}

void setUp(void) {}
void tearDown(void) {}

/* ── Valid parsing ─────────────────────────────────────────────────────── */

static void test_valid_full(void)
{
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(fixture("valid_build.json"), &spec);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_EQUAL_INT(1, spec.version);
    TEST_ASSERT_EQUAL_STRING("/nix/store/abc123-bash/bin/bash", spec.builder);
    TEST_ASSERT_EQUAL_STRING("aarch64-linux", spec.system);
    TEST_ASSERT_EQUAL_STRING("/private/tmp/nix-build-test", spec.top_tmp_dir);
    TEST_ASSERT_EQUAL_STRING("/private/tmp/nix-build-test/build", spec.tmp_dir);
    TEST_ASSERT_EQUAL_STRING("/build", spec.tmp_dir_in_sandbox);
    TEST_ASSERT_EQUAL_STRING("/nix/store", spec.store_dir);
    TEST_ASSERT_EQUAL_STRING("/nix/store", spec.real_store_dir);

    /* args */
    TEST_ASSERT_EQUAL_INT(2, spec.nargs);
    TEST_ASSERT_NOT_NULL(spec.args);
    TEST_ASSERT_EQUAL_STRING("-e", spec.args[0]);
    TEST_ASSERT_EQUAL_STRING("/nix/store/abc123-builder.sh", spec.args[1]);

    /* env (cJSON preserves insertion order) */
    TEST_ASSERT_EQUAL_INT(3, spec.nenv);
    TEST_ASSERT_NOT_NULL(spec.env);
    TEST_ASSERT_EQUAL_STRING("HOME", spec.env[0].key);
    TEST_ASSERT_EQUAL_STRING("/homeless-shelter", spec.env[0].value);
    TEST_ASSERT_EQUAL_STRING("NIX_BUILD_CORES", spec.env[1].key);
    TEST_ASSERT_EQUAL_STRING("8", spec.env[1].value);
    TEST_ASSERT_EQUAL_STRING("out", spec.env[2].key);
    TEST_ASSERT_EQUAL_STRING("/nix/store/out123-hello", spec.env[2].value);

    /* inputPaths */
    TEST_ASSERT_EQUAL_INT(2, spec.ninputs);
    TEST_ASSERT_NOT_NULL(spec.input_paths);
    TEST_ASSERT_EQUAL_STRING("/nix/store/abc123-bash", spec.input_paths[0]);
    TEST_ASSERT_EQUAL_STRING("/nix/store/def456-stdenv", spec.input_paths[1]);

    /* outputs */
    TEST_ASSERT_EQUAL_INT(1, spec.noutputs);
    TEST_ASSERT_NOT_NULL(spec.outputs);
    TEST_ASSERT_EQUAL_STRING("out", spec.outputs[0].name);
    TEST_ASSERT_EQUAL_STRING("/nix/store/out123-hello", spec.outputs[0].path);

    nlb_build_spec_free(&spec);
}

static void test_minimal(void)
{
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(fixture("minimal_build.json"), &spec);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_EQUAL_INT(1, spec.version);
    TEST_ASSERT_EQUAL_INT(0, spec.nargs);
    TEST_ASSERT_EQUAL_INT(0, spec.nenv);
    TEST_ASSERT_EQUAL_INT(0, spec.ninputs);
    TEST_ASSERT_EQUAL_INT(0, spec.noutputs);
    nlb_build_spec_free(&spec);
}

/* ── Rosetta detection ────────────────────────────────────────────────── */

static void test_needs_rosetta_aarch64(void)
{
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(fixture("valid_build.json"), &spec);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_FALSE(nlb_build_spec_needs_rosetta(&spec));
    nlb_build_spec_free(&spec);
}

static void test_needs_rosetta_x86_64(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"x86_64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\"}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(path, &spec);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_TRUE(nlb_build_spec_needs_rosetta(&spec));
    nlb_build_spec_free(&spec);
    unlink(path);
}

/* ── Error handling ───────────────────────────────────────────────────── */

static void test_missing_version(void)
{
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(fixture("missing_version.json"), &spec);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_bad_types(void)
{
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(fixture("bad_types.json"), &spec);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_empty_file(void)
{
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(fixture("empty.json"), &spec);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_nonexistent_file(void)
{
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse("/nonexistent/path.json", &spec);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_invalid_json(void)
{
    const char *path = write_tmp_json("{broken json");
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(path, &spec);
    TEST_ASSERT_EQUAL_INT(-1, rc);
    unlink(path);
}

static void test_wrong_version(void)
{
    const char *json =
        "{\"version\":99,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\"}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(path, &spec);
    TEST_ASSERT_EQUAL_INT(-1, rc);
    unlink(path);
}

static void test_missing_builder(void)
{
    const char *json =
        "{\"version\":1,\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\"}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(path, &spec);
    TEST_ASSERT_EQUAL_INT(-1, rc);
    unlink(path);
}

static void test_missing_system(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\"}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(path, &spec);
    TEST_ASSERT_EQUAL_INT(-1, rc);
    unlink(path);
}

static void test_empty_builder(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\"}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(path, &spec);
    TEST_ASSERT_EQUAL_INT(-1, rc);
    unlink(path);
}

static void test_args_non_string_element(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\","
        "\"args\":[\"ok\", 42]}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(path, &spec);
    TEST_ASSERT_EQUAL_INT(-1, rc);
    unlink(path);
}

static void test_env_non_string_value(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\","
        "\"env\":{\"HOME\": 42}}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(path, &spec);
    TEST_ASSERT_EQUAL_INT(-1, rc);
    unlink(path);
}

static void test_empty_args_array(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\","
        "\"args\":[]}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(path, &spec);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_EQUAL_INT(0, spec.nargs);
    nlb_build_spec_free(&spec);
    unlink(path);
}

static void test_empty_env_object(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\","
        "\"env\":{}}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(path, &spec);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_EQUAL_INT(0, spec.nenv);
    nlb_build_spec_free(&spec);
    unlink(path);
}

static void test_empty_input_paths(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\","
        "\"inputPaths\":[]}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(path, &spec);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_EQUAL_INT(0, spec.ninputs);
    nlb_build_spec_free(&spec);
    unlink(path);
}

static void test_empty_outputs(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\","
        "\"outputs\":{}}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(path, &spec);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_EQUAL_INT(0, spec.noutputs);
    nlb_build_spec_free(&spec);
    unlink(path);
}

static void test_null_buffer(void)
{
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse_buf(NULL, "test", &spec);
    TEST_ASSERT_EQUAL_INT(-1, rc);
}

static void test_parse_buf_valid(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\"}";
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse_buf(json, "<test>", &spec);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_EQUAL_STRING("/b", spec.builder);
    TEST_ASSERT_EQUAL_STRING("aarch64-linux", spec.system);
    nlb_build_spec_free(&spec);
}

/* Wrong-type optional fields should be treated as absent (not error). */
static void test_args_wrong_type(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\","
        "\"args\":42}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(path, &spec);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_EQUAL_INT(0, spec.nargs);
    nlb_build_spec_free(&spec);
    unlink(path);
}

static void test_env_wrong_type(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\","
        "\"env\":[1,2,3]}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(path, &spec);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_EQUAL_INT(0, spec.nenv);
    nlb_build_spec_free(&spec);
    unlink(path);
}

static void test_input_paths_wrong_type(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\","
        "\"inputPaths\":{}}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(path, &spec);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_EQUAL_INT(0, spec.ninputs);
    nlb_build_spec_free(&spec);
    unlink(path);
}

static void test_outputs_wrong_type(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\","
        "\"outputs\":[\"a\",\"b\"]}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(path, &spec);
    TEST_ASSERT_EQUAL_INT(0, rc);
    TEST_ASSERT_EQUAL_INT(0, spec.noutputs);
    nlb_build_spec_free(&spec);
    unlink(path);
}

static void test_input_paths_non_string_element(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\","
        "\"inputPaths\":[\"ok\", 42]}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(path, &spec);
    TEST_ASSERT_EQUAL_INT(-1, rc);
    unlink(path);
}

static void test_outputs_non_string_value(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\","
        "\"outputs\":{\"out\": 42}}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    int rc = nlb_build_spec_parse(path, &spec);
    TEST_ASSERT_EQUAL_INT(-1, rc);
    unlink(path);
}

/* ── Rosetta with NULL system ─────────────────────────────────────────── */

static void test_needs_rosetta_null_system(void)
{
    /* A zeroed spec has system=NULL — needs_rosetta must not crash. */
    nlb_build_spec spec;
    memset(&spec, 0, sizeof(spec));
    TEST_ASSERT_FALSE(nlb_build_spec_needs_rosetta(&spec));
}

/* ── Empty required string fields ─────────────────────────────────────── */

static void test_empty_system(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\"}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    TEST_ASSERT_EQUAL_INT(-1, nlb_build_spec_parse(path, &spec));
    unlink(path);
}

static void test_empty_top_tmp_dir(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\"}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    TEST_ASSERT_EQUAL_INT(-1, nlb_build_spec_parse(path, &spec));
    unlink(path);
}

static void test_empty_store_dir(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"\",\"realStoreDir\":\"/nix/store\"}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    TEST_ASSERT_EQUAL_INT(-1, nlb_build_spec_parse(path, &spec));
    unlink(path);
}

static void test_empty_tmp_dir(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\"}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    TEST_ASSERT_EQUAL_INT(-1, nlb_build_spec_parse(path, &spec));
    unlink(path);
}

static void test_empty_tmp_dir_in_sandbox(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"/nix/store\"}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    TEST_ASSERT_EQUAL_INT(-1, nlb_build_spec_parse(path, &spec));
    unlink(path);
}

static void test_empty_real_store_dir(void)
{
    const char *json =
        "{\"version\":1,\"builder\":\"/b\",\"system\":\"aarch64-linux\","
        "\"topTmpDir\":\"/t\",\"tmpDir\":\"/t/b\",\"tmpDirInSandbox\":\"/build\","
        "\"storeDir\":\"/nix/store\",\"realStoreDir\":\"\"}";
    const char *path = write_tmp_json(json);
    nlb_build_spec spec;
    TEST_ASSERT_EQUAL_INT(-1, nlb_build_spec_parse(path, &spec));
    unlink(path);
}

/* ── Free idempotency ─────────────────────────────────────────────────── */

static void test_free_zeroed_spec(void)
{
    /* nlb_build_spec_free should be safe on a zeroed spec */
    nlb_build_spec spec;
    memset(&spec, 0, sizeof(spec));
    nlb_build_spec_free(&spec);
    /* If we get here without crashing, the test passes */
    TEST_PASS();
}

/* ── Runner ───────────────────────────────────────────────────────────── */

int main(void)
{
    UNITY_BEGIN();

    /* Valid parsing */
    RUN_TEST(test_valid_full);
    RUN_TEST(test_minimal);

    /* Rosetta detection */
    RUN_TEST(test_needs_rosetta_aarch64);
    RUN_TEST(test_needs_rosetta_x86_64);

    /* Error handling */
    RUN_TEST(test_missing_version);
    RUN_TEST(test_bad_types);
    RUN_TEST(test_empty_file);
    RUN_TEST(test_nonexistent_file);
    RUN_TEST(test_invalid_json);
    RUN_TEST(test_wrong_version);
    RUN_TEST(test_missing_builder);
    RUN_TEST(test_missing_system);
    RUN_TEST(test_empty_builder);
    RUN_TEST(test_args_non_string_element);
    RUN_TEST(test_env_non_string_value);
    RUN_TEST(test_empty_args_array);
    RUN_TEST(test_empty_env_object);
    RUN_TEST(test_empty_input_paths);
    RUN_TEST(test_empty_outputs);
    RUN_TEST(test_null_buffer);
    RUN_TEST(test_parse_buf_valid);

    /* Wrong-type optional fields */
    RUN_TEST(test_args_wrong_type);
    RUN_TEST(test_env_wrong_type);
    RUN_TEST(test_input_paths_wrong_type);
    RUN_TEST(test_outputs_wrong_type);
    RUN_TEST(test_input_paths_non_string_element);
    RUN_TEST(test_outputs_non_string_value);

    /* Rosetta with NULL system */
    RUN_TEST(test_needs_rosetta_null_system);

    /* Empty required string fields */
    RUN_TEST(test_empty_system);
    RUN_TEST(test_empty_top_tmp_dir);
    RUN_TEST(test_empty_store_dir);
    RUN_TEST(test_empty_tmp_dir);
    RUN_TEST(test_empty_tmp_dir_in_sandbox);
    RUN_TEST(test_empty_real_store_dir);

    /* Free idempotency */
    RUN_TEST(test_free_zeroed_spec);

    return UNITY_END();
}
