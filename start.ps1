<#
  start.ps1 — Agent-CL 一键启动器

  用法：
    .\start.ps1                 # 默认启动交互式 REPL（真实模型）
    .\start.ps1 -Mode smoke     # 跑一轮真实 API 冒烟（需 key）
    .\start.ps1 -Mode test      # 跑全部 66 个单元/集成测试（不需 key）
    .\start.ps1 -Key sk-xxxx    # 临时指定 key（等价于设 AGENT_CL_API_KEY）
    .\start.bat                 # 同 start.ps1（可双击）

  key 解析顺序：参数 -Key > 环境变量 AGENT_CL_API_KEY
             > %USERPROFILE%\.agent-cl\api-key.txt > 交互输入（可选记住）
#>
param(
    [ValidateSet('repl', 'smoke', 'test', 'help')]
    [string]$Mode = 'repl',
    [string]$Key = '',
    [string]$Model = '',
    [string]$BaseUrl = ''
)

$ErrorActionPreference = 'Stop'
$root  = $PSScriptRoot
# 从任意目录启动都以仓库根为工作目录，REPL 里 /export、/load 的相对路径才稳定。
Set-Location $root
$offlineSbcl = Join-Path $root '.tools\sbcl\sbcl.exe'
$keyFile = Join-Path $env:USERPROFILE '.agent-cl\api-key.txt'

# Put Git's OpenSSL DLLs on PATH so cffi/cl+ssl can load them (Windows).
$gitBin = 'C:\Program Files\Git\mingw64\bin'
if ((Test-Path $gitBin) -and ($env:PATH -notlike "*$gitBin*")) {
    $env:PATH = "$gitBin;$env:PATH"
}

function Find-Sbcl {
    if (Test-Path $offlineSbcl) { return $offlineSbcl }          # 离线工具链
    $cmd = Get-Command sbcl -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }                             # PATH 上的系统 SBCL
    $g = Get-ChildItem 'C:\Program Files\Steel Bank Common Lisp' -Filter sbcl.exe -Recurse -ErrorAction SilentlyContinue |
         Sort-Object FullName -Descending | Select-Object -First 1
    if ($g) { return $g.FullName }                               # 官方默认安装目录
    return ''
}

function Write-Banner {
    param([string]$mode)
    Write-Host ''
    Write-Host '==================================================' -ForegroundColor DarkCyan
    Write-Host '  Agent-CL (Common Lisp Agent)' -ForegroundColor Cyan
    Write-Host "  模式: $mode    目录: $root" -ForegroundColor Gray
    Write-Host '==================================================' -ForegroundColor DarkCyan
}

function Test-KeyAvailable {
    return -not [string]::IsNullOrWhiteSpace($env:AGENT_CL_API_KEY)
}

function Resolve-Key {
    param([bool]$needKey)
    if (-not [string]::IsNullOrWhiteSpace($Key)) {
        $env:AGENT_CL_API_KEY = $Key
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($env:AGENT_CL_API_KEY)) { return }

    # 记忆的 key（仓库外）
    if (Test-Path $keyFile) {
        $saved = (Get-Content $keyFile -Raw).Trim()
        if ($saved) { $env:AGENT_CL_API_KEY = $saved; return }
    }

    if ($needKey) {
        Write-Host '没有找到 API key。请粘贴你的 DeepSeek/OpenAI key（sk- 开头）：' -ForegroundColor Yellow
        $k = Read-Host 'key'
        if (-not [string]::IsNullOrWhiteSpace($k)) {
            $env:AGENT_CL_API_KEY = $k.Trim()
            $remember = Read-Host '保存到 %USERPROFILE%\.agent-cl\api-key.txt 以便下次免输入？(y/N)'
            if ($remember -match '^y') {
                $dir = Split-Path $keyFile -Parent
                New-Item -ItemType Directory -Force -Path $dir | Out-Null
                Set-Content -Path $keyFile -Value $env:AGENT_CL_API_KEY -Encoding Ascii
                Write-Host "已保存: $keyFile" -ForegroundColor Green
            }
        } else {
            Write-Host '未提供 key：真实模型调用将失败；可用 mock/测试模式。' -ForegroundColor DarkYellow
        }
    }
}

# ---------- 环境 ----------
$sbcl = Find-Sbcl
if (-not $sbcl) {
    Write-Error '未找到 SBCL：离线 .tools 已清理或缺失。请先运行 .\scripts\install.ps1 安装官方 SBCL + Quicklisp，或在仓库内重建离线工具链。'
    exit 1
}
if ($sbcl -eq $offlineSbcl) {
    $env:SBCL_HOME = Split-Path $sbcl -Parent          # 仅离线工具链需要
} else {
    Remove-Item Env:SBCL_HOME -ErrorAction SilentlyContinue
}
$env:XDG_CACHE_HOME = Join-Path $root '.tools\cache'
if ($Model)  { $env:AGENT_CL_MODEL  = $Model }
if ($BaseUrl){ $env:AGENT_CL_BASE_URL = $BaseUrl }

# ---------- 模式分发 ----------
switch ($Mode) {
    'help' {
        Get-Help $PSCommandPath
        exit 0
    }
    'test' {
        Write-Banner 'test (mock 确定性测试)'
        & $sbcl --script (Join-Path $root 'scripts\run-tests.lisp')
        exit $LASTEXITCODE
    }
    'smoke' {
        Write-Banner 'smoke (真实 API 冒烟)'
        Resolve-Key -needKey $true
        if (-not (Test-KeyAvailable)) {
            Write-Host '缺少 key，无法冒烟。用法: .\start.ps1 -Mode smoke -Key sk-...' -ForegroundColor Red
            exit 2
        }
        & $sbcl --script (Join-Path $root 'scripts\smoke.lisp')
        exit $LASTEXITCODE
    }
    default {
        Write-Banner 'repl (交互式对话)'
        Resolve-Key -needKey $true
        if (Test-KeyAvailable) {
            Write-Host '已启用真实模型（dexador 直连自动开启）。空行或 Ctrl-C 退出。' -ForegroundColor Green
        } else {
            Write-Host '未配置 key：可离线启动，但模型调用会报错；请重新运行并提供 key。' -ForegroundColor DarkYellow
        }
        & $sbcl --script (Join-Path $root 'scripts\repl.lisp')
        exit $LASTEXITCODE
    }
}
