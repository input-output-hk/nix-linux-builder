/*
 * nix-linux-builder — build.json parser
 * Copyright 2025 Moritz Angermann <moritz.angermann@iohk.io>, Input Output Group
 * Apache License 2.0
 */

#include "build_json.h"
#include "log.h"
#include "cjson/cJSON.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Read entire file into a malloc'd buffer. Returns NULL on failure. */
static char *read_file(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        LOG_ERR("cannot open %s: %s", path, strerror(errno));
        return NULL;
    }

    if (fseek(f, 0, SEEK_END) != 0) {
        LOG_ERR("fseek failed on %s: %s", path, strerror(errno));
        fclose(f);
        return NULL;
    }
    long len = ftell(f);
    if (len < 0) {
        LOG_ERR("ftell failed on %s: %s", path, strerror(errno));
        fclose(f);
        return NULL;
    }
    if (len == 0) {
        LOG_ERR("empty file: %s", path);
        fclose(f);
        return NULL;
    }
    if (fseek(f, 0, SEEK_SET) != 0) {
        LOG_ERR("fseek failed on %s: %s", path, strerror(errno));
        fclose(f);
        return NULL;
    }

    /* Guard against overflow in the +1 for NUL terminator. */
    if ((size_t)len == SIZE_MAX) {
        LOG_ERR("file too large: %s", path);
        fclose(f);
        return NULL;
    }

    char *buf = malloc((size_t)len + 1);
    if (!buf) {
        LOG_ERR("out of memory reading %s", path);
        fclose(f);
        return NULL;
    }

    size_t nread = fread(buf, 1, (size_t)len, f);
    fclose(f);

    if (nread != (size_t)len) {
        LOG_ERR("short read on %s: expected %ld bytes, got %zu", path, len, nread);
        free(buf);
        return NULL;
    }

    buf[nread] = '\0';
    return buf;
}

/* Helper: extract a required string field from a cJSON object. */
static const char *get_string(const cJSON *obj, const char *field, const char *path)
{
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(obj, field);
    if (!cJSON_IsString(item) || !item->valuestring || !item->valuestring[0]) {
        LOG_ERR("%s: missing or invalid string field '%s'", path, field);
        return NULL;
    }
    return item->valuestring;
}

/* Core parsing: populate spec from a pre-parsed cJSON root.
 * 'label' is used in error messages (typically a file path or "<buffer>"). */
static int parse_from_root(cJSON *root, const char *label, nlb_build_spec *spec)
{
    spec->_json = root;

    /* Version check */
    const cJSON *ver = cJSON_GetObjectItemCaseSensitive(root, "version");
    if (!cJSON_IsNumber(ver) || ver->valueint != 1) {
        LOG_ERR("%s: unsupported or missing version (expected 1)", label);
        goto fail;
    }
    spec->version = ver->valueint;

    /* Required string fields */
    spec->builder = get_string(root, "builder", label);
    spec->system = get_string(root, "system", label);
    spec->top_tmp_dir = get_string(root, "topTmpDir", label);
    spec->tmp_dir = get_string(root, "tmpDir", label);
    spec->tmp_dir_in_sandbox = get_string(root, "tmpDirInSandbox", label);
    spec->store_dir = get_string(root, "storeDir", label);
    spec->real_store_dir = get_string(root, "realStoreDir", label);

    if (!spec->builder || !spec->system || !spec->top_tmp_dir ||
        !spec->tmp_dir || !spec->tmp_dir_in_sandbox ||
        !spec->store_dir || !spec->real_store_dir)
        goto fail;

    /* args array */
    const cJSON *args = cJSON_GetObjectItemCaseSensitive(root, "args");
    if (cJSON_IsArray(args)) {
        spec->nargs = cJSON_GetArraySize(args);
        if (spec->nargs < 0) { LOG_ERR("%s: invalid args array", label); goto fail; }
        spec->args = calloc((size_t)spec->nargs, sizeof(const char *));
        if (!spec->args) { LOG_ERR("out of memory"); goto fail; }

        const cJSON *item;
        int idx = 0;
        cJSON_ArrayForEach(item, args) {
            if (!cJSON_IsString(item)) {
                LOG_ERR("%s: args[%d] is not a string", label, idx);
                goto fail;
            }
            spec->args[idx++] = item->valuestring;
        }
    }

    /* env object */
    const cJSON *env = cJSON_GetObjectItemCaseSensitive(root, "env");
    if (cJSON_IsObject(env)) {
        spec->nenv = cJSON_GetArraySize(env);
        if (spec->nenv < 0) { LOG_ERR("%s: invalid env object", label); goto fail; }
        spec->env = calloc((size_t)spec->nenv, sizeof(nlb_env_var));
        if (!spec->env) { LOG_ERR("out of memory"); goto fail; }

        const cJSON *item;
        int idx = 0;
        cJSON_ArrayForEach(item, env) {
            if (!cJSON_IsString(item)) {
                LOG_ERR("%s: env.%s is not a string", label,
                        item->string ? item->string : "(null)");
                goto fail;
            }
            spec->env[idx].key = item->string;
            spec->env[idx].value = item->valuestring;
            idx++;
        }
    }

    /* inputPaths array */
    const cJSON *inputs = cJSON_GetObjectItemCaseSensitive(root, "inputPaths");
    if (cJSON_IsArray(inputs)) {
        spec->ninputs = cJSON_GetArraySize(inputs);
        if (spec->ninputs < 0) { LOG_ERR("%s: invalid inputPaths array", label); goto fail; }
        spec->input_paths = calloc((size_t)spec->ninputs, sizeof(const char *));
        if (!spec->input_paths) { LOG_ERR("out of memory"); goto fail; }

        const cJSON *item;
        int idx = 0;
        cJSON_ArrayForEach(item, inputs) {
            if (!cJSON_IsString(item)) {
                LOG_ERR("%s: inputPaths[%d] is not a string", label, idx);
                goto fail;
            }
            spec->input_paths[idx++] = item->valuestring;
        }
    }

    /* outputs object */
    const cJSON *outputs = cJSON_GetObjectItemCaseSensitive(root, "outputs");
    if (cJSON_IsObject(outputs)) {
        spec->noutputs = cJSON_GetArraySize(outputs);
        if (spec->noutputs < 0) { LOG_ERR("%s: invalid outputs object", label); goto fail; }
        spec->outputs = calloc((size_t)spec->noutputs, sizeof(nlb_output));
        if (!spec->outputs) { LOG_ERR("out of memory"); goto fail; }

        const cJSON *item;
        int idx = 0;
        cJSON_ArrayForEach(item, outputs) {
            if (!cJSON_IsString(item)) {
                LOG_ERR("%s: outputs.%s is not a string", label,
                        item->string ? item->string : "(null)");
                goto fail;
            }
            spec->outputs[idx].name = item->string;
            spec->outputs[idx].path = item->valuestring;
            idx++;
        }
    }

    LOG_DBG("parsed build.json: version=%d system=%s builder=%s nargs=%d nenv=%d",
            spec->version, spec->system, spec->builder, spec->nargs, spec->nenv);
    return 0;

fail:
    nlb_build_spec_free(spec);
    return -1;
}

int nlb_build_spec_parse(const char *path, nlb_build_spec *spec)
{
    memset(spec, 0, sizeof(*spec));

    char *text = read_file(path);
    if (!text) return -1;

    cJSON *root = cJSON_Parse(text);
    if (!root) {
        /* cJSON_GetErrorPtr() returns a pointer into 'text', so we must
         * read the error before freeing the buffer. */
        const char *err = cJSON_GetErrorPtr();
        LOG_ERR("%s: JSON parse error near: %.20s", path, err ? err : "(unknown)");
        free(text);
        return -1;
    }
    free(text);

    return parse_from_root(root, path, spec);
}

int nlb_build_spec_parse_buf(const char *buf, const char *label,
                             nlb_build_spec *spec)
{
    memset(spec, 0, sizeof(*spec));

    if (!buf) {
        LOG_ERR("%s: NULL buffer", label ? label : "<unknown>");
        return -1;
    }

    cJSON *root = cJSON_Parse(buf);
    if (!root) {
        const char *err = cJSON_GetErrorPtr();
        LOG_ERR("%s: JSON parse error near: %.20s", label, err ? err : "(unknown)");
        return -1;
    }

    return parse_from_root(root, label, spec);
}

void nlb_build_spec_free(nlb_build_spec *spec)
{
    free(spec->args);
    free(spec->env);
    free(spec->input_paths);
    free(spec->outputs);
    if (spec->_json)
        cJSON_Delete((cJSON *)spec->_json);
    memset(spec, 0, sizeof(*spec));
}

bool nlb_build_spec_needs_rosetta(const nlb_build_spec *spec)
{
    return spec->system && strcmp(spec->system, "x86_64-linux") == 0;
}
