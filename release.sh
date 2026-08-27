#!/bin/bash
# ============================================================
# 发版流水线：编译（--release，固定自签 Local Sign）→ ditto 打包 → GitHub Release
# 用法：bash release.sh ["本次更新说明（可选）"]
#
# 发布约定（与 App 内 UpdateService 对齐）：
#   • tag 格式 v<CFBundleVersion>（如 v2026.8.27.3），App 数值逐段比较
#   • asset 只放一个 .zip；App 校验顺序 = asset.digest 优先 → 正文 "SHA256: <hex>" 兜底
#   • 仓库需公开（Releases 匿名可拉），否则 App 端 HTTP 404
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="onerxxx/iBalance"

NOTES="${1:-}"

echo "==> 编译 release 构建（-O + 固定自签）"
bash "$ROOT/swift/build.sh" --release

APP="$ROOT/iBalance.app"
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
TAG="v$VER"
ZIP="$ROOT/iBalance-$VER.zip"

echo "==> 打包 $ZIP"
rm -f "$ZIP"
# sequesterRsrc 保住扩展属性（签名/图标元数据），keepParent 让 zip 根目录直接是 iBalance.app
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# ⚠️ 泄漏校验闸门（打包后、上传前强制执行）：
# bundle 内 fallback config.json 若混入 API Key / 账号 token / JWT 一律中止发布。
LEAK="$(unzip -p "$ZIP" "iBalance.app/Contents/Resources/config.json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
bad = []
if d.get('deepseek_api_key', '').strip(): bad.append('deepseek_api_key 非空')
for acc in d.get('workbuddy_accounts', []):
    if acc.get('token') or acc.get('refresh_token'): bad.append(f\"workbuddy_account {acc.get('uid','?')} 带 token\")
raw = sys.stdin.read()
print('; '.join(bad))" )"
RAW_LEAK="$(unzip -p "$ZIP" "iBalance.app/Contents/Resources/config.json" | grep -cE 'eyJhbGci|sk-[a-f0-9]{16}' || true)"
if [ -n "$LEAK" ] || [ "${RAW_LEAK:-0}" != "0" ]; then
    echo "!! 泄漏校验未通过（config.json 含凭据: ${LEAK:-JWT/key 特征串}）。请清空 swift/config.json 敏感字段后重试。" >&2
    exit 1
fi
echo "    泄漏校验通过（fallback config 无凭据）"

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "    SHA256: $SHA"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "!! Release $TAG 已存在（同日版本号重复）。删除后重发：gh release delete $TAG --cleanup-tag -y" >&2
    exit 1
fi

BODY="SHA256: $SHA"
if [ -n "$NOTES" ]; then
    BODY="$NOTES

$BODY"
fi

echo "==> 上传 Release $TAG"
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "$TAG" --notes "$BODY"
echo "==> 完成: https://github.com/$REPO/releases/tag/$TAG"
