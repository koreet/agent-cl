# agent-cl

用 Common Lisp（SBCL）从零构建的「现代 Agent」：OpenAI 兼容 Tool calling、ReAct 自主循环、
内置工具集、会话记忆、流式输出、结构化输出，以及基于 Lisp 宏的 **DSL 深度定制**能力。

> 架构设计见 [docs/architecture.md](docs/architecture.md)（含 M0–M6 里程碑与验收标准）。
> 实现进度与离线环境注记见本文「状态」与「环境」两节。

## 现代 Agent 功能（实现清单）

- **ReAct 引擎 + 工具调用**：内置 shell/file/time/code.exec(写代码执行)/memory.set|recall(跨会话记忆)/web.search(免 key DuckDuckGo)/task.delegate(子 agent 独立会话，只回结论省 token)
- **Plan-then-Execute**：REPL `/plan <任务>`：拆步骤→逐步执行→汇总
- **长会话自动压缩**：超预算自动把旧消息凝成摘要（`/compact` 手动、`/budget` 调阈值）
- **流式输出 + Markdown 渲染**：SSE 逐字输出；标题/粗体/行内码/代码块（关键字着色）/表格行着色（`NO_COLOR=1` 或 `/color off` 关闭）
- **REPL 命令面板**：`/help /tools /memory /export <f> /load <f> /new /compact /budget /plan /color /quit`
- **会话导出/载入**：JSONL 往返，可复盘/换机续聊
- 工具执行可视化（`[tool xxx -> OK]`）、Ctrl-C 优雅退出

`task.delegate`/`/plan` 等真实能力需联网模型（默认 DeepSeek）验证；mock 套件覆盖协议/引擎确定性语义。

## 状态（当前里程碑进度）

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0 | SBCL 2.6.8 + 依赖引导 + ASDF 骨架（包/错误层级/日志/JSON） | ✅ |
| M1 | LLM 传输层：messages 信封、OpenAI 兼容 codec、SSE 流式（工具参数分片按 index 拼接）、mock transport | ✅ |
| M2 | ReAct 引擎：schema 校验器、工具注册表、内置工具（shell/file/time/code.exec/memory/web.search/task.delegate）、守卫、CLOS 扩展钩子 | ✅ |
| M3 | DSL 层：`defdsl-tool`/`defcommand`/`defschema`/`defpolicy`/`defguard`/`defagent` + 默认禁用的白名单沙箱 | ✅ |
| M4 | 会话事件日志（JSONL）+ 导出/载入 + 暂停/恢复 + REPL 入口 | ✅ |
| M5 | 记忆预算/自动压缩（`/compact`/`/budget`）+ Plan-then-Execute（`/plan`） | ✅ |
| M6 | 真实 API 冒烟 + Windows 11 真机全量回归 | ✅ DeepSeek 端到端通过——SBCL 进程内 dexador+cl+ssl 直连（`scripts/smoke.lisp` 优先 dexador，缺依赖回退 node 钩子）；回归实录见 `docs/architecture.md` §14 |

**测试**：`55/55` 通过（`scripts/run-tests.lisp` 或 `.\start.ps1 -Mode test`，全部 mock 确定性测试）+ 真实 DeepSeek 冒烟 `[SMOKE-OK]`（Windows 11 真机全量回归记录见 `docs/architecture.md` §14）。

**工具名映射**：DeepSeek/OpenAI 要求函数名匹配 `^[a-zA-Z0-9_-]+$`，因此 DSL 点号工具名（如 `time.now`）在线上边界自动映射为 `time_now`（`src/tools/registry.lisp` 的 `sanitize-tool-name`/`find-tool` 反向查找），本地 DSL 命名不受影响。

## 运行测试

```powershell
cd C:\...\agent-cl
.\start.ps1 -Mode test      # 55 个 mock 确定性测试（无需 key、无需网络）
# 或直接：
& (Get-Command sbcl).Source --script scripts\run-tests.lisp
```

## 快速上手（DSL 视角）

```lisp
;; L2：领域 DSL —— 声明即注册为模型可调用的工具
(defdsl-tool "calc.add" "两数相加"
    ((a :number :description "加数" :required t)
     (b :number :description "被加数" :required t))
  (values (format nil "~a" (+ (getf args :A) (getf args :B))) :ok))

;; L1：指令 DSL —— 声明式编排一个 agent
(defpolicy chatty (:max-steps 30 :temperature 0.7 :parallel-tools t))

(defagent my-bot
  (:model deepseek-chat :base-url https://api.deepseek.com/v1
   :system "你是 CL 工程师助手，可以自己写代码执行。"
   :tools (shell.run file.read file.write time.now code.exec calc.add)
   :policy chatty))

;; code.exec：让 agent“自己写代码→执行→拿结果”→ 继续推理
(agent-cl.loop:run my-bot "写段 Python 算 1..10 的平方和并执行，告诉我结果")

(agent-cl.loop:run my-bot "把当前目录列表写入 notes.txt")   ; ReAct 循环
```

## 快速开始（一键启动）

仓库根目录提供启动器（自动配置 SBCL/缓存环境）：

```powershell
cd C:\...\agent-cl
.\start.ps1                 # 交互式 REPL（真实对话，自动接 dexador 直连）
.\start.ps1 -Mode smoke     # 真实 API 冒烟（需 key）
.\start.ps1 -Mode test      # 55 个 mock 确定性测试（无需 key）
.\start.ps1 -Key sk-xxxx    # 临时指定 key
start.bat                   # 等价（可双击，参数透传）
```

key 解析顺序：`-Key` 参数 > 环境变量 `AGENT_CL_API_KEY` >
`%USERPROFILE%\.agent-cl\api-key.txt`（仓库外，不会误提交）> 交互输入（可选记住）。
可选覆盖：`-Model deepseek-chat` / `-BaseUrl https://api.deepseek.com/v1`
（等价环境变量 `AGENT_CL_MODEL` / `AGENT_CL_BASE_URL`）。

## 环境注记（为什么与标准 CL 工程不同）

项目最初在**无管理员、winget 别名损坏、schannel TLS 被禁、无可用 Quicklisp 网络**的
Windows 沙箱中构建，因此保留了几处自适应设计（在正常联网机器上均平滑可用）：

- 依赖引导：`scripts/*.lisp` 会先探测 Quicklisp（`~/quicklisp/setup.lisp`）；存在则
  `ql:quickload` alexandria/yason/split-sequence/bordeaux-threads 四个依赖后
  `asdf:load-system :agent-cl`。无 Quicklisp 时退回 vendored `.tools/deps` 布局
  （沙箱时代产物，本仓库不携带；`scripts/env.lisp` 记录了该布局的加载方式）。
- 真实 HTTP：`src/llm/transport.lisp` 把网络调用委托给 `*http-fetch-hook*`；
  正常机器走**进程内 dexador 直连**：`scripts/dev-http.lisp` 加载 cffi/cl+ssl/dexador、
  强制 usocket 后端（绕开 Windows 默认 WinHTTP/schannel）、用 Git 自带 CA 包做证书校验
  （Windows 下需把 `C:\Program Files\Git\mingw64\bin` 加入 PATH，`start.ps1` 自动处理）；
  `scripts/smoke.lisp` 优先走该路径，失败才回退 node 钩子（`scripts/http-request.js`）。
  dexador 对 ≥400 响应会先抛可继续错误，`dev-http.lisp` 已将其转为携带服务端错误正文的
  干净 `transport-error`（4xx 不重试、5xx 可重试）。
- ASDF fasl 缓存经 `XDG_CACHE_HOME` 重定向到仓库内 `.tools/cache`（已 gitignore）。

**有意偏离架构文档的实现取舍**：
1. 测试框架：doc 首选 rove → 自带 ~90 行 harness（`tests/harness.lisp`，宏兼容）；
2. 日志：doc 首选 log4cl → `src/core/log.lisp` 自带分级日志（备选方案）；
3. CLI/时间/uuid：clingon/local-time/uuid 未引入，分别以极简实现替代。
