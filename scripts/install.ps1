<#
  install.ps1 — Agent-CL 安装器（标准联网路径）

  目标环境：正常联网的机器（有可用 TLS/网络、可用 winget 或手动装过 SBCL）。
  方案：官方 SBCL + Quicklisp + ql:quickload 项目依赖（无需仓库内 .tools/vendored）。

  用法：
    .\scripts\install.ps1 -Mode help        # 查看说明
    .\scripts\install.ps1 -Mode preflight   # 只做环境检测
    .\scripts\install.ps1                    # 安装（SBCL → Quicklisp → 依赖 → 加载验证）
    .\scripts\install.ps1 -QlHome D:\ql      # Quicklisp 装到指定目录
    .\scripts\install.ps1 -CacheDir D:\agent-cl-cache   # 构建缓存外置
    .\scripts\install.ps1 -WithDexador       # 额外装 dexador/cl+ssl（进程内 HTTPS 直连用）
    .\scripts\install.ps1 -SBCLExe "C:\...\sbcl.exe"   # 已有 SBCL 时跳过安装

  轻量验收：安装完成会加载 agent-cl 系统（能 (asdf:load-system :agent-cl) 即视为 OK），
  不自动跑测试；如需跑 50 个 mock 测试请加 -RunTests。
#>
param(
    [ValidateSet('install', 'preflight', 'help')]
    [string]$Mode = 'install',
    [string]$SBCLExe = '',
    [string]$QlHome = '',
    [string]$CacheDir = '',
    [switch]$WithDexador,
    [switch]$RunTests
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent                 # 仓库根
$stage = Join-Path $env:TEMP 'agent-cl-install'

function Info  { Write-Host "==> $args" -ForegroundColor Cyan }
function Ok    { Write-Host "[OK] $args" -ForegroundColor Green }
function Skip  { Write-Host "[SKIP] $args" -ForegroundColor DarkGray }
function Warn  { Write-Host "[WARN] $args" -ForegroundColor DarkYellow }
function Fail  { Write-Host "[FAIL] $args" -ForegroundColor Red }

function Get-SBCL {
    # 返回 sbcl 可执行文件路径，找不到返回 ''
    if ($SBCLExe -and (Test-Path $SBCLExe)) { return (Resolve-Path $SBCLExe).Path }
    $cmd = Get-Command sbcl -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # winget 装完可能当前会话 PATH 没刷新：查常见安装位置
    $found = Get-ChildItem 'C:\Program Files\Steel Bank Common Lisp' -Filter sbcl.exe -Recurse -ErrorAction SilentlyContinue |
             Sort-Object FullName -Descending | Select-Object -First 1
    if ($found) { return $found.FullName }
    ''
}

function Get-QlHome {
    if ($QlHome) { return $QlHome.TrimEnd('\') }
    (Join-Path $env:USERPROFILE 'quicklisp')
}

function Test-Net {
    try {
        $r = Invoke-WebRequest -Uri 'https://beta.quicklisp.org/quicklisp.lisp' -Method Head -TimeoutSec 15 -UseBasicParsing
        return ($r.StatusCode -eq 200)
    } catch { return $false }
}

function Ensure-SBCL {
    $exe = Get-SBCL
    if ($exe) { Ok "找到 SBCL: $exe"; return $exe }

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Fail '未找到 SBCL 且没有 winget。请手动安装后重试：'
        Fail '  https://www.sbcl.org/platform-table.html (Windows MSI)'
        exit 2
    }
    Info "安装 SBCL (winget)…（可能需要管理员/UAC，视策略而定）"
    # winget 输出 UTF-8；PS5.1 默认按 GBK 解码会乱码，临时切到 UTF-8
    $oldConsoleOut = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        & $winget.Source install -e --id SBCL.SBCL --accept-source-agreements --accept-package-agreements --disable-interactivity 2>&1 | Out-Host
    } finally {
        [Console]::OutputEncoding = $oldConsoleOut
    }
    if ($LASTEXITCODE -ne 0) {
        Fail "winget 安装失败 (exit $LASTEXITCODE)，请手动安装 MSI 后重跑。"
        exit 2
    }
    $exe = Get-SBCL
    if (-not $exe) {
        Fail 'SBCL 已安装但找不到 sbcl.exe，请新开终端或指定 -SBCLExe。'
        exit 2
    }
    Ok "SBCL: $exe"
    return $exe
}

function Ensure-Quicklisp {
    param([string]$sbcl)
    $qlRoot = Get-QlHome
    $setup = Join-Path $qlRoot 'setup.lisp'
    if (Test-Path $setup) { Ok "Quicklisp 已存在: $qlRoot"; return $qlRoot }

    if (-not (Test-Net)) {
        Fail '无法访问 beta.quicklisp.org（网络/TLS 问题）。请检查网络后重试；'
        Fail 'Windows 上若提示 TLS 不支持，可参考 https://www.quicklisp.org/beta/ 安装说明。'
        exit 3
    }
    Info '下载 Quicklisp 引导文件…'
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $qlLisp = Join-Path $stage 'quicklisp.lisp'
    Invoke-WebRequest -Uri 'https://beta.quicklisp.org/quicklisp.lisp' -OutFile $qlLisp -UseBasicParsing -TimeoutSec 60
    if (-not (Test-Path $qlLisp) -or (Get-Item $qlLisp).Length -lt 1000) {
        Fail '下载 quicklisp.lisp 失败。'
        exit 3
    }
    Info "安装 Quicklisp 到 $qlRoot …"
    # 用临时 .lisp 驱动文件执行安装，避免 --eval 传参时引号被 PowerShell 吞掉
    $pathArg = $qlRoot.Replace('\', '/')
    $driver = Join-Path $stage 'install-ql.lisp'
    $driverLines = @(
        ";; Agent-CL install helper",
        "(load `"$($qlLisp.Replace('\','/'))`")",
        "(quicklisp-quickstart:install :path `"$pathArg`")",
        "(format t `"~&QUICKLISP-INSTALLED~%`")"
    )
    Set-Content -Path $driver -Value $driverLines -Encoding Ascii
    # NOTE: --script must be the FIRST option (else SBCL ignores it and starts a REPL)
    # Redirect to a log file with a timeout so failures/cards are visible.
    $qlOut = Join-Path $stage 'quicklisp-install.out.log'
    $qlErr = Join-Path $stage 'quicklisp-install.err.log'
    Remove-Item $qlOut, $qlErr -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $sbcl -ArgumentList @('--script', $driver) `
            -RedirectStandardOutput $qlOut -RedirectStandardError $qlErr `
            -PassThru -NoNewWindow
    try { $proc | Wait-Process -Timeout 240 -ErrorAction Stop } catch {
        Fail 'Quicklisp 安装超过 240 秒，已中断（网络慢或卡住）。日志保留供排查。'
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        exit 3
    }
    # NB: keep these on the HOST stream — anything written to the pipeline inside
    # a function becomes part of its return value.
    Write-Host '--- 安装输出（尾 30 行）---' -ForegroundColor Gray
    Write-Host ((Get-Content $qlOut -Tail 30 -ErrorAction SilentlyContinue) -join "`n")
    Write-Host ((Get-Content $qlErr -Tail 15 -ErrorAction SilentlyContinue) -join "`n")
    Write-Host "--- 退出码: $($proc.ExitCode) ---" -ForegroundColor Gray
    if (-not (Test-Path $setup)) {
        Fail 'Quicklisp 安装未生成 setup.lisp（常见于本机缺 TLS 支持）。'
        Fail '请按 https://www.quicklisp.org/beta/ 手动安装，成功后重跑本脚本。'
        exit 3
    }
    Ok "Quicklisp: $setup"
    # 写入 ~/.sbclrc 以便之后每个 SBCL 会话自动可用（若已有该行则跳过）
    $rc = Join-Path $env:USERPROFILE '.sbclrc'
    $loadLine = "(load `"$($setup.Replace('\','/'))`")"
    if (-not (Test-Path $rc) -or -not (Select-String -Path $rc -SimpleMatch $loadLine -Quiet -ErrorAction SilentlyContinue)) {
        Add-Content -Path $rc -Value $loadLine -Encoding Ascii
        Ok "已写入 $rc （每会话自动加载 Quicklisp）"
    }
    return $qlRoot
}

function Install-Deps {
    param([string]$sbcl, [string]$qlHome)
    $setup = Join-Path $qlHome 'setup.lisp'
    # Keep these as a plain list of symbols inserted into a (list ...) form so the
    # generated Lisp never evaluates (:alexandria ...) as a function call.
    $deps = ':alexandria :yason :split-sequence :bordeaux-threads'
    if ($WithDexador) { $deps = ':alexandria :yason :split-sequence :bordeaux-threads :dexador :dexador-usocket :cl+ssl' }
    $repoArg = $repo.Replace('\', '/')
    $script = @"
(require :asdf)
(load "$($setup.Replace('\','/'))")
(ql:quickload (list $deps) :silent t)
(push #P"$repoArg/" asdf:*central-registry*)
(asdf:load-system :agent-cl)
(format t "~&INSTALL-DEPS-OK~%")
"@
    $tmp = Join-Path $stage 'verify-agent.lisp'
    Set-Content -Path $tmp -Value $script -Encoding Ascii
    Info '安装依赖并验证 agent-cl 可加载（首次会编译，稍候）…'
    $depOut = Join-Path $stage 'deps-install.out.log'
    $depErr = Join-Path $stage 'deps-install.err.log'
    Remove-Item $depOut, $depErr -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $sbcl -ArgumentList @('--script', $tmp) `
            -RedirectStandardOutput $depOut -RedirectStandardError $depErr `
            -PassThru -NoNewWindow
    try { $proc | Wait-Process -Timeout 900 -ErrorAction Stop } catch {
        Fail '依赖安装超过 900 秒，已中断。'
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        exit 4
    }
    Write-Host '--- 依赖安装输出（错误头 35 行 / 尾 60 行）---' -ForegroundColor Gray
    Write-Host '== 头 ==' -ForegroundColor Yellow
    Write-Host ((Get-Content $depErr -TotalCount 35 -ErrorAction SilentlyContinue) -join "`n")
    Write-Host '== 尾 ==' -ForegroundColor Yellow
    Write-Host ((Get-Content $depOut -Tail 60 -ErrorAction SilentlyContinue) -join "`n")
    Write-Host ((Get-Content $depErr -Tail 30 -ErrorAction SilentlyContinue) -join "`n")
    Write-Host "--- 退出码: $($proc.ExitCode) ---" -ForegroundColor Gray
    if (-not ((Get-Content $depOut -Raw -ErrorAction SilentlyContinue) -match 'INSTALL-DEPS-OK')) {
        Fail '依赖安装或 agent-cl 加载失败（见上方输出）。'
        exit 4
    }
    Ok '依赖安装完成，agent-cl 加载成功。'
}

function Show-Usage {
    Get-Help $PSCommandPath
}

# Put Git's OpenSSL DLLs on PATH so cffi/cl+ssl can load them (Windows).
$gitBin = 'C:\Program Files\Git\mingw64\bin'
if ((Test-Path $gitBin) -and ($env:PATH -notlike "*$gitBin*")) {
    $env:PATH = "$gitBin;$env:PATH"
}

# ---------- 入口 ----------
$cache = if ($CacheDir) { $CacheDir } else { Join-Path $repo '.tools\cache' }
$env:XDG_CACHE_HOME = $cache

switch ($Mode) {
    'help'    { Show-Usage; exit 0 }
    'preflight' {
        Write-Host '==> Agent-CL 预检' -ForegroundColor Cyan
        if (Get-SBCL)   { Ok "SBCL: $(Get-SBCL)" }   else { Warn 'SBCL 未安装（将由 winget 安装或需手动安装）' }
        if (Test-Path (Join-Path (Get-QlHome) 'setup.lisp')) { Ok 'Quicklisp 已就绪' } else { Warn 'Quicklisp 未安装（安装模式会处理）' }
        if (Get-Command winget -ErrorAction SilentlyContinue) { Ok 'winget 可用' } else { Warn '无 winget' }
        if (Test-Net) { Ok '网络可达 beta.quicklisp.org' } else { Fail '网络不可达 beta.quicklisp.org' }
        Write-Host '预检完成。'
        exit 0
    }
    default {
        Write-Host '==================================================' -ForegroundColor DarkCyan
        Write-Host '  Agent-CL 安装器（标准联网路径）' -ForegroundColor Cyan
        Write-Host "  仓库: $repo     缓存: $cache" -ForegroundColor Gray
        Write-Host '==================================================' -ForegroundColor DarkCyan

        $sbcl = Ensure-SBCL
        $ql   = Ensure-Quicklisp $sbcl
        Install-Deps $sbcl $ql

        if ($RunTests) {
            Info '运行 mock 测试套件（50 用例）…'
            & (Get-SBCL) --script (Join-Path $repo 'scripts\run-tests.lisp')
            if ($LASTEXITCODE -ne 0) { Fail '测试未全绿'; exit 5 }
            Ok '50/50 测试通过。'
        }
        Write-Host ''
        Write-Host '安装完成。下一步：' -ForegroundColor Green
        Write-Host "  cd $repo"
        Write-Host '  .\start.ps1                 # 交互式 REPL（真实模型）'
        Write-Host '  .\start.ps1 -Mode test      # mock 测试'
        if ($WithDexador) {
            Write-Host '  已装 dexador/cl+ssl：repl/smoke 将用进程内 HTTPS 直连。'
        }
        Write-Host '在 Lisp 里直接用： (ql:quickload :agent-cl)  （需先把本仓库加入 quicklisp 本地目录或 asdf 中央注册）'
    }
}
