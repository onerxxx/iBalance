# 项目打包说明

打包 iBalance 项目源码 + 可执行 App 为 zip 分发包时的规则。

## 核心原则

**原项目的用户数据一律不动** —— 真实 API Key / Token / 账号信息运行时保存在 `~/Library/Application Support/com.local.ibalance/`，仓库内 `swift/config.json` 只是编译模板（含真实凭据的本地快照，不进入分发包，打包时替换为初始化模板）。根目录 `config.json` 已于 2026-08-20 移除。

打包流程通过 **复制项目到临时副本** 实现：
1. 把项目整体复制到 `/tmp/iBalance_pkg/iBalance`
2. 在 **副本** 里把构建模板和 App Resources 中的 `config.json` 替换为初始化模板
3. 打包副本
4. 删除副本

原项目目录全程零修改，无需退出运行中的 App，无需备份还原。

## 一、初始化 config.json 模板

打包时写入 **副本** 两处模板的初始化内容（清空所有用户隐私数据）：

| 副本内路径 | 说明 |
|-----------|------|
| `swift/config.json` | 编译模板（构建时复制到 App Resources） |
| `iBalance.app/Contents/Resources/config.json` | App bundle 内运行时配置 |

```json
{
  "cockpit_app_id" : "com.jlcodes.cockpit-tools",
  "debug_mode" : false,
  "deepseek_api_key" : "",
  "deepseek_common_quota" : 10,
  "hide_main_icon" : true,
  "hide_wb_nickname" : false,
  "menubar_visible" : {},
  "refresh_interval" : 300,
  "trae_accounts" : [],
  "trae_auto_checkin" : false,
  "trae_decimals" : 0,
  "trae_storage_path" : "",
  "workbuddy_accounts" : [],
  "workbuddy_auto_checkin" : false,
  "workbuddy_decimals" : 0,
  "workbuddy_enabled" : true,
  "zcode_accounts" : [],
  "codex_accounts" : []
}
```

要点：
- `deepseek_api_key` 清空
- `trae_storage_path` 清空
- `workbuddy_accounts` / `trae_accounts` / `zcode_accounts` / `codex_accounts` 清空数组（删除所有 token / refresh_token / auth_info / uid）
- `trae_auto_checkin` / `workbuddy_auto_checkin` 关闭
- `debug_mode` 关闭
- `refresh_interval` 恢复默认 300 秒

> ⚠️ 本模板与第三节脚本中的 `INIT_CONFIG` 是同一份内容的两处拷贝。**新增/删除配置字段时必须两处同步修改**，字段集合以 `swift/Config.swift` 的 `CodingKeys` 为准。

## 二、打包排除清单

复制副本时就排除以下内容（不进入副本，自然不进 zip）：

| 排除路径 | 原因 |
|---------|------|
| `backups/` | 项目历史备份，与发行版无关 |
| `cockpit-tools-main/` | Cockpit Tools 参考源码（约 52MB），与发行版无关 |
| `docs/` | 开发文档（segmented control 指南等），与发行版无关 |
| `cache.json` | 运行时缓存（含账号用量数据），属用户隐私 |
| `click_ibalance.lua` | Hammerspoon 调试脚本，仅开发用 |
| `iBalance-已损坏说明.html` | 本机说明页，不进分发包 |
| `iBalance*.zip`（含 `iBalance.zip`、`iBalance-v*.zip`、`iBalance 1.0.zip` 等） | 已存在的 zip 文件，避免套娃。**注意排除模式必须覆盖带空格/带版本号的文件名**，只写 `iBalance.zip` + `iBalance-v*.zip` 会漏掉 `iBalance 1.0.zip`（历史上已踩过坑，2MB 的旧包被套进了新包） |
| `.git/` | 版本控制元数据 |
| `.reasonix/` | IDE / 工具临时数据 |
| `.workbuddy/` | 本地 WorkBuddy 调试数据 |
| `__pycache__/` | Python 字节码缓存（调试脚本用） |
| `swift/.build/` | Swift 编译中间产物 |
| `swift/.build_state` | 构建状态文件 |
| `.DS_Store` | macOS 文件系统元数据（rsync 中无 `/` 的模式匹配任意层级，递归排除） |

## 三、打包命令

> 版本号取自已编译 `iBalance.app/Contents/Info.plist` 的 `CFBundleVersion`（唯一权威来源，格式如 `2026.8.17.1`，末尾 `.1` 为当日构建序号，同日多次打包自动递增），
> 产物命名为 `iBalance-v<完整版本>.zip`。**发版前必须先跑 `swift/build.sh` 重建 App**，
> 因为构建序号在编译时才写入 App bundle，`swift/Info.plist` 里的版本号是占位值不可用。

```bash
SRC=/Volumes/850Pro_256G/htmls/iBalance
PKG_DIR=/tmp/iBalance_pkg
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$SRC/iBalance.app/Contents/Info.plist")
ZIP_OUT=$SRC/iBalance-v$VER.zip
echo "打包版本: v$VER -> $ZIP_OUT"

# 1. 准备临时副本目录（旧副本清空重来）
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"

# 2. 复制项目到副本，排除清单见第二节（原项目零修改）
rsync -a \
  --exclude 'backups/' \
  --exclude 'cockpit-tools-main/' \
  --exclude 'docs/' \
  --exclude 'cache.json' \
  --exclude 'click_ibalance.lua' \
  --exclude 'iBalance-已损坏说明.html' \
  --exclude '.reasonix/' \
  --exclude '.git/' \
  --exclude '.workbuddy/' \
  --exclude '__pycache__/' \
  --exclude 'swift/.build/' \
  --exclude 'swift/.build_state' \
  --exclude 'iBalance*.zip' \
  --exclude '.DS_Store' \
  "$SRC/" "$PKG_DIR/iBalance/"

# 3. 在副本里把两个运行时模板 config.json 替换为初始化模板（内容见第一节）
INIT_CONFIG='{
  "cockpit_app_id" : "com.jlcodes.cockpit-tools",
  "debug_mode" : false,
  "deepseek_api_key" : "",
  "deepseek_common_quota" : 10,
  "hide_main_icon" : true,
  "hide_wb_nickname" : false,
  "menubar_visible" : {},
  "refresh_interval" : 300,
  "trae_accounts" : [],
  "trae_auto_checkin" : false,
  "trae_decimals" : 0,
  "trae_storage_path" : "",
  "workbuddy_accounts" : [],
  "workbuddy_auto_checkin" : false,
  "workbuddy_decimals" : 0,
  "workbuddy_enabled" : true,
  "zcode_accounts" : [],
  "codex_accounts" : []
}'

echo "$INIT_CONFIG" > "$PKG_DIR/iBalance/swift/config.json"
echo "$INIT_CONFIG" > "$PKG_DIR/iBalance/iBalance.app/Contents/Resources/config.json"

# 4. 从副本目录打包（zip 内顶层是 iBalance/）
rm -f "$ZIP_OUT"
( cd "$PKG_DIR" && zip -r -q -X "$ZIP_OUT" iBalance )

# 5. 删除临时副本
rm -rf "$PKG_DIR"

# 原项目用户数据全程未动，无需还原
# 历史 zip（含旧的 iBalance.zip / iBalance-v*.zip）因排除规则不会进入新包，可保留作存档
```

## 四、打包后校验

> 以下命令假设当前目录为项目**上级**目录（`/Volumes/850Pro_256G/htmls`），先 `cd` 过去再执行。
> `ZIP` 指向刚打出的包（按实际版本号调整，或先 `ZIP=$(ls -t iBalance/iBalance-v*.zip | head -1)` 自动取最新）。

```bash
ZIP=iBalance/iBalance-v2026.8.17.1.zip

# 1. 模板 config.json 应为初始化版大小，不应出现含真实 token 的大文件
unzip -l "$ZIP" | grep config.json

# 2. 内容级防泄漏校验（比体积更可靠）：模板 config 的敏感字段必须为空
for f in swift/config.json iBalance.app/Contents/Resources/config.json; do
  unzip -p "$ZIP" "iBalance/$f" | python3 -c "
import json,sys
d = json.load(sys.stdin)
leaks = [k for k in ('deepseek_api_key','trae_storage_path') if d.get(k)]
for k in ('workbuddy_accounts','trae_accounts','zcode_accounts','codex_accounts'):
    if d.get(k): leaks.append(k)
print('$f', 'LEAK:' if leaks else 'OK', leaks)"
done

# 3. 应排除项应为空（含任何形式的嵌套 zip）
unzip -l "$ZIP" | grep -E 'backups/|cockpit-tools-main/|docs/|cache\.json|click_ibalance\.lua|已损坏说明|\.reasonix/|\.git/|\.workbuddy/|__pycache__/|\.build/|\.build_state|iBalance[^/]*\.zip'

# 4. zip 内 App 的完整版本号应与文件名一致（plutil 不支持读 stdin，需经临时文件）
TMP_PLIST=$(mktemp)
unzip -p "$ZIP" iBalance/iBalance.app/Contents/Info.plist > "$TMP_PLIST"
/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$TMP_PLIST"
rm -f "$TMP_PLIST"

# 5. 顶层条目
unzip -l "$ZIP" | awk '{print $4}' | grep -E '^iBalance/[^/]+/?$' | sort -u

# 6. 原项目用户配置不进入 zip；运行时会从 Application Support 读取
```

## 五、zip 内应包含的内容

```
iBalance/
├── AGENT.md
├── IMPROVEMENTS.md
├── PACKAGING.md
├── macos-panel-ui-guide.md
├── reasonix.toml
├── .gitignore
├── iBalance.app/                ← 可执行 App（含初始化 config）
├── swift/                       ← 源码
│   ├── Services/
│   │   ├── DeepSeek.swift
│   │   ├── Trae.swift
│   │   ├── WorkBuddy.swift
│   │   └── Zcode.swift
│   ├── icons/
│   ├── AppIcon.icns
│   ├── Config.swift
│   ├── Crypto.swift
│   ├── Info.plist
│   ├── Logger.swift
│   ├── Network.swift
│   ├── Panel.swift
│   ├── ProcessUtil.swift
│   ├── build.sh
│   ├── config.json              ← 初始化版（475B）
│   └── main.swift
```
