#import "LlmBridge.h"

#include "LfmRuntime.h"

#include <string>
#include <vector>

NSErrorDomain const LfmBridgeErrorDomain = @"LfmBridgeErrorDomain";

namespace {

NSError *MakeError(NSInteger code, const std::string& message) {
    return [NSError errorWithDomain:LfmBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: @(message.c_str())}];
}

std::vector<int> NumbersToInts(NSArray<NSNumber *> *numbers) {
    std::vector<int> values;
    values.reserve(numbers.count);
    for (NSNumber *number in numbers) {
        values.push_back(number.intValue);
    }
    return values;
}

NSArray<NSNumber *> *IntsToNumbers(const std::vector<int>& values) {
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:values.size()];
    for (int value : values) {
        [out addObject:@(value)];
    }
    return out;
}

}  // namespace

@implementation LfmRuntimeBridge {
    NSString *_lastError;
}

- (NSString *)lastError {
    return _lastError ?: @"";
}

- (BOOL)loadWithModelPath:(NSString *)modelPath
           classifierPath:(NSString *)classifierPath
             labelMapPath:(NSString *)labelMapPath
                     nCtx:(NSInteger)nCtx
                    error:(NSError *_Nullable *_Nullable)error {
    try {
        _lastError = @"";
        return LfmRuntimeHolder::instance().load(
            std::string(modelPath.UTF8String),
            std::string(classifierPath.UTF8String),
            std::string(labelMapPath.UTF8String),
            static_cast<int>(nCtx));
    } catch (const std::exception& ex) {
        _lastError = @(ex.what());
        if (error != nil) {
            *error = MakeError(1, ex.what());
        }
        return NO;
    }
}

- (nullable NSArray<NSNumber *> *)tokenize:(NSString *)text
                                    addBos:(BOOL)addBos
                                     error:(NSError *_Nullable *_Nullable)error {
    try {
        _lastError = @"";
        return IntsToNumbers(LfmRuntimeHolder::instance().tokenize(std::string(text.UTF8String), addBos));
    } catch (const std::exception& ex) {
        _lastError = @(ex.what());
        if (error != nil) {
            *error = MakeError(2, ex.what());
        }
        return nil;
    }
}

- (nullable NSString *)classifyPromptTokenIds:(NSArray<NSNumber *> *)promptTokenIds
                                   poolStart:(NSInteger)poolStart
                                     poolEnd:(NSInteger)poolEnd
                                       error:(NSError *_Nullable *_Nullable)error {
    try {
        _lastError = @"";
        const std::string label = LfmRuntimeHolder::instance().classify(
            NumbersToInts(promptTokenIds),
            static_cast<int>(poolStart),
            static_cast<int>(poolEnd));
        return @(label.c_str());
    } catch (const std::exception& ex) {
        _lastError = @(ex.what());
        if (error != nil) {
            *error = MakeError(3, ex.what());
        }
        return nil;
    }
}

- (nullable NSString *)generateWithPrefill:(NSString *)prefill
                                 nPredict:(NSInteger)nPredict
                                    error:(NSError *_Nullable *_Nullable)error {
    try {
        _lastError = @"";
        const std::string generated = LfmRuntimeHolder::instance().generate(
            std::string(prefill.UTF8String),
            static_cast<int>(nPredict));
        return @(generated.c_str());
    } catch (const std::exception& ex) {
        _lastError = @(ex.what());
        if (error != nil) {
            *error = MakeError(4, ex.what());
        }
        return nil;
    }
}

- (void)reset {
    LfmRuntimeHolder::instance().reset();
}

- (void)releaseRuntime {
    LfmRuntimeHolder::instance().release();
    _lastError = @"";
}

@end
