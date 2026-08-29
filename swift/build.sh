#!/bin/bash
# ============================================================
# 编译 Swift 源码并打包成 iBalance.app
# 产物：../iBalance.app（可双击运行）；用户配置/缓存由 App 写入 Application Support
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/main.swift"
PLIST="$SCRIPT_DIR/Info.plist"
CONFIG="$SCRIPT_DIR/config.json"

# 产物输出到上级目录（与 .sh/.py 同级，方便分发）
# 用 cd+pwd 解析掉路径里的 "swift/../"，保证与 ps 报告的进程路径一致，避免启动验证误报
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/iBalance.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE="$MACOS_DIR/iBalance"

# 编译模式：默认 debug（-Onone + SwiftPM 跨调用增量，日常小修改只重编受影响文件 ~2s，
# 全量约 20s 的场景只出现在首次/清缓存后）；传 --release 时用 release 配置（-O + WMO，正式分发）。
# 对菜单栏小工具而言运行性能无感知差异。
BUILD_MODE="fast"
SPM_CONF="debug"
if [[ "${1:-}" == "--release" ]]; then
    SPM_CONF="release"
    BUILD_MODE="release"
fi

echo "==> 编译源文件（SwiftPM 增量，配置：${SPM_CONF}，模式：${BUILD_MODE}）"
# -explicit-module-build 不用：小项目固定开销大（SDK 预构建 55s、无改动仍 14s）
# --build-system native：显式指定 llbuild 后端（新版 SwiftPM 默认 XCBuild 后端在
# Swift 6.4-dev 上报 "Unknown error parsing property list"，native 稳定且增量更快）
swift build --package-path "$SCRIPT_DIR" -c "$SPM_CONF" --build-system native
# 产物路径由 SwiftPM 管理（swift/.build/<conf>/iBalance）；show-bin-path 不触发构建
BIN_DIR="$(swift build --package-path "$SCRIPT_DIR" -c "$SPM_CONF" --build-system native --show-bin-path)"

# 先停掉旧 iBalance 再删旧 bundle：旧进程还在跑时删 bundle，open 只会激活旧实例，
# 新二进制根本没运行。SIGTERM + 1.0s 优雅退出，随后循环等 pgrep 为空，超时升级 SIGKILL，
# 最终用"不同 PID"作为通过判据，防止 macOS SIGTERM 被忽略 / 弹窗未响应导致 open 激活老进程。
wait_iBalance_exit() {
    local start=$SECONDS elapsed killed=0
    local old_pids="$(pgrep -x iBalance 2>/dev/null)"
    [ -z "$old_pids" ] && return 0
    while pgrep -x iBalance >/dev/null 2>&1; do
        elapsed=$(( SECONDS - start ))
        if (( elapsed >= 3 && killed == 0 )); then   # SIGTERM 后 3s 仍未退出，升级 SIGKILL（更早强制）
            for p in $old_pids; do kill -9 "$p" 2>/dev/null || true; done
            killall -9 iBalance 2>/dev/null || true
            killed=1
        fi
        if (( elapsed >= 10 )); then                 # 共 10s 仍未退出（极罕见：调试器 / 系统 io hang）
            echo "!! 旧 iBalance 进程仍未退出（pid=${old_pids}），告警后仍尝试 open 新 bundle —— macOS 可能激活老实例"
            return 1
        fi
        sleep 0.1
    done
    # 确认 PID 完全不重叠：避免有同名残留新启的实例
    local any_remain=0
    for op in $old_pids; do
        if kill -0 "$op" 2>/dev/null; then any_remain=1; break; fi
    done
    return $any_remain
}

if pgrep -x iBalance >/dev/null 2>&1; then
    echo "==> 停止运行中的 iBalance"
    killall iBalance 2>/dev/null || true
    # 不再固定 sleep 1.0：wait_iBalance_exit 以 0.1s 粒度轮询退出（实测 SIGTERM 后 ~0.1s 退完）
fi
wait_iBalance_exit

echo "==> 组装 .app bundle"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# 拷贝编译产物到 MacOS/（产物由 SwiftPM 增量管理，此处只复制不重复编译）
cp "$BIN_DIR/iBalance" "$EXECUTABLE"

# 拷贝 Info.plist
cp "$PLIST" "$CONTENTS_DIR/Info.plist"

# 版本号 = 当天日期.构建号：同日多次构建递增，跨日重置为 1
# 格式：YYYY.M.D.N（如 2026.8.13.1）
# 日期无前导零（8 月=8，不是 08）；构建号来自 swift/.build_state 计数器
TODAY_M=$((10#$(date +%m)))
TODAY_D=$((10#$(date +%d)))
BASE_VER="$(date +%Y).$TODAY_M.$TODAY_D"
BUILD_STATE_FILE="$SCRIPT_DIR/.build_state"
PREV_BASE=""
PREV_NUM=0
if [[ -f "$BUILD_STATE_FILE" ]]; then
    read -r PREV_BASE PREV_NUM < "$BUILD_STATE_FILE" 2>/dev/null || true
fi
if [[ "$PREV_BASE" == "$BASE_VER" ]]; then
    BUILD_NUM=$((PREV_NUM + 1))
else
    BUILD_NUM=1
fi
echo "$BASE_VER $BUILD_NUM" > "$BUILD_STATE_FILE"
FULL_VER="$BASE_VER.$BUILD_NUM"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BASE_VER" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $FULL_VER" "$CONTENTS_DIR/Info.plist"
echo "==> 版本号：v$FULL_VER"

# 拷贝 AppIcon.icns 到 Resources（App 图标，Finder/Launchpad 显示）
if [[ -f "$SCRIPT_DIR/AppIcon.icns" ]]; then
    cp "$SCRIPT_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# 拷贝 config.json 到 Resources（作为内置 fallback）
cp "$CONFIG" "$RESOURCES_DIR/config.json"

# 拷贝全部图标 SVG 到 Resources（菜单栏 template 图标 + 面板品牌图标，品牌图标保持原色非 template）
cp "$SCRIPT_DIR/icons/"*.svg "$RESOURCES_DIR/"
# 拷贝 PNG 图标（如「关于」弹窗使用的 deepseek.png）
cp "$SCRIPT_DIR/icons/"*.png "$RESOURCES_DIR/" 2>/dev/null || true
# 拷贝 PDF 图标（菜单栏平台图标矢量版，优先于同名 SVG 加载）
cp "$SCRIPT_DIR/icons/"*.pdf "$RESOURCES_DIR/" 2>/dev/null || true

# 拷贝字体（Mono 开关：JetBrainsMonoNL-SemiBold，运行时按进程注册）
if [[ -d "$SCRIPT_DIR/fonts" ]]; then
    cp "$SCRIPT_DIR/fonts/"*.otf "$RESOURCES_DIR/" 2>/dev/null || true
    cp "$SCRIPT_DIR/fonts/"*.ttf "$RESOURCES_DIR/" 2>/dev/null || true
fi

# 代码签名（保持固定签名身份）：
# ad-hoc 签名每次编译都会生成新哈希，macOS TCC 按签名识别应用，
# 导致"完全磁盘访问"等授权每次重建都被重置；
# 用固定自签证书签名后，重建不再要求重新授权。
SIGN_IDENTITY="iBalance Local Sign"
BUNDLE_ID="com.local.ibalance"
if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "==> 代码签名（${SIGN_IDENTITY}，identifier=${BUNDLE_ID}）"
    codesign --force --identifier "$BUNDLE_ID" --sign "$SIGN_IDENTITY" "$APP_DIR"
else
    echo "!! 未找到签名证书 '$SIGN_IDENTITY'，回退 ad-hoc 签名（identifier 仍固定）"
    codesign --force --identifier "$BUNDLE_ID" --sign - "$APP_DIR" || \
        echo "!! ad-hoc 签名失败，保留 linker 签名"
fi

echo "==> 完成"
echo "    应用：$APP_DIR"
echo "    配置/缓存：~/Library/Application Support/com.local.ibalance/"
echo ""

# 重启 App：两道保险
#   1) 旧 PID 必须都退出（wait_iBalance_exit 记录的 old_pids，在第 3s 就升级 SIGKILL）
#   2) open 前再用 pgrep 确认残留，仍有就按 PID 逐个 -9，再 sleep 2s 轮询；
#      只有残留为 0 才执行 open，避免 macOS `open` 看到同名实例直接激活老进程、
#      用户以为升级成功其实一直跑旧二进制（footer 不更新等"幽灵 bug"的根源）。
wait_iBalance_exit || echo "!! wait_iBalance_exit 未完全确认退出，进入兜底"
final_start=$SECONDS
while pgrep -x iBalance >/dev/null 2>&1; do
    for p in $(pgrep -x iBalance 2>/dev/null); do
        echo "    -> 强制清理残留 pid=$p"
        kill -9 "$p" 2>/dev/null || true
    done
    sleep 0.5
    if (( SECONDS - final_start >= 6 )); then
        echo "!! 清理超时（6s），放弃重启 —— 请手动关闭 iBalance 后双击 App 启动"
        exit 1
    fi
done
open "$APP_DIR"
# 启动验证：0.1s 间隔轮询等新进程出现（实测 open 后 ~0.2s 起完），出现即验证运行路径；
# 5s 兜底超时仍无进程才告警（旧进程已由 wait_iBalance_exit 确认清空，首个 PID 即新实例）
new_pid=""
for _ in $(seq 1 50); do
    new_pid=$(pgrep -x iBalance 2>/dev/null | head -1)
    [ -n "$new_pid" ] && break
    sleep 0.1
done
if [ -n "$new_pid" ]; then
    new_cmd=$(ps -o command= -p "$new_pid" 2>/dev/null | tr -s ' ')
    if [[ "$new_cmd" == "$APP_DIR"* ]]; then
        echo "==> iBalance 已重启（pid=${new_pid}）"
    else
        echo "!! 警告：当前运行中的 iBalance 不是本次构建的 bundle"
        echo "    运行路径:  $new_cmd"
        echo "    目标 bundle: $APP_DIR/Contents/MacOS/iBalance"
    fi
else
    echo "!! iBalance 未成功启动，请手动双击 App"
fi
