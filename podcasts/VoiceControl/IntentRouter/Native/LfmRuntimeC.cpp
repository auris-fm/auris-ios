#include "LfmRuntimeC.h"

#include "LfmRuntime.h"

#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

thread_local std::string g_lastError;

char *DupCString(const std::string &value) {
    char *out = static_cast<char *>(std::malloc(value.size() + 1));
    if (out == nullptr) {
        return nullptr;
    }
    std::memcpy(out, value.c_str(), value.size() + 1);
    return out;
}

void SetError(const std::exception &error) {
    g_lastError = error.what();
}

}  // namespace

extern "C" {

const char *lfm_last_error(void) {
    return g_lastError.c_str();
}

bool lfm_load(
    const char *model_path,
    const char *classifier_path,
    const char *label_map_path,
    int n_ctx) {
    try {
        g_lastError.clear();
        return LfmRuntimeHolder::instance().load(
            model_path == nullptr ? std::string() : std::string(model_path),
            classifier_path == nullptr ? std::string() : std::string(classifier_path),
            label_map_path == nullptr ? std::string() : std::string(label_map_path),
            n_ctx);
    } catch (const std::exception &error) {
        SetError(error);
        return false;
    }
}

int *lfm_tokenize(const char *text, bool add_bos, int *out_count) {
    try {
        g_lastError.clear();
        if (out_count == nullptr) {
            g_lastError = "out_count is null";
            return nullptr;
        }
        const auto tokens = LfmRuntimeHolder::instance().tokenize(
            text == nullptr ? std::string() : std::string(text),
            add_bos);
        int *out = static_cast<int *>(std::malloc(sizeof(int) * tokens.size()));
        if (out == nullptr) {
            g_lastError = "tokenize allocation failed";
            *out_count = 0;
            return nullptr;
        }
        for (size_t i = 0; i < tokens.size(); ++i) {
            out[i] = tokens[i];
        }
        *out_count = static_cast<int>(tokens.size());
        return out;
    } catch (const std::exception &error) {
        SetError(error);
        if (out_count != nullptr) {
            *out_count = 0;
        }
        return nullptr;
    }
}

void lfm_free_ints(int *values) {
    std::free(values);
}

char *lfm_classify(const int *prompt_token_ids, int n_tokens, int pool_start, int pool_end) {
    try {
        g_lastError.clear();
        if (prompt_token_ids == nullptr || n_tokens <= 0) {
            g_lastError = "invalid prompt tokens";
            return nullptr;
        }
        std::vector<int> tokens(static_cast<size_t>(n_tokens));
        for (int i = 0; i < n_tokens; ++i) {
            tokens[static_cast<size_t>(i)] = prompt_token_ids[i];
        }
        const std::string label = LfmRuntimeHolder::instance().classify(tokens, pool_start, pool_end);
        return DupCString(label);
    } catch (const std::exception &error) {
        SetError(error);
        return nullptr;
    }
}

char *lfm_generate(const char *prefill, int n_predict) {
    try {
        g_lastError.clear();
        const std::string generated = LfmRuntimeHolder::instance().generate(
            prefill == nullptr ? std::string() : std::string(prefill),
            n_predict);
        return DupCString(generated);
    } catch (const std::exception &error) {
        SetError(error);
        return nullptr;
    }
}

void lfm_free_string(char *value) {
    std::free(value);
}

void lfm_reset(void) {
    LfmRuntimeHolder::instance().reset();
}

void lfm_release(void) {
    LfmRuntimeHolder::instance().release();
    g_lastError.clear();
}

}  // extern "C"
