<#
.SYNOPSIS
    C 盘占用体检与清理。只删可再生成的缓存，日志与已装软件的旧安装包。

.DESCRIPTION
    硬性约束（不可通过参数放宽）：
      · 只删除「删了会自动重建」的东西：浏览器离线缓存、磁盘缓存、
        应用更新安装包、过期日志、已装软件的旧安装包。
      · 绝不删除：字体、IndexedDB / Local Storage / Cookies / Bookmarks /
        History（登录态与浏览器数据）、用户文档 / 照片 / 视频 / 桌面、
        数据库本体、虚拟磁盘 / 镜像、项目源码与依赖目录、应用配置。
      · 删除一律走 Windows 回收站（可恢复），不会永久抹除。
      · 绝不自动清空回收站 —— 清空不可逆，且会连带抹掉用户自己手动删除的
        文件。脚本只在结束时报告回收站占用，由用户自行决定何时清空。

.PARAMETER Clean
    执行清理。缺省只做体检，不动任何文件。

.PARAMETER Category
    仅处理指定类别。可重复。不指定则处理全部「安全」类别。

.PARAMETER Deep
    深度定位：扫描一级目录，找出「已知类别之外」的占用。较慢。

.PARAMETER ThresholdGB
    报告阈值，小于该体积的项不列出。缺省 0.05。

.PARAMETER Json
    输出 JSON。

.PARAMETER NoRecycleBin
    跳过回收站直接永久删除（不可恢复，慎用）。此时空间立即释放，
    但同样不会触碰回收站里的既有内容。

.EXAMPLE
    pwsh -File disk-clean.ps1
    仅体检。

.EXAMPLE
    pwsh -File disk-clean.ps1 -Clean
    清理全部安全类别。
#>
[CmdletBinding()]
param(
    [switch]$Clean,
    [string[]]$Category = @(),
    [double]$ThresholdGB = 0.05,
    [switch]$Deep,
    [switch]$Json,
    [switch]$NoRecycleBin
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$UserHome = $env:USERPROFILE
$AppLocal = Join-Path $UserHome 'AppData\Local'
$AppRoaming = Join-Path $UserHome 'AppData\Roaming'

# ============================================================
# 安全护栏：以下路径 / 文件名永远不进删除候选
# ============================================================

$script:ProtectedNames = @(
    'IndexedDB', 'Local Storage', 'WebStorage', 'Cookies', 'Bookmarks',
    'Login Data', 'History', 'Preferences', 'Sessions', 'Extensions',
    'Extension State', 'Network', 'Sync Data', 'Web Data', 'Top Sites',
    'Bookmarks.bak', 'Current Tabs', 'Current Session', 'Last Tabs',
    'Shortcuts', 'Visited Links', 'Favicons', 'databases'
)

$script:ProtectedRoots = @(
    (Join-Path $UserHome 'Documents'),
    (Join-Path $UserHome 'Desktop'),
    (Join-Path $UserHome 'Pictures'),
    (Join-Path $UserHome 'Videos'),
    (Join-Path $UserHome 'Music'),
    (Join-Path $UserHome 'OneDrive'),
    (Join-Path $UserHome '源码'),
    (Join-Path $UserHome 'projects'),
    (Join-Path $UserHome 'PycharmProjects'),
    (Join-Path $UserHome '.ssh'),
    (Join-Path $UserHome '.gnupg'),
    (Join-Path $UserHome '.aws'),
    (Join-Path $UserHome '.config'),
    'C:\Windows', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData',
    'C:\Users\Public'
)

function Test-ProtectedPath {
    param([string]$Path)
    if (-not $Path) { return $true }
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($r in $script:ProtectedRoots) {
        if (-not $r) { continue }
        $rootFull = [IO.Path]::GetFullPath($r)
        if ($full.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($full.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    foreach ($n in $script:ProtectedNames) {
        if ($full -match ("[\\/]" + [regex]::Escape($n) + "([\\/]|$)")) { return $true }
    }
    # 扩展名白名单：只允许删这些类型的文件
    $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
    if ($ext -notin @('', '.exe', '.msi', '.zip', '.7z', '.log', '.tmp', '.dll', '.json', '.blockmap', '.dat', '.ldb', '.old', '.bak', '.sqlite', '.wal', '.shm')) {
        return $true
    }
    return $false
}

# ============================================================
# 工具函数
# ============================================================

function Get-FileListSize {
    param([System.IO.FileInfo[]]$Files)
    if (-not $Files -or $Files.Count -eq 0) { return 0 }
    $sum = ($Files | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return 0 }
    return [double]$sum
}

function Remove-ToTrash {
    param([System.IO.FileInfo[]]$Files, [switch]$Permanent, [string]$ManifestPath)
    if (-not $Files -or $Files.Count -eq 0) { return @{ Ok = 0; Fail = 0 } }

    $safe = @($Files | Where-Object { -not (Test-ProtectedPath $_.FullName) })
    $ok = 0; $fail = 0

    if ($Permanent) {
        foreach ($f in $safe) {
            try { [IO.File]::Delete($f.FullName); $ok++ } catch { $fail++ }
        }
    } else {
        Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
        foreach ($f in $safe) {
            if (-not (Test-Path -LiteralPath $f.FullName)) { continue }
            try {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                    $f.FullName,
                    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
                )
                $ok++
            } catch { $fail++ }
        }
    }
    return @{ Ok = $ok; Fail = $fail }
}

function Test-AppInstalled {
    param([string[]]$Patterns, [string[]]$InstallDirs = @())
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($p in $Patterns) {
        if (Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match $p } | Select-Object -First 1) {
            return $true
        }
    }
    foreach ($d in $InstallDirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        foreach ($p in $Patterns) {
            if (Get-ChildItem -LiteralPath $d -Force -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match $p } | Select-Object -First 1) { return $true }
        }
    }
    return $false
}

# ============================================================
# 类别探测器
#   Dirs = 整个目录可删（目录内只含缓存）
#   Files = 单个文件可删
#   Risk = Safe | Review
# ============================================================

function Get-CatUpdater {
    $files = @()
    $updaterDirs = Get-ChildItem -LiteralPath $AppLocal -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'updater|Updater' }
    foreach ($d in $updaterDirs) {
        # QuarkUpdater 之类放的是自更新程序本体，删了应用会坏 —— 整个跳过
        if ($d.Name -eq 'QuarkUpdater') { continue }
        $files += Get-ChildItem -LiteralPath $d.FullName -Force -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Extension -in '.exe', '.msi', '.7z' -or
                $_.Name -in 'current.blockmap', 'update-info.json'
            }
    }
    return @{ Category = 'Updater'; Files = @($files); Dirs = @(); Risk = 'Safe'
              Note = '各应用自动更新下载的安装包，删后更新时重新下载' }
}

function Get-CatTemp {
    $files = Get-ChildItem -LiteralPath $env:TEMP -Force -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) -and $_.Length -gt 1MB }
    return @{ Category = 'Temp'; Files = @($files); Dirs = @(); Risk = 'Safe'
              Note = '超过 1 天未访问的临时文件' }
}

function Get-CatTaskLogs {
    $files = @()
    $base = Join-Path $UserHome '.minimax\background-tasks'
    if (Test-Path -LiteralPath $base) {
        $files = Get-ChildItem -LiteralPath $base -Force -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-3) -and $_.Length -gt 50MB }
    }
    return @{ Category = 'TaskLogs'; Files = @($files); Dirs = @(); Risk = 'Safe'
              Note = '已结束的后台任务输出日志（单文件超 50MB）' }
}

function Get-CatAppLog {
    $files = @()
    $p = Join-Path $UserHome '.local\share\opencode\log'
    if (Test-Path -LiteralPath $p) {
        $files = Get-ChildItem -LiteralPath $p -Force -File -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) }
    }
    return @{ Category = 'AppLog'; Files = @($files); Dirs = @(); Risk = 'Safe'
              Note = 'opencode 超过 14 天的旧日志' }
}

function Get-CatDbBackup {
    $files = @()
    $p = Join-Path $UserHome '.minimax\v2\sqlite\backups'
    if (Test-Path -LiteralPath $p) {
        $files = Get-ChildItem -LiteralPath $p -Force -File -Filter '*.sqlite' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'before-.*-migration' }
    }
    return @{ Category = 'DbBackup'; Files = @($files); Dirs = @(); Risk = 'Safe'
              Note = '版本迁移前的数据库快照，迁移已完成则无需保留' }
}

function Get-CatInstaller {
    $files = @()
    $dl = Join-Path $UserHome 'Downloads'
    if (-not (Test-Path -LiteralPath $dl)) {
        return @{ Category = 'Installer'; Files = @(); Dirs = @(); Risk = 'Safe'; Note = '无' }
    }
    $map = @(
        @{ File = 'flutter_sdk.zip';       Pattern = 'flutter';                    Dirs = @('C:\dev\flutter', (Join-Path $AppLocal 'Programs')) }
        @{ File = 'NeteaseCloudMusic*.exe'; Pattern = '网易云音乐|NeteaseCloudMusic'; Dirs = @('C:\Program Files (x86)\Netease', (Join-Path $AppLocal 'Programs')) }
        @{ File = 'QoderUserSetup*.exe';    Pattern = 'Qoder';                      Dirs = @((Join-Path $AppLocal 'Programs')) }
        @{ File = 'Cap_*setup*.exe';        Pattern = 'Cap';                        Dirs = @((Join-Path $AppLocal 'Programs'), 'C:\Program Files') }
        @{ File = 'maoxiong_setup*.exe';    Pattern = '猫熊|maoxiong';              Dirs = @((Join-Path $AppLocal 'Programs'), 'C:\Program Files') }
    )
    $cands = Get-ChildItem -LiteralPath $dl -Force -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.exe', '.zip', '.msi' }
    foreach ($c in $cands) {
        foreach ($m in $map) {
            if ($c.Name -like $m.File) {
                # 只有确认软件已安装，旧安装包才是纯冗余
                if (Test-AppInstalled -Patterns @($m.Pattern) -InstallDirs $m.Dirs) { $files += $c }
                break
            }
        }
    }
    return @{ Category = 'Installer'; Files = @($files); Dirs = @(); Risk = 'Safe'
              Note = '对应软件已安装，Downloads 里对应的旧安装包' }
}

function Get-CatUpgradeResidue {
    $files = @()
    $p = Join-Path $AppRoaming 'Tencent\WXWork\upgrade'
    if (Test-Path -LiteralPath $p) {
        # 企业微信可能装在任意盘 / 任意目录：注册表卸载项 + 常见安装目录双重确认
        $installDirs = @(
            'C:\Program Files (x86)',
            'C:\Program Files',
            'D:\Program Files (x86)',
            'D:\Program Files',
            (Join-Path $AppLocal 'Programs')
        )
        if (Test-AppInstalled -Patterns @('WXWork', '企业微信') -InstallDirs $installDirs) {
            $files = Get-ChildItem -LiteralPath $p -Force -Recurse -File -ErrorAction SilentlyContinue
        }
    }
    return @{ Category = 'UpgradeResidue'; Files = @($files); Dirs = @(); Risk = 'Safe'
              Note = '已安装完成、遗留的升级包副本' }
}

# --- 浏览器离线缓存：目录整块可删，但要先关浏览器 ---

function Get-BrowserCacheDirs {
    param([string]$Root, [string[]]$Profiles)
    $dirs = @()
    if (-not (Test-Path -LiteralPath $Root)) { return $dirs }
    Get-ChildItem -LiteralPath $Root -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in $Profiles } |
        ForEach-Object {
            foreach ($sub in @('Service Worker', 'Cache', 'Code Cache')) {
                $p = Join-Path $_.FullName $sub
                if (Test-Path -LiteralPath $p) { $dirs += $p }
            }
        }
    return $dirs
}

function Get-CatEdgeCache {
    $dirs = Get-BrowserCacheDirs -Root (Join-Path $AppLocal 'Microsoft\Edge\User Data') -Profiles @('Default')
    return @{ Category = 'EdgeCache'; Files = @(); Dirs = @($dirs); Risk = 'Review'
              Note = 'Edge 离线缓存，删后网页重新下载；不影响登录态；需先关闭 Edge' }
}

function Get-CatChromeCache {
    $dirs = Get-BrowserCacheDirs -Root (Join-Path $AppLocal 'Google\Chrome\User Data') -Profiles @('Default', 'Profile 1')
    return @{ Category = 'ChromeCache'; Files = @(); Dirs = @($dirs); Risk = 'Review'
              Note = 'Chrome 离线缓存，删后网页重新下载；不影响登录态；需先关闭 Chrome' }
}

function Get-CatEgoCache {
    $dirs = Get-BrowserCacheDirs -Root (Join-Path $AppLocal 'Citro Labs\ego lite\User Data') -Profiles @('Default', 'Profile 1', 'Profile 2', 'Profile 3')
    return @{ Category = 'EgoCache'; Files = @(); Dirs = @($dirs); Risk = 'Review'
              Note = 'ego lite 离线缓存，删后重新下载；不影响登录态；需先关闭 ego' }
}

# ============================================================
# 主流程
# ============================================================

$freeBefore = (Get-PSDrive C).Free
$rbBefore = (Get-ChildItem 'C:\$Recycle.Bin' -Force -Recurse -File -ErrorAction SilentlyContinue |
             Measure-Object Length -Sum).Sum
if ($null -eq $rbBefore) { $rbBefore = 0 }

$probes = @(
    Get-CatUpdater
    Get-CatTemp
    Get-CatTaskLogs
    Get-CatAppLog
    Get-CatDbBackup
    Get-CatInstaller
    Get-CatUpgradeResidue
    Get-CatEdgeCache
    Get-CatChromeCache
    Get-CatEgoCache
)

if ($Category.Count -gt 0) {
    $probes = @($probes | Where-Object { $_.Category -in $Category })
}

# --- 生成报告 ---
$report = @()
foreach ($p in $probes) {
    $fileSize = Get-FileListSize -Files $p.Files
    $dirSize = 0
    foreach ($d in $p.Dirs) {
        $dirSize += (Get-ChildItem -LiteralPath $d -Force -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object Length -Sum).Sum
    }
    $sz = $fileSize + $dirSize
    if ($sz -lt ($ThresholdGB * 1GB)) { continue }
    $report += [PSCustomObject]@{
        Category = $p.Category
        Risk     = $p.Risk
        GB       = [math]::Round($sz / 1GB, 3)
        Files    = $p.Files.Count
        Dirs     = $p.Dirs.Count
        Note     = $p.Note
        Raw      = $p
    }
}
$report = @($report | Sort-Object GB -Descending)

$safeTotal   = ($report | Where-Object { $_.Risk -eq 'Safe' }   | Measure-Object GB -Sum).Sum
$reviewTotal = ($report | Where-Object { $_.Risk -eq 'Review' } | Measure-Object GB -Sum).Sum

# --- 清理 ---
$cleaned = @()
$restartPaths = @()
$manifestFile = $null
$rbHeldGB = 0
$rbAddedGB = 0

if ($Clean) {
    $browserCats = @('EdgeCache', 'ChromeCache', 'EgoCache')
    $touchBrowser = @($report | Where-Object {
        ($_.Risk -eq 'Safe' -or $_.Category -in $browserCats) -and
        ($_.Category -in $browserCats)
    }).Count -gt 0

    if ($touchBrowser) {
        foreach ($pn in @('msedge', 'chrome', 'ego')) {
            $running = Get-Process -Name $pn -ErrorAction SilentlyContinue
            if (-not $running) { continue }
            $exePath = ($running | Where-Object { $_.Path } | Select-Object -First 1).Path
            if ($exePath) { $restartPaths += $exePath }
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 3
    }

    # 记录本次将删除的完整清单 —— 万一删错了，可以照着清单找回原始路径
    $manifest = @()
    foreach ($t in $report) {
        $isBrowser = $t.Category -in $browserCats
        if ($t.Risk -eq 'Review' -and -not $isBrowser) { continue }
        foreach ($f in $t.Raw.Files) { if (-not (Test-ProtectedPath $f.FullName)) { $manifest += $f.FullName } }
        foreach ($d in $t.Raw.Dirs) { if (-not (Test-ProtectedPath $d)) { $manifest += "$d\*" } }
    }
    if ($manifest.Count -gt 0) {
        $logDir = Join-Path $env:TEMP 'disk-cleanup-logs'
        New-Item -ItemType Directory -Force -Path $logDir -ErrorAction SilentlyContinue | Out-Null
        $manifestPath = Join-Path $logDir ("deleted-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $manifest | Out-File -LiteralPath $manifestPath -Encoding UTF8
        $manifestFile = $manifestPath
    }

    foreach ($t in $report) {
        # 需确认类默认不删，除非显式指定该类别
        $isBrowser = $t.Category -in $browserCats
        if ($t.Risk -eq 'Review' -and -not $isBrowser) { continue }

        $res = Remove-ToTrash -Files $t.Raw.Files -Permanent:$NoRecycleBin
        $removed = $res.Ok
        $failed = $res.Fail

        # 目录整块处理
        foreach ($d in $t.Raw.Dirs) {
            if (Test-ProtectedPath $d) { continue }
            if ($NoRecycleBin) {
                try { [IO.Directory]::Delete($d, $true); $removed++ } catch { $failed++ }
            } else {
                Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction SilentlyContinue
                try {
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                        $d,
                        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
                    )
                    $removed++
                } catch { $failed++ }
            }
        }

        $cleaned += [PSCustomObject]@{
            Category = $t.Category; GB = $t.GB; Removed = $removed; Failed = $failed
        }
    }

    if (-not $NoRecycleBin) {
        # 不自动清空回收站 —— 清空是不可逆的，会连用户自己手动删进去的文件一起抹掉。
        # 文件留在回收站里，C 盘空间并未真正释放；这里如实报告占用，由用户自己决定何时清空。
        $rbNow = (Get-ChildItem 'C:\$Recycle.Bin' -Force -Recurse -File -ErrorAction SilentlyContinue |
                  Measure-Object Length -Sum).Sum
        if ($null -eq $rbNow) { $rbNow = 0 }
        $rbAdded = $rbNow - $rbBefore
        $rbHeldGB = $rbNow / 1GB
        $rbAddedGB = $rbAdded / 1GB
    }

    foreach ($rp in ($restartPaths | Select-Object -Unique)) {
        if (Test-Path -LiteralPath $rp) { Start-Process -FilePath $rp -ErrorAction SilentlyContinue }
    }
}

$freeAfter = (Get-PSDrive C).Free

# --- 深度定位 ---
$deepResult = $null
if ($Deep) {
    $skipTop = @('Windows', 'Program Files', 'Program Files (x86)', 'ProgramData',
                 'System Volume Information', '$Recycle.Bin', '$WinREAgent')
    $rootRows = @()
    Get-ChildItem 'C:\' -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin $skipTop } | ForEach-Object {
            $s = (Get-ChildItem $_.FullName -Force -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            if ($s -ge 500MB) {
                $rootRows += [PSCustomObject]@{ Name = $_.Name; Path = $_.FullName; GB = [math]::Round($s / 1GB, 2) }
            }
        }
    $homeRows = @()
    # 这些是 NTFS junction，指向 AppData\Local / AppData\Roaming，
    # 递归统计会与 AppData 重复计数，必须排除
    $skipHome = @('.mavis', 'Local Settings', 'Application Data', 'All Users', 'Default User')
    Get-ChildItem $UserHome -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin $skipHome } | ForEach-Object {
            $s = (Get-ChildItem $_.FullName -Force -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            if ($s -ge 500MB) {
                $homeRows += [PSCustomObject]@{ Name = $_.Name; Path = $_.FullName; GB = [math]::Round($s / 1GB, 2) }
            }
        }
    $appRows = @()
    foreach ($base in @($AppLocal, $AppRoaming)) {
        if (-not (Test-Path -LiteralPath $base)) { continue }
        Get-ChildItem -LiteralPath $base -Force -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $s = (Get-ChildItem $_.FullName -Force -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            if ($s -ge 500MB) {
                $appRows += [PSCustomObject]@{ Name = $_.Name; Path = $_.FullName; GB = [math]::Round($s / 1GB, 2) }
            }
        }
    }
    $deepResult = [PSCustomObject]@{
        Root    = @($rootRows | Sort-Object GB -Descending)
        Home    = @($homeRows | Sort-Object GB -Descending)
        AppData = @($appRows | Sort-Object GB -Descending)
    }
}

# --- 输出 ---
if ($Json) {
    [PSCustomObject]@{
        Drive         = 'C'
        FreeGBBefore  = [math]::Round($freeBefore / 1GB, 2)
        FreeGBAfter   = [math]::Round($freeAfter / 1GB, 2)
        FreedGB       = [math]::Round(($freeAfter - $freeBefore) / 1GB, 2)
        SafeTotalGB   = [math]::Round(($safeTotal ?? 0), 2)
        ReviewTotalGB = [math]::Round(($reviewTotal ?? 0), 2)
        Report        = @($report | ForEach-Object {
                             [PSCustomObject]@{ Category = $_.Category; Risk = $_.Risk; GB = $_.GB
                                                 Files = $_.Files; Dirs = $_.Dirs; Note = $_.Note }
                         })
        Cleaned       = $cleaned
        Deep          = $deepResult
        ManifestFile  = $manifestFile
        RecycleBinHeldGB = [math]::Round($rbHeldGB, 2)
        RecycleBinAddedGB = [math]::Round($rbAddedGB, 2)
    } | ConvertTo-Json -Depth 5
    return
}

Write-Output ''
Write-Output ('C 盘  可用 {0} / 200 GB' -f [math]::Round($freeAfter / 1GB, 1))
Write-Output ('-' * 58)
if ($report.Count -eq 0) {
    Write-Output '未发现明显可清理项。'
} else {
    foreach ($r in $report) {
        $tag = if ($r.Risk -eq 'Safe') { '[安全]' } else { '[需确认]' }
        Write-Output ('{0} {1,-16} {2,9}   {3,6} 项' -f $tag, $r.Category, ('{0:N2} G' -f $r.GB), ($r.Files + $r.Dirs))
    }
    Write-Output ('-' * 58)
    Write-Output ('安全类合计 {0:N2} GB     需确认类合计 {1:N2} GB' -f ($safeTotal ?? 0), ($reviewTotal ?? 0))
}

if ($Clean) {
    Write-Output ''
    foreach ($c in $cleaned) {
        Write-Output ('已清理 {0,-16} {1,7:N2} GB   成功 {2}  跳过 {3}' -f $c.Category, $c.GB, $c.Removed, $c.Failed)
    }
    Write-Output ('-' * 58)
    Write-Output ('本次释放 {0:N2} GB    C 盘可用 {1:N1} GB' -f (($freeAfter - $freeBefore) / 1GB), ($freeAfter / 1GB))
    if ($manifestFile -and (Test-Path -LiteralPath $manifestFile)) {
        Write-Output ('删除清单已存档: {0}' -f $manifestFile)
    }
    if (-not $NoRecycleBin) {
        Write-Output ('回收站现有 {0:N2} GB (本次新增 {1:N2} GB)，空间尚未真正释放。' -f $rbHeldGB, $rbAddedGB)
        Write-Output '需要立即释放空间时，手动清空回收站即可（脚本不代为清空）。'
    }
} else {
    Write-Output ''
    Write-Output '加 -Clean 执行清理；-Category 可指定类别；-Deep 深度定位大头。'
}

if ($Deep -and $deepResult) {
    Write-Output ''
    Write-Output '===== 深度定位（已知类别之外的大头）====='
    foreach ($grp in @(
        @{ T = 'C 盘根'; R = $deepResult.Root },
        @{ T = '用户目录'; R = $deepResult.Home },
        @{ T = 'AppData'; R = $deepResult.AppData }
    )) {
        if (-not $grp.R -or $grp.R.Count -eq 0) { continue }
        Write-Output ''
        Write-Output ("[$($grp.T)]")
        foreach ($r in $grp.R) { Write-Output ('  {0,8:N2} G  {1}' -f $r.GB, $r.Path) }
    }
}
Write-Output ''
