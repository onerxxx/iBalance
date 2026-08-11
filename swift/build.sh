#!/bin/bash
# ============================================================
# 编译 Swift 源码并打包成 iBalance.app
# 产物：../iBalance.app（可双击运行）+ 同目录 config.json
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/main.swift"
PLIST="$SCRIPT_DIR/Info.plist"
CONFIG="$SCRIPT_DIR/config.json"

# 产物输出到上级目录（与 .sh/.py 同级，方便分发）
APP_DIR="$SCRIPT_DIR/../iBalance.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE="$MACOS_DIR/iBalance"

# 收集 swift/ 下所有 .swift（含 Services/ 子目录）作为编译输入
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$SCRIPT_DIR" -maxdepth 2 -name "*.swift" | sort)

echo "==> 编译源文件（${#SOURCES[@]} 个 .swift）"
# -target arm64-apple-macos12 保证兼容 macOS 12+（Apple Silicon）
# -framework Network：NWPathMonitor 离线感知需要
swiftc \
    -parse-as-library \
    -framework Cocoa \
    -framework UserNotifications \
    -framework Security \
    -framework Network \
    -lsqlite3 \
    -target arm64-apple-macos12 \
    -O \
    "${SOURCES[@]}" \
    -o "$SCRIPT_DIR/iBalance"

echo "==> 组装 .app bundle"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# 移动编译产物到 MacOS/
mv "$SCRIPT_DIR/iBalance" "$EXECUTABLE"

# 拷贝 Info.plist
cp "$PLIST" "$CONTENTS_DIR/Info.plist"

# 拷贝 AppIcon.icns 到 Resources（App 图标，Finder/Launchpad 显示）
if [[ -f "$SCRIPT_DIR/AppIcon.icns" ]]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# 拷贝 config.json 到 Resources（作为内置 fallback）
cp "$CONFIG" "$RESOURCES_DIR/config.json"

# 拷贝菜单栏图标 SVG（template image：纯黑填充/描边+透明背景，矢量）到 Resources
cp "$SCRIPT_DIR/icons/credit-card-filled.svg" "$RESOURCES_DIR/credit-card-filled.svg"

# 代码签名（保持固定签名身份）：
# ad-hoc 签名每次编译都会生成新哈希，macOS TCC 按签名识别应用，
# 导致"完全磁盘访问"等授权每次重建都被重置；
# 用固定自签证书签名后，重建不再要求重新授权。
SIGN_IDENTITY="iBalance Local Sign"
if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "==> 代码签名（${SIGN_IDENTITY}）"
    codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR"
else
    echo "!! 未找到签名证书 '$SIGN_IDENTITY'，保留 linker ad-hoc 签名（重建后可能需重新授权磁盘访问）"
fi

# 写根目录 config.json（用户编辑这份，优先级高于 Resources）。
# ⚠️ 覆盖保护：根目录已存在用户配置时做字段级合并（用户字段优先，模板只补充新增 key），
# 绝不用模板直接覆盖（模板里 API Key 为空，直接 cp 会清掉用户真实配置）。
ROOT_CONFIG="$SCRIPT_DIR/../config.json"
if [[ -f "$ROOT_CONFIG" ]]; then
    /usr/bin/python3 - "$CONFIG" "$ROOT_CONFIG" <<'PYEOF'
import json, sys
tpl_path, cur_path = sys.argv[1], sys.argv[2]
try:
    with open(tpl_path) as f: tpl = json.load(f)
    with open(cur_path) as f: cur = json.load(f)
except Exception as e:
    print("!! config 合并解析失败（%s），保留用户原配置不动" % e)
    sys.exit(0)
tpl.update(cur)  # 模板打底补新增 key，用户字段优先覆盖
with open(cur_path, "w") as f:
    json.dump(tpl, f, indent=2, ensure_ascii=False, sort_keys=True)
    f.write("\n")
print("==> 根目录 config.json 已合并（用户字段保留）")
PYEOF
else
    cp "$CONFIG" "$ROOT_CONFIG"
fi

echo "==> 完成"
echo "    应用：$APP_DIR"
echo "    配置：$SCRIPT_DIR/../config.json（编辑此文件改 API Key / 刷新间隔）"
echo ""
echo "双击 iBalance.app 即可运行，或终端：open \"$APP_DIR\""
