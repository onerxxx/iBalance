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
APP_DIR="$SCRIPT_DIR/../iBalance.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE="$MACOS_DIR/iBalance"

# 收集 swift/ 下所有 .swift（含 Services/ 子目录）作为编译输入
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$SCRIPT_DIR" -maxdepth 2 -name "*.swift" | sort)

# 编译优化级别：默认 -Onone（快速编译，适合日常小修改迭代，实测比 -O 快 ~3.7 倍）；
# 传 --release 参数时用 -O（优化构建，用于正式分发）。
# 对菜单栏小工具而言两者运行性能无感知差异。
OPT_FLAG="-Onone"
BUILD_MODE="fast"
if [[ "${1:-}" == "--release" ]]; then
    OPT_FLAG="-O"
    BUILD_MODE="release"
fi

echo "==> 编译源文件（${#SOURCES[@]} 个 .swift，模式：${BUILD_MODE}）"
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
    "$OPT_FLAG" \
    "${SOURCES[@]}" \
    -o "$SCRIPT_DIR/iBalance"

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
            echo "!! 旧 iBalance 进程仍未退出（pid=$old_pids），告警后仍尝试 open 新 bundle —— macOS 可能激活老实例"
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
    sleep 1.0
fi
wait_iBalance_exit

echo "==> 组装 .app bundle"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# 移动编译产物到 MacOS/
mv "$SCRIPT_DIR/iBalance" "$EXECUTABLE"

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

# 拷贝字体（Mono 开关：DepartureMono，运行时按进程注册）
if [[ -d "$SCRIPT_DIR/fonts" ]]; then
    cp "$SCRIPT_DIR/fonts/"*.otf "$RESOURCES_DIR/" 2>/dev/null || true
    cp "$SCRIPT_DIR/fonts/"*.ttf "$RESOURCES_DIR/" 2>/dev/null || true
fi

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
# 启动验证：新进程 PID ≠ 原 PID（若 open 激活的是其他旧 bundle 会告警）
sleep 2
new_pid=$(pgrep -x iBalance 2>/dev/null | head -1)
if [ -n "$new_pid" ]; then
    new_cmd=$(ps -o command= -p "$new_pid" 2>/dev/null | tr -s ' ')
    if [[ "$new_cmd" == "$APP_DIR"* ]]; then
        echo "==> iBalance 已重启（pid=$new_pid）"
    else
        echo "!! 警告：当前运行中的 iBalance 不是本次构建的 bundle"
        echo "    运行路径:  $new_cmd"
        echo "    目标 bundle: $APP_DIR/Contents/MacOS/iBalance"
    fi
else
    echo "!! iBalance 未成功启动，请手动双击 App"
fi
