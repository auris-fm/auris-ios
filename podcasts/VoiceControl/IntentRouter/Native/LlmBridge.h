//
// LlmBridge — Objective-C++ surface for the LFM router native stack.
//
// llama.cpp pin (must match Android / training config.yaml):
//   0eadefebd3f8f92a86d634a0e5b8fffc9dc792c0
// Metal / CUDA / Vulkan stay off for this ship. Whisper remains a separate module.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const LfmBridgeErrorDomain;

/// Full LFM classify-then-generate runtime backed by CPU llama.cpp.
@interface LfmRuntimeBridge : NSObject

@property (nonatomic, readonly, copy) NSString *lastError;

- (BOOL)loadWithModelPath:(NSString *)modelPath
           classifierPath:(NSString *)classifierPath
             labelMapPath:(NSString *)labelMapPath
                     nCtx:(NSInteger)nCtx
                    error:(NSError *_Nullable *_Nullable)error;

- (nullable NSArray<NSNumber *> *)tokenize:(NSString *)text
                                    addBos:(BOOL)addBos
                                     error:(NSError *_Nullable *_Nullable)error;

- (nullable NSString *)classifyPromptTokenIds:(NSArray<NSNumber *> *)promptTokenIds
                                   poolStart:(NSInteger)poolStart
                                     poolEnd:(NSInteger)poolEnd
                                       error:(NSError *_Nullable *_Nullable)error;

- (nullable NSString *)generateWithPrefill:(NSString *)prefill
                                 nPredict:(NSInteger)nPredict
                                    error:(NSError *_Nullable *_Nullable)error;

- (void)reset;
- (void)releaseRuntime;

@end

NS_ASSUME_NONNULL_END
