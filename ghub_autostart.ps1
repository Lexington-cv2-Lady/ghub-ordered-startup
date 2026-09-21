<#
    G HUB 开机自启设置（独立脚本）
    ------------------------------------------------------------------
    功能：开启 / 关闭「登录时自动按正确顺序启动 G HUB」。
          不启用也不影响手动启动。

    用法：
      双击 Autostart-Settings.cmd（开机自启设置.cmd） → 出现菜单，按提示选择。
      或在 PowerShell 中：
          .\ghub_autostart.ps1 -On      开启自启（静默，不弹菜单）
          .\ghub_autostart.ps1 -Off     关闭自启
          .\ghub_autostart.ps1          打开交互菜单

    权限说明：注册计划任务需要管理员权限，脚本会自动请求提权。

    原理：创建一个名为 “LGHUB Order Startup” 的计划任务，
          触发条件＝用户登录后延迟 30 秒，运行级别＝最高（静默提权，不弹 UAC），
          动作 ＝ 隐藏窗口运行 start_lghub_universal.ps1。

    注意：本文件必须保存为「UTF-8 带 BOM」，否则 PowerShell 5.1 会按 GBK 解码导致乱码。
#>
[CmdletBinding()]
param(
    [switch]$On,
    [switch]$Off,
    [switch]$Silent,     # 供主脚本调用：不显示菜单、不等待按键
    [string]$UserDesktop # 透传，保持与主脚本一致的桌面路径解析
)

$ErrorActionPreference = 'Continue'
$TaskName = 'LGHUB Order Startup'
$AppTitle = 'G HUB 开机自启设置'
$MainScriptName = 'start_lghub_universal.ps1'

function Set-Title([string]$t) { try { $Host.UI.RawUI.WindowTitle = $t } catch { } }

function Get-SelfPath {
    if ($PSCommandPath) { return $PSCommandPath }
    if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) { return $MyInvocation.MyCommand.Path }
    return $null
}

# ============================================================
# 自提权
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

    # 路径运行时取得，Start-Process 传递 Unicode 路径安全，无需临时 cmd 中转
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $self + '"'))
    if ($On)     { $argList += '-On' }
    if ($Off)    { $argList += '-Off' }
    if ($Silent) { $argList += '-Silent' }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    } catch {
        Write-Host "[失败] 提权被拒绝，请右键以管理员身份运行。" -ForegroundColor Red
        Read-Host "按回车键退出"
    }
    exit 0
}

Set-Title $AppTitle

# ============================================================
# 状态查询
# ============================================================
function Get-AutostartState {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) { return 'NotInstalled' }
    return [string]$t.State     # Ready / Disabled / Running
}

function Show-Status {
    $state = Get-AutostartState
    switch ($state) {
        'NotInstalled' {
            Write-Host "  当前状态：" -NoNewline; Write-Host "未启用" -ForegroundColor DarkGray
            Write-Host "  （尚未创建计划任务）" -ForegroundColor DarkGray
        }
        'Disabled' {
            Write-Host "  当前状态：" -NoNewline; Write-Host "已关闭" -ForegroundColor Yellow
            Write-Host "  （计划任务存在但已禁用）" -ForegroundColor DarkGray
        }
        default {
            Write-Host "  当前状态：" -NoNewline; Write-Host "已开启" -ForegroundColor Green
            $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            if ($t) {
                $d = $t.Triggers[0].Delay
                if (-not $d) { $d = 'PT30S' }
                Write-Host "  触发方式：登录后 $([int]($d -replace 'PT|S','')) 秒自动启动" -ForegroundColor DarkGray
                $act = $t.Actions[0].Arguments
                if ($act -match '"?([^"\\]+\.ps1)"?') {
                    Write-Host "  执行脚本：$($Matches[1])" -ForegroundColor DarkGray
                }
            }
        }
    }
}

# ============================================================
# 开启 / 关闭
# ============================================================
function Enable-Autostart {
    $selfPath  = Get-SelfPath
    $scriptDir = if ($selfPath) { Split-Path $selfPath -Parent } else { $PWD.Path }
    $mainScript = Join-Path $scriptDir $MainScriptName

    if (-not (Test-Path $mainScript)) {
        Write-Host "  [失败] 未找到主脚本：$mainScript" -ForegroundColor Red
        return $false
    }

    $act = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Silent' -f $mainScript)
    $trg = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $trg.Delay = 'PT30S'
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
             -StartWhenAvailable -MultipleInstances IgnoreNew `
             -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    $prn = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
             -LogonType Interactive -RunLevel Highest

    try {
        Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg `
          -Settings $set -Principal $prn -Force -ErrorAction Stop | Out-Null
        Write-Host "  [完成] 已开启开机自启" -ForegroundColor Green
        Write-Host "         登录后 30 秒自动按正确顺序启动 G HUB" -ForegroundColor DarkGray
        return $true
    } catch {
        Write-Host "  [失败] $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Disable-Autostart {
    $state = Get-AutostartState
    if ($state -eq 'NotInstalled') {
        Write-Host "  当前未启用，无需关闭。" -ForegroundColor DarkGray
        return $true
    }
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host "  [完成] 已关闭开机自启" -ForegroundColor Green
        return $true
    } catch {
        # 退而求其次：只禁用任务
        try {
            Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
            Write-Host "  [完成] 已关闭开机自启（任务保留但已禁用）" -ForegroundColor Green
            return $true
        } catch {
            Write-Host "  [失败] $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
}

# ============================================================
# 主流程
# ============================================================
if ($On) {
    Set-Title "$AppTitle - 正在开启"
    Write-Host "===== $AppTitle =====" -ForegroundColor White
    $ok = Enable-Autostart
    if (-not $Silent) { Start-Sleep -Seconds 3; Read-Host "按回车键关闭窗口" }
    exit ([int](-not $ok))
}

if ($Off) {
    Set-Title "$AppTitle - 正在关闭"
    Write-Host "===== $AppTitle =====" -ForegroundColor White
    $ok = Disable-Autostart
    if (-not $Silent) { Start-Sleep -Seconds 3; Read-Host "按回车键关闭窗口" }
    exit ([int](-not $ok))
}

# 交互菜单
while ($true) {
    Clear-Host
    Set-Title $AppTitle
    Write-Host "========================================" -ForegroundColor White
    Write-Host "   $AppTitle" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor White
    Write-Host ""
    Show-Status
    Write-Host ""
    Write-Host "  1. 开启开机自启"
    Write-Host "  2. 关闭开机自启"
    Write-Host "  0. 退出"
    Write-Host ""
    $c = Read-Host "请选择"

    Write-Host ""
    switch ($c) {
        '1' {
            Set-Title "$AppTitle - 正在开启"
            Enable-Autostart | Out-Null
        }
        '2' {
            Set-Title "$AppTitle - 正在关闭"
            Disable-Autostart | Out-Null
        }
        '0' { exit 0 }
        default { Write-Host "  无效选择。" -ForegroundColor Yellow }
    }
    Write-Host ""
    Read-Host "按回车键返回菜单"
}
