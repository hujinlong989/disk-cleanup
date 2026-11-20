# disk-cleanup

Windows 磁盘空间体检与清理 skill —— 给 MiniMax Code / Claude Code 用的磁盘清理助手。

> ⚠️ **这是一个会删文件的工具。** 所有删除都走 Windows 回收站（可恢复），但请先读 [安全设计](#安全设计) 再用。

## 它解决什么问题

C 盘满了 → 不知道哪些能删、哪些不能删 → 让 AI 自己扫全盘 → 扫出来一堆 `node_modules` 和浏览器数据，删错就丢登录态。

这个 skill 把判断固化下来：**只删「删了会自动重建」的东西**，其余一律不碰。

## 效果

| 场景 | 释放 |
|---|---|
| Edge / Chrome / ego lite 离线缓存 | 8.19G / 2.81G / 1.13G |
| 应用更新安装包残留（updater） | 1.92G |
| 企业微信升级残留 | 2.04G |
| 过期日志、临时文件、SQLite 迁移快照 | 0.7G+ |

## 安装

把整个文件夹放进对应客户端的 skills 目录：

**MiniMax Code**

```powershell
git clone <this-repo> "$env:USERPROFILE\.minimax\skills\disk-cleanup"
```

**Claude Code**

```powershell
git clone <this-repo> "$env:USERPROFILE\.claude\skills\disk-cleanup"
```

两份可以并存（内容相同），也可以只装一份。

## 使用

装好后不用手动跑。对 AI 说「C盘没空间了，帮我清理一下」就会触发。

也可以直接跑脚本：

```powershell
pwsh -File scripts/disk-clean.ps1              # 体检，只报告不删
pwsh -File scripts/disk-clean.ps1 -Clean       # 清理全部安全类
pwsh -File scripts/disk-clean.ps1 -Deep        # 深挖已知类别之外的大头
pwsh -File scripts/disk-clean.ps1 -Json        # JSON 输出，便于程序化处理
pwsh -File scripts/disk-clean.ps1 -Clean -Category Updater,Temp   # 只清指定类
```

| 参数 | 说明 |
|---|---|
| `-Clean` | 执行清理。缺省只做体检，不动任何文件 |
| `-Category` | 仅处理指定类别 |
| `-Deep` | 扫描一级目录，定位已知类别之外的大头（较慢） |
| `-ThresholdGB` | 报告阈值，缺省 0.05 |
| `-Json` | 输出 JSON |
| `-NoRecycleBin` | 跳过回收站直接永久删除（不可恢复） |

## 安全设计

三层保障，**不依赖 AI 的自觉**：

**1. 两层护栏（`Test-ProtectedPath`）**

- 路径级：用户文档 / 桌面 / 图片 / 视频 / 音乐 / OneDrive / 源码目录 / `.ssh` / `.gnupg` / `.aws` / `.config`、`C:\Windows`、`C:\Program Files`、`C:\ProgramData`、`C:\Users\Public`
- 名称级：`IndexedDB`、`Local Storage`、`WebStorage`、`Cookies`、`Bookmarks`、`Login Data`、`History`、`Preferences`、`Sessions`、`Extensions`、`Network`、`Sync Data`、`Web Data`、`databases` 等浏览器数据目录
- 扩展名白名单：只允许删 `.exe .msi .zip .7z .log .tmp .dll .json .blockmap .dat .ldb .old .bak .sqlite .wal .shm` 和无扩展名文件

**2. 只进回收站**

删除一律走 `Microsoft.VisualBasic.FileIO.FileSystem::DeleteFile/SendToRecycleBin`，不永久抹除。

**3. 不自动清空回收站**

清空回收站不可逆，会连带抹掉用户自己手动删的文件。脚本只报告回收站当前占用，由你自己决定何时清空。

**特殊排除**

- **用户字体**（`AppData\Local\Microsoft\Windows\Fonts`）不在任何清理类别里，永久保留
- **QuarkUpdater** 整个目录跳过 —— 里面是自更新程序本体（`updater.exe` + dll），不是缓存，删了夸克更新会坏
- **NTFS junction**（`.mavis`、`Local Settings`、`Application Data`）在统计体积时排除，否则同一份数据被算两遍

**安装包不靠文件名猜** —— `Installer` 类别要同时满足「注册表卸载项有它」和「安装目录找得到它」才允许删，避免把还没装上的软件安装包清掉。

## 追溯

每次清理的完整路径清单写到 `%TEMP%\disk-cleanup-logs\deleted-<时间戳>.txt`，删错了可以照着找回来。

## 边界

- **Windows 专用**（PowerShell），PowerShell 7 (`pwsh`) 和 Windows PowerShell 5.1 都能跑
- **只管 C 盘用户目录**。其他盘需要手工分拣 —— 脚本的 `-Deep` 根目录扫描会覆盖到，但清理逻辑不跨盘
- 不做：卸载软件、删除单个指定文件、整理用户文档、分区或格式化
- 管理员权限的操作（如 DISM 清理 WinSxS）脚本不提权，会如实报告让用户自己用管理员终端跑

## 已知可移植性问题

`scripts/disk-clean.ps1` 中 `UpgradeResidue`（企业微信升级残留）类别硬编码了 `D:\Program Files (x86)\WXWork`。换一台机器这个路径不成立，该类别会静默失效 —— 其他类别不受影响。

## License

MIT
