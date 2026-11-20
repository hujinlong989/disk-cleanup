# 类别清单与安全边界

## 可清理类别（脚本内置）

| 类别 | 目标 | 判定条件 | 风险 |
|---|---|---|---|
| `Updater` | `AppData\Local\*-updater\` 下的安装包 | 扩展名 `.exe/.msi/.7z`，或文件名 `current.blockmap`/`update-info.json` | 安全 |
| `Temp` | `%TEMP%` 下超过 1 天未访问的 >1MB 文件 | LastWriteTime + 大小 | 安全 |
| `TaskLogs` | `.minimax\background-tasks\*.log` | 已完成（>3天）+ 单文件 >50MB | 安全 |
| `AppLog` | `.local\share\opencode\log\*.log` | >14 天 | 安全 |
| `DbBackup` | `.minimax\v2\sqlite\backups\*before-*-migration*.sqlite` | 文件名匹配迁移快照 | 安全 |
| `Installer` | `Downloads` 下的旧安装包 | **先验证软件已安装**（注册表 + 安装目录双查） | 安全 |
| `UpgradeResidue` | `AppData\Roaming\Tencent\WXWork\upgrade\` | D 盘已有同版本正式安装 | 安全 |
| `EdgeCache` | Edge 的 `Service Worker` / `Cache` / `Code Cache` | 目录整块 | 需确认 |
| `ChromeCache` | Chrome 同上 | 目录整块 | 需确认 |
| `EgoCache` | ego lite 同上 | 目录整块 | 需确认 |

## 永不删除清单

护栏 `Test-ProtectedPath` 拦截以下目标，任何分类逻辑错误都无法绕过。

### 路径级

- 用户目录：`Documents` `Desktop` `Pictures` `Videos` `Music` `OneDrive` `PycharmProjects` `.ssh` `.gnupg` `.aws` `.config`
- 系统目录：`C:\Windows` `C:\Program Files` `C:\Program Files (x86)` `C:\ProgramData` `C:\Users\Public`

### 文件/目录名级（浏览器数据）

`IndexedDB` `Local Storage` `WebStorage` `Cookies` `Bookmarks` `Login Data` `History` `Preferences` `Sessions` `Extensions` `Extension State` `Network` `Sync Data` `Web Data` `Top Sites` `Favicons` `Visited Links` `Shortcuts` `databases`

删掉这些会丢登录态或浏览器设置。

### 扩展名白名单

只允许删除这些扩展名，其余一律视为需人工判断：

`.exe .msi .zip .7z .log .tmp .dll .json .blockmap .dat .ldb .old .bak .sqlite .wal .shm`（以及无扩展名）

## 特殊排除

- **字体**：`AppData\Local\Microsoft\Windows\Fonts` 不在任何类别里，永久保留。
- **`QuarkUpdater`**：该目录放的是自更新程序本体（`updater.exe` + dll），不是缓存，删了夸克更新会坏 —— 整个目录跳过。
- **目录联接**：`.mavis` 是指向 `.minimax` 的 junction，`Local Settings` / `Application Data` 同理。统计体积时排除 `.mavis`，否则同一份数据被算两遍。

## 安装包判定

`Installer` 类别不靠文件名猜，靠**确认软件已装**：

1. 查注册表卸载项（HKLM / HKLM\WOW6432Node / HKCU）匹配 DisplayName
2. 查实际安装目录（`AppData\Local\Programs`、`C:\Program Files` 等）匹配目录名

两者任一命中才算"已安装"，才允许删安装包。

## 已知不清理项

以下是占用大但**脚本不碰**的，需要用户单独决策：

- 浏览器 IndexedDB（Edge 1.47G / Chrome）—— 站点数据，删了掉登录
- 用户字体（4.99G）—— 用户明确要求不动
- `ms-playwright`（4.41G）—— 6 个 chromium + 5 个 headless_shell 版本每一个都对应着 9 个在用的 playwright 安装，无孤儿版本可删
- `AppData\Local\pnpm\store`（0.70G）—— C 盘项目（deepseek-harness）的活跃缓存；真实 store 在 E 盘
- Docker / WSL 虚拟磁盘、VS + Windows Kits、鸿蒙模拟器镜像 —— 属于卸载决策，不是缓存
- WinSxS（11.98G）—— 需管理员权限跑 DISM 评估，脚本不提权
