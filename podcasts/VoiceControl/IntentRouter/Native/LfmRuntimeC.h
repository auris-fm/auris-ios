#pragma once

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef LFM_API
#  if defined(__GNUC__) || defined(__clang__)
#    define LFM_API __attribute__((visibility("default")))
#  else
#    define LFM_API
#  endif
#endif

/// Last error message from the LFM runtime (empty string when none).
LFM_API const char *lfm_last_error(void);

/// Load GGUF + LFMC classifier + label map. Returns false on failure.
LFM_API bool lfm_load(
    const char *model_path,
    const char *classifier_path,
    const char *label_map_path,
    int n_ctx);

/// Tokenize with special tokens kept (`special=true`). Caller must free with lfm_free_ints.
LFM_API int *lfm_tokenize(const char *text, bool add_bos, int *out_count);

LFM_API void lfm_free_ints(int *values);

/// Classify last-user span. Caller must free with lfm_free_string.
LFM_API char *lfm_classify(const int *prompt_token_ids, int n_tokens, int pool_start, int pool_end);

/// Greedy generate from prefill. Caller must free with lfm_free_string.
LFM_API char *lfm_generate(const char *prefill, int n_predict);

LFM_API void lfm_free_string(char *value);

LFM_API void lfm_reset(void);

LFM_API void lfm_release(void);

#ifdef __cplusplus
}
#endif
