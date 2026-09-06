<#
  reset-install.ps1 — 一键“干净重演安装”：清空 Quicklisp + ASDF 编译缓存 +
  ~/.sbclrc 引导行，然后立即调用 install.ps1 重新安装。

  用法：
    .\scripts\reset-install.ps1                 # 先列出将删项并确认
    .\scripts\reset-install.ps1 -Force          # 跳过确认（自动化）
    .\scripts\reset-install.ps1 -WithDexador    # 重装后连带 dexador/cl+ssl
    .\scripts\reset-install.ps1 -RemoveSbcl     # 可选：连系统 SBCL 也卸载重装（需管理员/UAC）

  安全：
    - 只删三样：%USERPROFILE%\quicklisp、仓库 .tools\cache\common-lisp、
      以及 .sbclrc 中含 quicklisp/setup.lisp 的那一行（其它配置不动，并先备份 .sbclrc）。
    - 系统 SBCL 默认保留；-RemoveSbcl 才会动它。
#>
param(
    [switch]$Force,
    [switch]$WithDexador,
    [switch]$RemoveSbcl
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$qlHome = Join-Path $env:USERPROFILE 'quicklisp'
$rcFile = Join-Path $env:USERPROFILE '.sbclrc'
$cacheDir = Join-Path $repo '.tools\cache\common-lisp'
$gitBin = 'C:\Program Files\Git\mingw64\bin'
if ((Test-Path $gitBin) -and ($env:PATH -notlike "*$gitBin*")) {
    $env:PATH = "$gitBin;$env:PATH"
}

function Info { Write-Host "==> $args" -ForegroundColor Cyan }
function Ok   { Write-Host "[OK] $args" -ForegroundColor Green }
function Skip { Write-Host "[SKIP] $args" -ForegroundColor DarkGray }
function Warn { Write-Host "[WARN] $args" -ForegroundColor DarkYellow }
function Fail { Write-Host "[FAIL] $args" -ForegroundColor Red }
function Confirm-Question {
    param([string]$Question)
    try { (Read-Host $Question) -match '^y' }
    catch {
        # 非交互/无控制台：fail-safe，视为取消
        Write-Host '（无法读取输入，视为取消）' -ForegroundColor DarkYellow
        return $false
    }
}

# ---------- 1. 盘点将删项 ----------
$toDelete = @()
if (Test-Path $qlHome)   { $toDelete += "Quicklisp:    $qlHome" }
if (Test-Path $cacheDir) { $toDelete += "ASDF 缓存:    $cacheDir" }
$rcHasQl = $false
if (Test-Path $rcFile) {
    $rcHasQl = [bool](Select-String -Path $rcFile -SimpleMatch 'quicklisp/setup.lisp' -Quiet -ErrorAction SilentlyContinue)
    if ($rcHasQl) { $toDelete += "sbclrc 引导行: $rcFile 中含 quicklisp/setup.lisp 的行" }
}
# -RemoveSbcl 会卸载系统 SBCL：总是先显式提示（Force 也不例外），并纳入确认清单
if ($RemoveSbcl) {
    $toDelete += '系统 SBCL：将执行 winget uninstall（需要管理员/UAC 确认）'
    Write-Host '注意：-RemoveSbcl 会卸载系统级 SBCL（非仓库内 .tools），卸载后由 install.ps1 重新安装。' -ForegroundColor DarkYellow
}
if (-not $Force) {
    Write-Host '将删除以下内容（之后会重新下载安装）：' -ForegroundColor Yellow
    if ($toDelete.Count) { $toDelete | ForEach-Object { Write-Host "  - $_" } }
    else { Write-Host '  （无）' }
    Write-Host ''
    if (-not (Confirm-Question '继续并重装？(y/N)')) { Write-Host '已取消。'; exit 0 }
}

# ---------- 2. 备份并删除 ----------
if ($RemoveSbcl) {
    Write-Host ''
    Write-Host '!! 即将卸载系统 SBCL (winget uninstall SBCL.SBCL) !!' -ForegroundColor Red
    if (-not $Force) {
        if (-not (Confirm-Question '确认卸载系统 SBCL？(y/N)')) {
            Write-Host '跳过 SBCL 卸载，仅重置 Quicklisp/缓存。' -ForegroundColor DarkYellow
            $RemoveSbcl = $false
        }
    }
}
if ($RemoveSbcl) {
    Info '卸载系统 SBCL（可能需要管理员/UAC）…'
    winget uninstall --id SBCL.SBCL --accept-source-agreements 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { Warn "winget 卸载 SBCL 返回 $LASTEXITCODE；继续重装流程。" }
}
if (Test-Path $rcFile) { Copy-Item $rcFile "$rcFile.bak-reset" -Force; Ok "已备份 $rcFile -> $rcFile.bak-reset" }
else { Skip '无 ~/.sbclrc' }

foreach ($item in @($qlHome, $cacheDir)) {
    if (Test-Path $item) { Remove-Item -Recurse -Force $item; Ok "已删除 $item" }
    else { Skip "不存在: $item" }
}
if ($rcHasQl -and (Test-Path $rcFile)) {
    $lines = Get-Content $rcFile | Where-Object { $_ -notmatch 'quicklisp/setup\.lisp' }
    Set-Content -Path $rcFile -Value $lines -Encoding Ascii
    Ok '已从 ~/.sbclrc 移除 Quicklisp 引导行'
}

# ---------- 3. 立即重装 ----------
Info '开始重新安装…'
$installer = Join-Path $PSScriptRoot 'install.ps1'
if ($WithDexador) { & $installer -WithDexador }
else              { & $installer }
exit $LASTEXITCODE
