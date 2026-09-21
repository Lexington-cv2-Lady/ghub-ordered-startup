<#
    G HUB 有序启动工具
    ------------------------------------------------------------------
    解决的问题：Logitech G HUB 存在一个长期未修复的启动顺序 bug ——
      若 lghub_updater 比 lghub_agent 先启动，G HUB 会卡死无法正常使用。
      本脚本先停掉 Updater 服务、杀光残留进程，再严格按
      Agent -> Updater -> G HUB 的顺序重新拉起，最后校验实际启动顺序。

    用法：
      双击随附的启动器 Start-GHUB.cmd（启动 G HUB.cmd） 即可。
      或在 PowerShell 中：  .\start_lghub_universal.ps1

    权限说明：
      脚本需要管理员权限，会自动请求提权（会弹一次 UAC，请点「是」）。
      必须提权的原因：
        1. 停止 LGHUBUpdaterService（以 LocalSystem 身份运行的服务）
        2. lghub_agent / lghub_updater 以提权身份运行，普通权限杀不掉
      不提权时这两步会被系统拒绝、且被静默吞掉，顺序 bug 会复现。

    注意：
      本文件必须保存为「UTF-8 带 BOM」。若存成无 BOM，PowerShell 5.1 会按
      GBK 解码，中文提示将变成乱码甚至导致脚本无法解析。
#>
[CmdletBinding()]
param(
    # 由非提权实例回传，确保「创建桌面快捷方式」建在真正使用者的桌面上
    [string]$UserDesktop,

    # 跳过所有交互提示（供计划任务等无人值守场景使用）
    [switch]$Silent
)

$ErrorActionPreference = 'Continue'
$ProductGuid  = '{521c89be-637f-4274-a840-baaf7460c2b2}'
$AppTitle     = 'G HUB 有序启动'

function Set-Title([string]$text) {
    try { $Host.UI.RawUI.WindowTitle = $text } catch { }
}

function Write-Step([string]$text) {
    Write-Host $text -ForegroundColor Cyan
    Set-Title "$AppTitle - $text"
    Write-Log $text
}

function Write-Log([string]$text) {
    # 诊断日志固定写到脚本目录下的 lghub_run.log（不通过参数传递，
    # 避免 cmd 解析含冒号的路径时出错）。每次运行覆盖上一次。
    if (-not $script:LogPath) {
        try {
            $sd = if (Get-SelfPath) { Split-Path (Get-SelfPath) -Parent } else { $null }
            if ($sd -and (Test-Path $sd)) { $script:LogPath = Join-Path $sd 'lghub_run.log' }
            else { $script:LogPath = Join-Path $env:TEMP 'lghub_run.log' }
        } catch { $script:LogPath = $null }
    }
    if (-not $script:LogPath) { return }
    try {
        $plain = $text -replace '\x1b\[[0-9;]*m', ''
        $line  = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $plain)
        if (-not $script:LogInit) {
            Set-Content -Path $script:LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
            $script:LogInit = $true
        } else {
            Add-Content -Path $script:LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    } catch { }
}

# ============================================================
# 1) 自身路径 / 桌面路径
# ============================================================
function Get-SelfPath {
    if ($PSCommandPath) { return $PSCommandPath }
    if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
        return $MyInvocation.MyCommand.Path
    }
    return $null
}

function Get-DesktopPath {
    # 优先用调用方回传的路径（提权前后可能不是同一个用户配置）
    if ($UserDesktop -and (Test-Path $UserDesktop)) { return $UserDesktop }
    try {
        $d = [Environment]::GetFolderPath('Desktop')
        if ($d -and (Test-Path $d)) { return $d }
    } catch { }
    return (Join-Path $env:USERPROFILE 'Desktop')
}

# ============================================================
# 2) 自提权
# ============================================================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $self = Get-SelfPath
    if (-not $self) {
        Write-Host "[错误] 无法定位脚本自身路径，请右键选择「使用 PowerShell 运行」。" -ForegroundColor Red
        Read-Host "按回车键退出"
        exit 1
    }
    Write-Host "[提权] 正在以管理员身份重新启动（如弹出 UAC 请点「是」）..." -ForegroundColor Yellow

    # 说明：路径在运行时用 $PSCommandPath 取得，是 Unicode 字符串，
    # 经 Start-Process 传给提权进程不会丢失中文。
    # （曾用「临时 cmd 中转」方案，但那会因为 cmd 无法可靠执行含中文的
    #   UTF-8 批处理而报 "The batch file cannot be found."，故弃用。）
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $self + '"'))
    $argList += @('-UserDesktop', ('"' + (Get-DesktopPath) + '"'))
    if ($Silent) { $argList += '-Silent' }

    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    } catch {
        Write-Host "[失败] 提权被拒绝，请右键以管理员身份运行。" -ForegroundColor Red
        Read-Host "按回车键退出"
    }
    exit 0
}

Set-Title "$AppTitle - 初始化"

# ============================================================
# 3) 定位 G HUB 安装目录
# ============================================================
function Resolve-GHubRoot {
    # 1) 默认安装位置
    $candidates = @()
    if ($env:ProgramFiles)        { $candidates += (Join-Path $env:ProgramFiles 'LGHUB') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'LGHUB') }
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'lghub.exe')) { return $c }
    }

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    # 2) 按产品 GUID 查卸载项
    foreach ($r in $roots) {
        $k = Join-Path $r $ProductGuid
        if (Test-Path $k) {
            $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
            foreach ($v in @($p.DisplayIcon, $p.UninstallString, $p.InstallLocation)) {
                if (-not $v) { continue }
                $s   = ($v -replace '"','').Trim()
                $dir = if ($s -like '*.exe') { Split-Path $s -Parent } else { $s }
                if ($dir -and (Test-Path (Join-Path $dir 'lghub.exe'))) { return $dir }
            }
        }
    }

    # 3) 兜底：按显示名模糊匹配
    foreach ($r in $roots) {
        foreach ($item in (Get-ChildItem $r -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty $item.PSPath -ErrorAction SilentlyContinue
            if (-not $p.DisplayName -or $p.DisplayName -notmatch 'G\s*HUB') { continue }
            foreach ($v in @($p.DisplayIcon, $p.UninstallString)) {
                if (-not $v) { continue }
                $s   = ($v -replace '"','').Trim()
                $dir = if ($s -like '*.exe') { Split-Path $s -Parent } else { $s }
                if ($dir -and (Test-Path (Join-Path $dir 'lghub.exe'))) { return $dir }
            }
        }
    }
    return $null
}

$root = Resolve-GHubRoot
if (-not $root) {
    Write-Host "[失败] 未找到 G HUB 安装目录。" -ForegroundColor Red
    Write-Host "       请确认已安装 G HUB。"
    Write-Log "[失败] 未找到 G HUB 安装目录"
    if (-not $Silent) { Read-Host "按回车键退出" }
    exit 1
}

$agentExe   = Join-Path $root 'lghub_agent.exe'
$updaterExe = Join-Path $root 'lghub_updater.exe'
$mainExe    = Join-Path $root 'lghub.exe'

Write-Host "===== $AppTitle =====" -ForegroundColor White
Write-Host "[路径] $root"
Write-Log "===== 开始 ====="
Write-Log "[路径] $root"

# ============================================================
# 4) 自适应模式：有 agent+updater 才需要排序
# ============================================================
$hasAgent   = Test-Path $agentExe
$hasUpdater = Test-Path $updaterExe

if ($hasAgent -and $hasUpdater) {
    $steps = @(
        [PSCustomObject]@{ Name='LGHUB Agent';   Exe=$agentExe;   Proc='lghub_agent';   WaitSec=12 },
        [PSCustomObject]@{ Name='LGHUB Updater'; Exe=$updaterExe; Proc='lghub_updater'; WaitSec=10 },
        [PSCustomObject]@{ Name='LGHUB';         Exe=$mainExe;    Proc='lghub';         WaitSec=25 }
    )
    $orderedMode = $true
    Write-Host "[模式] 按序启动（检测到 Agent + Updater）" -ForegroundColor Cyan
} else {
    $steps = @(
        [PSCustomObject]@{ Name='LGHUB'; Exe=$mainExe; Proc='lghub'; WaitSec=30 }
    )
    $orderedMode = $false
    Write-Host "[模式] 普通启动（未检测到 lghub_agent.exe，无需排序）" -ForegroundColor Cyan
}

$killList = @(
    'lghub_system_tray','lghub_updater','lghub_agent','lghub',
    'lghub_gl','lghub_software_manager','lghub_sso_handler',
    'lghub_gl_crashpad_handler','logi_crashpad_handler'
)

function Test-AnyProc {
    param([string[]]$names)
    foreach ($n in $names) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Start-GHubProcess {
    param([string]$Exe)
    # 必须让 G HUB 脱离本脚本的控制台。
    # 若共享控制台，脚本结束时控制台被销毁，G HUB 会收到 CTRL_CLOSE_EVENT
    # 而可能被一并结束（其 CEF 内核的日志串进本控制台，正是句柄被继承的证据）。
    # WMI 创建进程不会继承父进程的控制台句柄，因此用它启动。
    try {
        $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create `
                -Arguments @{ CommandLine = ('"' + $Exe + '"') } -ErrorAction Stop
        if ($r.ReturnValue -eq 0) { return $true }
    } catch { }
    # 兜底：普通方式启动
    try {
        $wshell = New-Object -ComObject WScript.Shell
        $wshell.Run('"' + $Exe + '"', 1, $false) | Out-Null
        return $true
    } catch { return $false }
}

# ============================================================
# 5) 清理：先停服务，再杀进程
# ============================================================
Write-Step "[1/3] 清理 G HUB 后台进程..."

if ($orderedMode) {
    # 关键：lghub_updater.exe 是 LGHUBUpdaterService 的进程。仅用 taskkill 杀它，
    # 服务管理器会在恢复策略的 5 秒后自动拉起它，导致 Updater 早于 Agent 出现、
    # 顺序验证失败（这正是「启动顺序 bug」的竞态来源）。
    # 先 Stop-Service 标记为「主动停止」，就不会触发失败重启。
    Stop-Service -Name 'LGHUBUpdaterService' -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
}

for ($round = 1; $round -le 3; $round++) {
    $killed = 0
    foreach ($n in $killList) {
        & taskkill /F /IM ($n + '.exe') 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $killed++ }
    }
    Write-Host "  第 $round 轮清理：终止 $killed 个进程"
    Write-Log "  第 $round 轮清理：终止 $killed 个进程"
    Start-Sleep -Seconds 2
    if (-not (Test-AnyProc $killList)) { break }
}

$allGone = $false
for ($i = 1; $i -le 10; $i++) {
    Start-Sleep -Seconds 1
    if (-not (Test-AnyProc $killList)) { $allGone = $true; break }
}
if ($allGone) { Write-Host "  后台已全部清理" -ForegroundColor Green; Write-Log "  后台已全部清理" }
else          { Write-Host "  [警告] 仍有进程未退出，继续启动..." -ForegroundColor Yellow; Write-Log "  [警告] 仍有进程未退出" }
Start-Sleep -Seconds 1

# ============================================================
# 6) 按序启动
# ============================================================
Write-Step "[2/3] 按顺序启动..."
$report  = @()
$hasFail = $false

$stepIdx = 0
foreach ($s in $steps) {
    $stepIdx++
    Set-Title "$AppTitle - [2/3] 启动 $($s.Name) ($stepIdx/$($steps.Count))"

    if (-not (Test-Path $s.Exe)) {
        Write-Host "  [失败] 找不到 $($s.Exe)" -ForegroundColor Red
        $report += [PSCustomObject]@{ Step=$s.Name; Action='缺失文件'; Result='FAIL' }
        $hasFail = $true
        continue
    }
    Write-Host "  [启动] $($s.Name) ..."
    if (-not (Start-GHubProcess -Exe $s.Exe)) {
        Write-Host "  [失败] $($s.Name) 启动异常" -ForegroundColor Red
        Write-Log "  [失败] $($s.Name) 启动异常"
        $report += [PSCustomObject]@{ Step=$s.Name; Action='启动异常'; Result='FAIL' }
        $hasFail = $true
        continue
    }
    $ok = $false
    for ($i = 1; $i -le $s.WaitSec; $i++) {
        Start-Sleep -Seconds 1
        if (Get-Process -Name $s.Proc -ErrorAction SilentlyContinue) { $ok = $true; break }
    }
    if ($ok) {
        Write-Host "  [确认] $($s.Name) 已运行（等待 ${i} 秒）" -ForegroundColor Green
        Write-Log "  [确认] $($s.Name) 已运行（等待 ${i} 秒）"
        $report += [PSCustomObject]@{ Step=$s.Name; Action='已启动'; Result='OK' }
    } else {
        Write-Host "  [超时] $($s.Name) $($s.WaitSec) 秒内未检测到进程" -ForegroundColor Red
        Write-Log "  [超时] $($s.Name) 未在 $($s.WaitSec) 秒内启动"
        $report += [PSCustomObject]@{ Step=$s.Name; Action='启动超时'; Result='FAIL' }
        $hasFail = $true
    }
}

Write-Host ""
$report | Format-Table -AutoSize | Out-Host

# ============================================================
# 7) 顺序校验
# ============================================================
Write-Step "[3/3] 校验启动顺序..."

if ($orderedMode) {
    # 重要：lghub_agent.exe 启动后会自行重启一次，瞬间可能同时存在新旧两个实例。
    # 若此时立即取值，可能读到「正在退出的旧实例」或错过新实例，导致误判顺序。
    # 因此先等进程稳定，再对每个进程名取其「最早」的启动时间作为该组件的真实启动时刻。
    Start-Sleep -Seconds 6

    $procs = @()
    foreach ($s in $steps) {
        $cands = @(Get-Process -Name $s.Proc -ErrorAction SilentlyContinue |
                   Where-Object { try { $null -ne $_.StartTime } catch { $false } } |
                   Sort-Object StartTime)
        if ($cands.Count -gt 0) {
            $procs += [PSCustomObject]@{ Name=$s.Name; StartTime=$cands[0].StartTime; Count=$cands.Count }
        }
    }

    if (@($procs).Count -eq 3) {
        $sorted = $procs | Sort-Object StartTime
        $sorted | ForEach-Object {
            $extra = if ($_.Count -gt 1) { "（共 $($_.Count) 个实例，取最早）" } else { '' }
            Write-Host ("  {0:HH:mm:ss.fff}  {1}{2}" -f $_.StartTime, $_.Name, $extra)
            Write-Log ("  进程启动时间 {0:HH:mm:ss.fff}  {1}{2}" -f $_.StartTime, $_.Name, $extra)
        }
        $orderOk = ($sorted[0].Name -eq 'LGHUB Agent') -and ($sorted[1].Name -eq 'LGHUB Updater') -and ($sorted[2].Name -eq 'LGHUB')
        if ($orderOk) {
            Write-Host "  [顺序正确] Agent -> Updater -> G HUB" -ForegroundColor Green
            Write-Log "  [顺序正确] Agent -> Updater -> G HUB"
        } else {
            $actual = (($sorted | ForEach-Object { $_.Name }) -join ' -> ')
            Write-Host "  [顺序异常] 实际顺序: $actual" -ForegroundColor Yellow
            Write-Log "  [顺序异常] 实际顺序: $actual"
            Write-Host "             这不一定会影响使用，若 G HUB 打不开可重跑本脚本。" -ForegroundColor DarkGray
            $hasFail = $true
        }
    } else {
        Write-Host "  [警告] 只有 $(@($procs).Count)/3 个进程在运行，无法完整校验" -ForegroundColor Yellow
        Write-Log "  [警告] 只有 $(@($procs).Count)/3 个进程在运行"
    }
} else {
    $p = Get-Process -Name 'lghub' -ErrorAction SilentlyContinue
    if ($p) { Write-Host "  [正常] G HUB 主程序已运行" -ForegroundColor Green; Write-Log "  [正常] 主程序已运行" }
}

# ============================================================
# 8) 首次运行：快捷方式 / 自启引导
# ============================================================
$selfPath  = Get-SelfPath
$scriptDir = if ($selfPath) { Split-Path $selfPath -Parent } else { $PWD.Path }
$markerDir = Join-Path $env:LOCALAPPDATA 'LGHUBOrderStart'
$marker    = Join-Path $markerDir 'firstrun.done'
$asked     = $false
$hadPrompt = $false

function Test-FirstRun {
    if ($Silent) { return $false }
    try { if (Test-Path $marker) { return $false } } catch { return $false }
    return $true
}

if (Test-FirstRun) {
    Write-Host ""
    Write-Host "===== 首次运行设置 =====" -ForegroundColor White

    # --- 桌面快捷方式 ---
    $desktop = Get-DesktopPath
    $sh      = New-Object -ComObject WScript.Shell

    # 找出可能"代表 G HUB"的桌面快捷方式，以便替换前备份。
    # 现实中至少有三种形态：
    #   1. 直接指向 lghub.exe（官方安装器创建）
    #   2. 指向 powershell.exe 且参数里带 lghub（用户自己做的脚本启动器）
    #   3. 指向某个 .cmd/.bat 启动器
    $existing = @()
    try {
        Get-ChildItem $desktop -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
            $sc = $null
            try { $sc = $sh.CreateShortcut($_.FullName) } catch { }
            if (-not $sc) { return }
            $t = [string]$sc.TargetPath
            $a = [string]$sc.Arguments
            $hit = $false
            if ($t -and $t -ieq $mainExe)                      { $hit = $true }
            elseif ($a -and $a -match 'lghub')                 { $hit = $true }
            elseif ($t -and $t -match 'lghub')                 { $hit = $true }
            elseif ($_.Name -match 'Logitech\s*G\s*HUB')       { $hit = $true }
            if ($hit) { $existing += $_ }
        }
    } catch { }

    Write-Host "  可用本脚本替换桌面上的 G HUB 图标，替换后双击图标即按正确顺序启动。"
    if (@($existing).Count -gt 0) {
        Write-Host "  检测到 $((@($existing)).Count) 个相关快捷方式：" -ForegroundColor Yellow
        @($existing) | ForEach-Object { Write-Host "    · $($_.Name)" -ForegroundColor DarkGray }
    } else {
        Write-Host "  未检测到已有的 G HUB 快捷方式，将新建一个。" -ForegroundColor DarkGray
    }

    $ans = Read-Host "  是否创建/替换桌面快捷方式？(Y/N)"
    $hadPrompt = $true
    if ($ans -match '^[Yy]') {
        try {
            # 备份并移除所有旧的 G HUB 快捷方式，避免桌面上出现两个图标
            foreach ($old in @($existing)) {
                $bak = Join-Path $desktop ($old.BaseName + ' (原版).lnk')
                if (-not (Test-Path $bak)) {
                    Copy-Item $old.FullName $bak -Force -ErrorAction SilentlyContinue
                    Write-Host "  已备份原快捷方式为：$(Split-Path $bak -Leaf)" -ForegroundColor DarkGray
                }
                Remove-Item $old.FullName -Force -ErrorAction SilentlyContinue
            }

            # 定位随附的启动器 .cmd。不写死文件名，以便中英文命名都能识别
            # （分发时常用英文名，本地可能用中文名）。
            $launcher = $null
            $preferred = @('Start-GHUB.cmd', '启动 G HUB.cmd', 'start-ghub.cmd')
            foreach ($nm in $preferred) {
                $try = Join-Path $scriptDir $nm
                if (Test-Path $try) { $launcher = $try; break }
            }
            # 未命中则在本目录里找任何看起来像启动器的 .cmd
            if (-not $launcher) {
                $cand = Get-ChildItem $scriptDir -Filter '*.cmd' -ErrorAction SilentlyContinue |
                        Where-Object { $_.BaseName -notmatch 'Autostart|自启' } |
                        Select-Object -First 1
                if ($cand) { $launcher = $cand.FullName }
            }

            $lnkPath = Join-Path $desktop 'Logitech G HUB.lnk'
            # 注意：若目标 .lnk 已存在，CreateShortcut 会读取它的现有内容，
            # 未显式赋值的字段（如 Arguments）会保留旧值，因此必须逐项覆盖。
            $lnk = $sh.CreateShortcut($lnkPath)
            if ($launcher) {
                $lnk.TargetPath  = $launcher
                $lnk.Arguments   = ''          # 显式清空，否则会残留上一个快捷方式的参数
            } else {
                $lnk.TargetPath  = 'powershell.exe'
                $lnk.Arguments   = '-NoProfile -ExecutionPolicy Bypass -File "' + $selfPath + '"'
            }
            $lnk.WorkingDirectory = $scriptDir
            $lnk.IconLocation     = "$mainExe,0"
            $lnk.Description      = '按 Agent -> Updater -> G HUB 顺序启动，规避启动顺序 bug'
            $lnk.WindowStyle      = 1
            $lnk.Save()

            # 回读校验，确认参数确实被清空、目标正确
            $verify = $sh.CreateShortcut($lnkPath)
            if ([string]$verify.Arguments) {
                Write-Host "  [警告] 快捷方式仍带有参数：$($verify.Arguments)" -ForegroundColor Yellow
            } else {
                Write-Host "  [完成] 桌面快捷方式已就绪：$lnkPath" -ForegroundColor Green
            }
        } catch {
            Write-Host "  [失败] 创建快捷方式时出错：$_" -ForegroundColor Red
        }
    } else {
        Write-Host "  已跳过，桌面图标保持不变。"
    }

    # --- 开机自启引导 ---
    Write-Host ""
    $auto = Read-Host "  是否设置开机自动启动？（可用 Autostart-Settings.cmd（开机自启设置.cmd） 随时更改）(Y/N)"
    if ($auto -match '^[Yy]') {
        $autoScript = Join-Path $scriptDir 'ghub_autostart.ps1'
        if (Test-Path $autoScript) {
            try {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $autoScript -On -Silent
            } catch {
                Write-Host "  [失败] 调用自启脚本出错：$_" -ForegroundColor Red
            }
        } else {
            Write-Host "  未找到 ghub_autostart.ps1，请手动运行 Autostart-Settings.cmd（开机自启设置.cmd）。" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  已跳过。之后可运行 Autostart-Settings.cmd（开机自启设置.cmd） 开启。"
    }

    # 记录已询问（写不进去也不影响使用）
    try {
        New-Item -ItemType Directory -Path $markerDir -Force -ErrorAction SilentlyContinue | Out-Null
        Set-Content -Path $marker -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') -Encoding ASCII -ErrorAction SilentlyContinue
    } catch { }
}

# ============================================================
# 9) 收尾
# ============================================================
# 失败时的处理：顺序校验不通过并不等于 G HUB 一定不能用——
# 该 bug 是概率性的，有时顺序反了也能凑合跑起来。
# 因此这里把判断权交给用户：能用就直接关，不能用就按 1 重跑。
$retryRequested = $false

if ($hasFail) {
    Set-Title "$AppTitle - 需要确认"
    Write-Host ""
    Write-Host "————————————————————————————" -ForegroundColor DarkGray
    Write-Host " 有步骤未按预期完成。" -ForegroundColor Yellow
    Write-Host ""
    Write-Host " 这种情况不一定会影响使用。请先打开 G HUB 试一下：" -ForegroundColor Gray
    Write-Host "   · 能正常打开、鼠标设置正常  →  直接按回车关闭即可" -ForegroundColor Gray
    Write-Host "   · 打不开 / 卡在启动界面     →  按 1 重新执行一次" -ForegroundColor Gray
    Write-Host "————————————————————————————" -ForegroundColor DarkGray
    Write-Host ""

    if (-not $Silent) {
        $c = Read-Host " 按回车键关闭，或按 1 重新执行"
        if ($c -match '1') { $retryRequested = $true }
    }
} elseif ($hadPrompt) {
    Set-Title "$AppTitle - 完成"
    Write-Host ""
    Write-Host "全部完成。" -ForegroundColor Green
    if (-not $Silent) { Read-Host "按回车键关闭窗口" }
} else {
    Set-Title "$AppTitle - 完成"
    Write-Host ""
    Write-Host "全部完成，窗口将在 5 秒后自动关闭。" -ForegroundColor Green
    if (-not $Silent) {
        for ($i = 5; $i -gt 0; $i--) {
            Set-Title "$AppTitle - 完成（$i 秒后关闭）"
            Start-Sleep -Seconds 1
        }
    }
}

# ============================================================
# 10) 用户要求重试：以管理员身份重新启动本脚本，然后退出当前实例
# ============================================================
if ($retryRequested) {
    Write-Host ""
    Write-Host " 正在重新执行..." -ForegroundColor Cyan
    $self = Get-SelfPath
    if ($self) {
        $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $self + '"'))
        $argList += @('-UserDesktop', ('"' + (Get-DesktopPath) + '"'))
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
        } catch {
            Write-Host " [失败] 无法重新执行：$_" -ForegroundColor Red
            Write-Host "        请手动再运行一次本脚本。" -ForegroundColor Yellow
            Read-Host "按回车键退出"
        }
    } else {
        Write-Host " [失败] 无法定位脚本路径，请手动再运行一次。" -ForegroundColor Yellow
        Read-Host "按回车键退出"
    }
    # 当前实例直接结束，不进入下面的关窗逻辑
    exit 0
}

# ============================================================
# 11) 收尾说明
# ============================================================
# 不主动杀 conhost：本脚本退出后窗口会自然关闭——
#   · 双击启动器 .cmd 时，控制台是为该 cmd 创建的，cmd 结束即关闭
#   · 右键「使用 PowerShell 运行」时，控制台是为本进程创建的，进程退出即关闭
#   · 在已有终端里运行时，窗口属于用户自己的终端，本就不应关闭
# 之前用 GetConsoleProcessList 判断"是否共享控制台"再决定杀不杀，
# 反而因为启动器会额外引入一个 cmd 进程而误判，故弃用。
