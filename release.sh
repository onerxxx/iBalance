#!/bin/bash
# ============================================================
# 发版流水线：编译（--release，固定自签 Local Sign）→ ditto 打包 → GitHub Release
# 用法：bash release.sh ["本次更新说明（可选）"]
#
# 发布约定（与 App 内 UpdateService 对齐）：
#   • tag 格式 v<CFBundleVersion>（如 v2026.8.27.3），App 数值逐段比较
#   • asset 只放一个 .zip；App 校验顺序 = asset.digest 优先 → 正文 "SHA256: <hex>" 兜底
#   • 仓库需公开（Releases 匿名可拉），否则 App 端 HTTP 404
#   ⚠️ tag 由 GitHub 从**远端默认分支 HEAD** 创建，不是取本地 HEAD；zip 又由 build.sh 从
#      **磁盘源码**编出 ⇒ 两者都必须与「这套要发布的改动」对齐。开头 git 段替你做掉
#      commit + push 并复核（详见该段注释）
# ============================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="onerxxx/iBalance"

NOTES="${1:-}"

# ── 发布前置 git 段：commit → push → 复核（2026-09-23 加）────────────────────
# 为什么必须有：`gh release create <tag> <zip>` 的 tag 由 GitHub 从**远端默认分支 HEAD** 建，
# 而 zip 是 build.sh 从**磁盘上的源码**编出来的。两条都得与这套改动对齐，否则：
#   • 改了没 commit ⇒ 二进制里带着 tag 源码没有的代码；
#   • 提交了没 push ⇒ tag 指向旧提交，release 页源码对不上（v2026.9.23.4 就是这么踩的）。
# 这里把这两步做掉：`git add -u`（**只提已跟踪文件**，新建/未跟踪的草稿不会被扫进历史）
# → commit（首行取发版说明的亮点句，正文 = 完整说明）→ `git push` → 复核 HEAD == 远端默认分支。
#
# ⚠️ 位置刻意在**编译之前**：本节失败时版本号计数器还没被消费，修好原样重跑即可、不会跳号。
# ⚠️ 想自己掌握提交内容？自己 commit + push 后再跑 —— 没有已跟踪改动时本节只做一次幂等
#    push 与复核，不会另建提交。
# 逃生开关：IBALANCE_SKIP_PUSH_GATE=1 整段跳过（会大声提示 tag 可能不指向本次提交）。
if [[ "${IBALANCE_SKIP_PUSH_GATE:-}" == "1" ]]; then
    echo "!! 已跳过发布前置 git 段（IBALANCE_SKIP_PUSH_GATE=1）：不提交、不推送、不复核" >&2
else
    echo "==> 发布前置 git 段：commit → push → 复核"
    DEFAULT_BRANCH="$(gh api "repos/$REPO" --jq '.default_branch' 2>/dev/null || true)"
    if [[ -z "$DEFAULT_BRANCH" ]]; then
        # 取不到默认分支 = gh 未登录 / 网络不可达 —— 后面的上传同样做不了，直接中止
        echo "!! 取不到远端默认分支（gh 未登录或网络不可达）。发布流程本身也需要它，先修好再发。" >&2
        exit 1
    fi
    BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
    if [[ "$BRANCH" != "$DEFAULT_BRANCH" ]]; then
        # 在别的分支上发版没有意义（tag 只从默认分支建），而且自动 push 会把该分支推到公开远端
        echo "!! 中止：当前在 ${BRANCH} 分支，tag 却由 ${DEFAULT_BRANCH} 建 ⇒ 切回 ${DEFAULT_BRANCH} 再发" >&2
        exit 1
    fi
    # 1) 自动提交：仅已跟踪文件的改动 / 删除（未跟踪文件不碰）
    TRACKED_DIRTY="$(git -C "$ROOT" status --porcelain --untracked-files=no)"
    if [[ -n "$TRACKED_DIRTY" ]]; then
        echo "    待提交（已跟踪文件）:"
        printf '%s\n' "$TRACKED_DIRTY" | sed 's/^/      /'
        # 提交首行 = 发版说明里第一个非空、非标题行（即「本版亮点」那段）；正文 = 完整说明
        SUBJECT="$(printf '%s\n' "$NOTES" | grep -v '^[[:space:]]*$' | grep -v '^#' | head -1 | cut -c1-72)"
        [[ -z "$SUBJECT" ]] && SUBJECT="发版前提交"
        git -C "$ROOT" add -u
        # --cleanup=whitespace：说明正文里的 `#` 标题行必须原样保留，别被当注释剔掉
        git -C "$ROOT" commit -q --cleanup=whitespace -m "release: ${SUBJECT}" -m "${NOTES:-（本次未填写发版说明）}"
        echo "    已提交：$(git -C "$ROOT" rev-parse --short HEAD)  $(git -C "$ROOT" log -1 --pretty=%s)"
    else
        echo "    无已跟踪改动，跳过提交"
    fi
    # 2) push（已推送时是幂等空操作）
    if ! git -C "$ROOT" push origin "$BRANCH"; then
        echo "!! 中止：git push 失败（远端不可达 / 分支保护拒收 / 无上游）。修好后重跑本脚本。" >&2
        exit 1
    fi
    # 3) 复核：push 之后 HEAD 必须就是远端默认分支 HEAD（= tag 将指向的提交）
    LOCAL_SHA="$(git -C "$ROOT" rev-parse HEAD)"
    REMOTE_SHA="$(gh api "repos/$REPO/commits/$DEFAULT_BRANCH" --jq '.sha' 2>/dev/null || true)"
    if [[ "$LOCAL_SHA" != "$REMOTE_SHA" ]]; then
        # ⚠️ 变量一律写 ${VAR} 花括号形式：本机 /bin/bash 是 3.2.57 + LANG=C.UTF-8，
        #    变量名后面紧跟多字节字符（全角括号、中文标点）时，首字节会被并进变量名
        #    ⇒ 展开成垃圾、`set -u` 下直接 "unbound variable" 中止。加空格或花括号都能免疫
        echo "!! 中止：push 后 HEAD 仍与远端 ${DEFAULT_BRANCH} 不一致（远端可能刚被推过）" >&2
        echo "    本地 HEAD : ${LOCAL_SHA}" >&2
        echo "    远端 ${DEFAULT_BRANCH} : ${REMOTE_SHA}" >&2
        exit 1
    fi
    echo "    HEAD == origin/${DEFAULT_BRANCH} (${LOCAL_SHA:0:7})"
    # 未跟踪文件只提示：不进历史、不影响 tag 对齐，但 swift/ 下多出来的 .swift 会被 SwiftPM 编进去
    UNTRACKED="$(git -C "$ROOT" status --porcelain --untracked-files=all | grep '^??' || true)"
    if [[ -n "$UNTRACKED" ]]; then
        echo "⚠️  有未跟踪文件（不提交、不影响发版，仅提示；swift/ 下的 .swift 会被编进二进制）:" >&2
        printf '%s\n' "$UNTRACKED" >&2
    fi
fi

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
