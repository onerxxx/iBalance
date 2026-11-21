// ZstdBridge.h — zstddeclib.c 的最小对外声明（仅供 iBalance 解压 Codex rollout）
//
// 为什么手写而不用官方 zstd.h：zstddeclib.c 是 amalgamation（源 + 头已内联），
// 我们再引入完整 zstd.h 只会多 70KB 且与内联声明重复；这里只暴露解压流所需
// 的 5 个符号，签名与 zstd 1.5.7 公开 API 一致（见 zstddeclib.c 内 zstd.h 段落）。
#ifndef ZSTD_BRIDGE_H
#define ZSTD_BRIDGE_H

#include <stddef.h>

typedef struct {
    const void* src;
    size_t size;
    size_t pos;
} ZSTD_inBuffer;

typedef struct {
    void* dst;
    size_t size;
    size_t pos;
} ZSTD_outBuffer;

typedef struct ZSTD_DCtx_s ZSTD_DCtx;
typedef ZSTD_DCtx ZSTD_DStream;

ZSTD_DCtx* ZSTD_createDCtx(void);
size_t ZSTD_freeDCtx(ZSTD_DCtx* dctx);
size_t ZSTD_decompressStream(ZSTD_DStream* zds, ZSTD_outBuffer* output, ZSTD_inBuffer* input);
unsigned ZSTD_isError(size_t result);
const char* ZSTD_getErrorName(size_t result);

#endif /* ZSTD_BRIDGE_H */
