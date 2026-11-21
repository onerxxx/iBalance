# Vendor: zstd（解压端单文件库）

Codex CLI/Desktop 自 2026 年起把已结束会话的 `rollout-*.jsonl` 后台压缩成
`rollout-*.jsonl.zst`（`~/.codex/.tmp/rollout-compression.lock` 的维护任务）。
macOS 不自带 zstd 解码能力（`libarchive` 无 zstd filter、`compression_tool` 只支持
lzfse/lz4/lzma/zlib，`/usr/lib` 无 libzstd），所以这里 vendor 官方的解压端
amalgamation。

- 来源：zstd v1.5.7 `build/single_file_libs/zstddeclib.c`
- 生成方式（在 zstd 源码树内）：
  `cd build/single_file_libs && sh create_single_file_decoder.sh`
- 只含解压（无压缩/CLI），链接后约 +300KB
- `include/ZstdBridge.h` 是最小 API 声明，不使用官方 zstd.h
- 许可证：BSD-3-Clause / GPLv2 双许可，见 `LICENSE`

升级方式：换版本时重新生成 `zstddeclib.c` 覆盖本文件，编译验证 `ZSTD_decompressStream`
签名未变即可。
