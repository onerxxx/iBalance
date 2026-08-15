# 项目打包说明

打包 iBalance 项目源码 + 可执行 App 为 zip 分发包时的规则。

## 核心原则

**原项目的 `config.json` 一律不动** —— 用户的真实 API Key / Token / 账号信息必须保留。

打包流程通过 **复制项目到临时副本** 实现：
1. 把项目整体复制到 `/tmp/iBalance_pkg/iBalance`
2. 在 **副本** 里把三处 `config.json` 替换为初始化模板
3. 打包副本
4. 删除副本

原项目目录全程零修改，无需退出运行中的 App，无需备份还原。

## 一、初始化 config.json 模板

打包时写入 **副本** 三处的初始化内容（清空所有用户隐私数据）：

| 副本内路径 | 说明 |
|-----------|------|
| `config.json` | 根目录用户配置（用户编辑这份） |
| `swift/config.json` | 编译模板（`build.sh` 会用它覆盖根目录） |
| `iBalance.app/Contents/Resources/config.json` | App bundle 内运行时配置 |

```json
{
  "cockpit_app_id" : "com.jlcodes.cockpit-tools",
  "deepseek_api_key" : "",
  "deepseek_decimals" : 2,
  "hide_main_icon" : true,
  "qianwen_decimals" : 1,
  "qianwen_ticket" : "",
  "refresh_interval" : 300,
  "trae_auto_checkin" : false,
  "trae_decimals" : 0,
  "trae_storage_path" : "",
  "workbuddy_accounts" : [],
  "workbuddy_auto_checkin" : false,
  "workbuddy_decimals" : 0,
  "workbuddy_enabled" : true
}
```

要点：
- `deepseek_api_key` 清空
- `qianwen_ticket` 清空
- `trae_storage_path` 清空
- `workbuddy_accounts` 清空数组（删除所有 token / refresh_token / uid）
- `trae_auto_checkin` / `workbuddy_auto_checkin` 关闭
- `refresh_interval` 恢复默认 300 秒

> ⚠️ 本模板与第三节脚本中的 `INIT_CONFIG` 是同一份内容的两处拷贝。**新增/删除配置字段时必须两处同步修改**，且字段集合要与真实 `config.json` 对齐（可用 `python3 -c "import json;print(sorted(json.load(open('config.json'))))"` 对比）。

## 二、打包排除清单

复制副本时就排除以下内容（不进入副本，自然不进 zip）：

| 排除路径 | 原因 |
|---------|------|
| `backups/` | 项目历史备份，与发行版无关 |
| `iBalance*.zip`（含 `iBalance.zip`、`iBalance-v*.zip`、`iBalance 1.0.zip` 等） | 已存在的 zip 文件，避免套娃。**注意排除模式必须覆盖带空格/带版本号的文件名**，只写 `iBalance.zip` + `iBalance-v*.zip` 会漏掉 `iBalance 1.0.zip`（历史上已踩过坑，2MB 的旧包被套进了新包） |
| `.git/` | 版本控制元数据 |
| `.reasonix/` | IDE / 工具临时数据 |
| `.workbuddy/` | 本地 WorkBuddy 调试数据 |
| `__pycache__/` | Python 字节码缓存（调试脚本用） |
| `swift/.build/` | Swift 编译中间产物 |
| `swift/.build_state` | 构建状态文件 |
| `swift-tools/click` / `swift-tools/presskey` | 已编译的二进制工具，仅保留源码 |
| `.DS_Store` | macOS 文件系统元数据（rsync 中无 `/` 的模式匹配任意层级，递归排除） |

## 三、打包命令

> 版本号取自 `swift/Info.plist` 的 `CFBundleShortVersionString`（唯一权威来源，格式如 `2026.8.13`），
> 产物命名为 `iBalance-v<版本>.zip`。**发版前若 bump 了版本号，先跑 `swift/build.sh` 重建 App**，
> 否则 zip 里的 `iBalance.app` 还是旧版本。

```bash
SRC=/Volumes/850Pro_256G/htmls/iBalance
PKG_DIR=/tmp/iBalance_pkg
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SRC/swift/Info.plist")
ZIP_OUT=$SRC/iBalance-v$VER.zip
echo "打包版本: v$VER -> $ZIP_OUT"

# 1. 准备临时副本目录（旧副本清空重来）
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR"

# 2. 复制项目到副本，排除清单见第二节（原项目零修改）
rsync -a \
  --exclude 'backups/' \
  --exclude '.reasonix/' \
  --exclude '.git/' \
  --exclude '.workbuddy/' \
  --exclude '__pycache__/' \
  --exclude 'swift/.build/' \
  --exclude 'swift/.build_state' \
  --exclude 'iBalance*.zip' \
  --exclude 'swift-tools/click' \
  --exclude 'swift-tools/presskey' \
  --exclude '.DS_Store' \
  "$SRC/" "$PKG_DIR/iBalance/"

# 3. 在副本里把三处 config.json 替换为初始化模板（内容见第一节）
INIT_CONFIG='{
  "cockpit_app_id" : "com.jlcodes.cockpit-tools",
  "deepseek_api_key" : "",
  "deepseek_decimals" : 2,
  "hide_main_icon" : true,
  "qianwen_decimals" : 1,
  "qianwen_ticket" : "",
  "refresh_interval" : 300,
  "trae_auto_checkin" : false,
  "trae_decimals" : 0,
  "trae_storage_path" : "",
  "workbuddy_accounts" : [],
  "workbuddy_auto_checkin" : false,
  "workbuddy_decimals" : 0,
  "workbuddy_enabled" : true
}'

echo "$INIT_CONFIG" > "$PKG_DIR/iBalance/config.json"
echo "$INIT_CONFIG" > "$PKG_DIR/iBalance/swift/config.json"
echo "$INIT_CONFIG" > "$PKG_DIR/iBalance/iBalance.app/Contents/Resources/config.json"

# 4. 从副本目录打包（zip 内顶层是 iBalance/）
rm -f "$ZIP_OUT"
( cd "$PKG_DIR" && zip -r -q -X "$ZIP_OUT" iBalance )

# 5. 删除临时副本
rm -rf "$PKG_DIR"

# 原项目 config.json 全程未动，无需还原
# 历史 zip（含旧的 iBalance.zip / iBalance-v*.zip）因排除规则不会进入新包，可保留作存档
```

## 四、打包后校验

> 以下命令假设当前目录为项目**上级**目录（`/Volumes/850Pro_256G/htmls`），先 `cd` 过去再执行。
> `ZIP` 指向刚打出的包（按实际版本号调整，或先 `ZIP=$(ls -t iBalance/iBalance-v*.zip | head -1)` 自动取最新）。

```bash
ZIP=iBalance/iBalance-v2026.8.13.zip

# 1. config.json 体积应均为 418B（初始化版），不应出现 4974B（含真实 token）
unzip -l "$ZIP" | grep config.json

# 2. 内容级防泄漏校验（比体积更可靠）：三处 config 的敏感字段必须为空
for f in config.json swift/config.json iBalance.app/Contents/Resources/config.json; do
  unzip -p "$ZIP" "iBalance/$f" | python3 -c "
import json,sys
d = json.load(sys.stdin)
leaks = [k for k in ('deepseek_api_key','qianwen_ticket','trae_storage_path') if d.get(k)]
if d.get('workbuddy_accounts'): leaks.append('workbuddy_accounts')
print('$f', 'LEAK:' if leaks else 'OK', leaks)"
done

# 3. 应排除项应为空（含任何形式的嵌套 zip）
unzip -l "$ZIP" | grep -E 'backups/|\.reasonix/|\.git/|\.workbuddy/|__pycache__/|\.build/|\.build_state|/click$|/presskey$|iBalance[^/]*\.zip'

# 4. zip 内 App 的版本号应与文件名一致（plutil 不支持读 stdin，需经临时文件）
TMP_PLIST=$(mktemp)
unzip -p "$ZIP" iBalance/iBalance.app/Contents/Info.plist > "$TMP_PLIST"
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$TMP_PLIST"
rm -f "$TMP_PLIST"

# 5. 顶层条目
unzip -l "$ZIP" | awk '{print $4}' | grep -E '^iBalance/[^/]+/?$' | sort -u

# 6. 原项目 config 未被修改（应仍含真实 api_key）
grep deepseek_api_key iBalance/config.json
```

## 五、zip 内应包含的内容

```
iBalance/
├── AGENT.md
├── CHANGELOG.md
├── IMPROVEMENTS.md
├── PACKAGING.md
├── reasonix.toml
├── .gitignore
├── config.json                  ← 初始化版（418B）
├── iBalance.app/                ← 可执行 App（含初始化 config）
├── swift/                       ← 源码
│   ├── Services/
│   ├── icons/
│   ├── AppIcon.icns
│   ├── Config.swift
│   ├── Crypto.swift
│   ├── Info.plist
│   ├── Network.swift
│   ├── Panel.swift
│   ├── build.sh
│   ├── config.json              ← 初始化版（418B）
│   └── main.swift
└── swift-tools/                 ← 辅助工具源码
    ├── click.swift
    └── presskey.swift
```
