#import "LlmBridge.h"

#include "LfmRuntimeC.h"

#include <string>
#include <vector>

NSErrorDomain const LfmBridgeErrorDomain = @"LfmBridgeErrorDomain";

namespace {

NSError *MakeError(NSInteger code, const char *message) {
    NSString *text = message == nullptr ? @"" : @(message);
    return [NSError errorWithDomain:LfmBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: text}];
}

}  // namespace

@implementation LfmRuntimeBridge {
    NSString *_lastError;
}

- (NSString *)lastError {
    if (_lastError != nil) {
        return _lastError;
    }
    const char *native = lfm_last_error();
    return native == nullptr ? @"" : @(native);
}

- (BOOL)loadWithModelPath:(NSString *)modelPath
           classifierPath:(NSString *)classifierPath
             labelMapPath:(NSString *)labelMapPath
                     nCtx:(NSInteger)nCtx
                    error:(NSError *_Nullable *_Nullable)error {
    _lastError = @"";
    const bool ok = lfm_load(
        modelPath.UTF8String,
        classifierPath.UTF8String,
        labelMapPath.UTF8String,
        static_cast<int>(nCtx));
    if (!ok) {
        _lastError = @(lfm_last_error());
        if (error != nil) {
            *error = MakeError(1, lfm_last_error());
        }
        return NO;
    }
    return YES;
}

- (nullable NSArray<NSNumber *> *)tokenize:(NSString *)text
                                    addBos:(BOOL)addBos
                                     error:(NSError *_Nullable *_Nullable)error {
    _lastError = @"";
    int count = 0;
    int *tokens = lfm_tokenize(text.UTF8String, addBos ? true : false, &count);
    if (tokens == nullptr) {
        _lastError = @(lfm_last_error());
        if (error != nil) {
            *error = MakeError(2, lfm_last_error());
        }
        return nil;
    }
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
    for (int i = 0; i < count; ++i) {
        [out addObject:@(tokens[i])];
    }
    lfm_free_ints(tokens);
    return out;
}

- (nullable NSString *)classifyPromptTokenIds:(NSArray<NSNumber *> *)promptTokenIds
                                   poolStart:(NSInteger)poolStart
                                     poolEnd:(NSInteger)poolEnd
                                       error:(NSError *_Nullable *_Nullable)error {
    _lastError = @"";
    std::vector<int> tokens;
    tokens.reserve(promptTokenIds.count);
    for (NSNumber *number in promptTokenIds) {
        tokens.push_back(number.intValue);
    }
    char *label = lfm_classify(
        tokens.data(),
        static_cast<int>(tokens.size()),
        static_cast<int>(poolStart),
        static_cast<int>(poolEnd));
    if (label == nullptr) {
        _lastError = @(lfm_last_error());
        if (error != nil) {
            *error = MakeError(3, lfm_last_error());
        }
        return nil;
    }
    NSString *result = @(label);
    lfm_free_string(label);
    return result;
}

- (nullable NSString *)generateWithPrefill:(NSString *)prefill
                                 nPredict:(NSInteger)nPredict
                                    error:(NSError *_Nullable *_Nullable)error {
    _lastError = @"";
    char *generated = lfm_generate(prefill.UTF8String, static_cast<int>(nPredict));
    if (generated == nullptr) {
        _lastError = @(lfm_last_error());
        if (error != nil) {
            *error = MakeError(4, lfm_last_error());
        }
        return nil;
    }
    NSString *result = @(generated);
    lfm_free_string(generated);
    return result;
}

- (void)reset {
    lfm_reset();
}

- (void)releaseRuntime {
    lfm_release();
    _lastError = @"";
}

@end
