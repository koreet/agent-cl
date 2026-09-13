# agent-cl

> 用 Common Lisp（SBCL）从零构建的「现代 Agent」：OpenAI 兼容 Tool calling、ReAct 自主循环、
> 流式输出、会话事件日志、内置工具集，以及基于 Lisp 宏的 **DSL 深度定制**能力。

**语言**：[English](README.en.md) · 中文

架构设计见 [docs/architecture.md](docs/architecture.md)（含 M0–M6 里程碑与验收标准）。

---

## 这是什么

一个可自托管、可深度改造的编码/研究型 agent。核心循环（`src/loop/engine.lisp`）本身很小：
**step → LLM 往返 → 若有工具调用则校验并执行 → 回灌观察 → 重复，直到模型给出答案或守卫触发**。
所有扩展点都是 CLOS 泛型函数（默认空实现），因此行为定制靠**继承 agent 类**完成，不需要改循环。

它同时提供一层 Lisp 宏 DSL：把「工具、策略、守卫、审计规则、目标、原则、身份、记忆、元认知」
写成声明式代码，声明本身就是 schema、线上描述和校验器的唯一来源。

**当前状态**：单元/集成测试 **324 passed, 0 failed**（全部 mock、可离线运行），
真实 DeepSeek 端到端冒烟 `[SMOKE-OK]`、真实流式 `[LIVE-STREAM-OK]`。

---

## 功能亮点

**引擎与协议**

- ReAct 循环 + 并行工具调用（`policy-parallel-tools`，串行模式下未执行的调用也会留下显式说明）
- SSE 流式输出：工具参数按 `index` 分片拼接；`[DONE]` 变体/心跳行/截断 chunk 都有明确处理
- 瞬态失败自动重试（5xx/429，指数退避 + 可中断等待）；**已经输出过 token 的流不重试**（避免重复显示）
- 消息序列不变量：每个 `tool_calls` 必有对应 tool 结果；中断/串行/停机都会补齐占位，避免后续请求 400
- 用量与缓存命中率统计；被截断的答复（`finish_reason: length`）会被标记；空回答不当成完成
- 上下文裁剪按**整回合**进行（绝不拆散 tool_calls 与 tool 结果）

**工具集（9 个内置）**

| 工具 | 说明 |
|---|---|
| `shell.run` | 执行命令，带真实超时看门狗（Windows 上 `uiop` 的超时无效，这里自行杀进程树） |
| `file.read` / `file.write` | 读写文本，默认限制在工作区根内（见下「安全模型」） |
| `time.now` | 当前 UTC 时间（ISO-8601） |
| `code.exec` | 让 agent 自己写代码并执行（python / sbcl / sh），返回真实退出码与 stderr |
| `memory.set` / `memory.recall` | 跨会话持久记忆（`~/.agent-cl/memory/`，键到文件名是单射编码） |
| `web.search` | 联网检索：默认 Tavily（需 key），可 `:backend "ddg"` 用无 key 的 DuckDuckGo；带结果缓存、进程预算、子 agent 配额与熔断器 |
| `task.delegate` | 派子 agent（独立会话、只回结论省 token）；按对象身份剔除委派工具、与父工具集求交、层级上限 |

**会话与记忆**

- 事件日志式会话：`~/.agent-cl/sessions/<id>/events.jsonl`，一行一个事件，可审计、可恢复
- `/sessions` 列出（默认隐藏只有检查点、没有对话的空会话，`/sessions all` 全看）、`/use` 按编号/id/前缀切换并回放历史
- `/export` / `/load` JSONL 往返；载入时会净化被截断的会话（孤立 tool 结果、悬空 tool_calls）
- 退出时若本次会话一句话都没说，不会留下空条目

**界面**

- REPL：流式 Markdown 渲染（标题/粗体/行内码/代码块着色/表格对齐）、底部常驻状态栏 + 输入栏（终端可固定时）、`NO_COLOR=1` 或 `/color off` 关闭彩色
- 只读控制台 GUI（Hunchentoot，`127.0.0.1:8977`）：浏览真实会话事件日志；聊天框是 mock，不写会话

**安全模型**

- **工作区限制**：`file.read`/`file.write` 限定在仓库根内。校验分两层——先做词法折叠（`..` 归一化），
  再**按文件系统属性拒绝链接**（Windows reparse point / POSIX symlink）：链接可以指向工作区外，
  纯字符串校验穿不过它。可用 `(set-file-workspace-root nil)` 显式放开。
- **审计规则可预防**：`defaudit` 的 `:applies-to` 会在工具**执行前**拦截调用（`:on-violation :block` 拒绝执行、
  `:warn` 放行并标注结果），而不是等工具跑完才抱怨。规则按工具累积，且 wire 名（`file_write`）
  与 DSL 名（`file.write`）都能匹配。
- **可执行沙箱默认关闭**：`*dsl-execution-mode*` 为 `:off`，需 `with-dsl-sandbox` 显式开启；
  只有白名单内的纯函数可调用（且只从 `CL` 包解析，避免宿主同名函数被穿透），并限制步数、参数规模、
  整数大小与结果长度，环形结构直接拒绝。
- **自我改进有门禁**：`improve-file` 只允许改仓库内文件、拒绝改门禁自身（`scripts/run-tests.lisp`、
  `tests/`、`agent-cl.asd`、`.git/`、`.tools/`），按"备份 → 打补丁 → 跑真实测试套件 → 通过则采纳 /
  失败则回滚"执行；补丁已生效后的清理失败不会被谎报成"被拒绝"。

---

## 快速开始

### Windows（一键）

```powershell
cd C:\path\to\agent-cl
.\start.ps1                 # 交互式 REPL（真实对话）
.\start.ps1 -Mode smoke     # 真实 API 冒烟（需要 key）
.\start.ps1 -Mode test      # 全部单元/集成测试（不需要 key、不需要网络）
.\start.ps1 -Key sk-xxxx    # 临时指定 key
.\start.ps1 -Model deepseek-chat -BaseUrl https://api.deepseek.com/v1
start.bat                   # 等价入口，可双击，参数透传
```

key 解析顺序：`-Key` > 环境变量 `AGENT_CL_API_KEY` > `%USERPROFILE%\.agent-cl\api-key.txt` > 交互输入。
`start.ps1` 会自动把 Git 的 `mingw64\bin` 加进 PATH（`cl+ssl` 需要那里的 `libcrypto`/`libssl` DLL）。

### 任意平台（直接跑）

```bash
sbcl --script scripts/run-tests.lisp    # 测试
sbcl --script scripts/smoke.lisp        # 真实 API 冒烟（需要 key）
sbcl --script scripts/repl.lisp         # REPL
sbcl --script console/server.lisp       # 控制台 GUI（http://127.0.0.1:8977）
```

### 依赖

- **SBCL 2.6.x**（Windows 上默认装在 `C:\Program Files\Steel Bank Common Lisp\`，`start.ps1` 会自己找）
- **Quicklisp**（`~/quicklisp/setup.lisp`）提供四个依赖：`alexandria`、`yason`、`split-sequence`、`bordeaux-threads`
  （若存在 vendored `.tools/deps` 布局则优先用它，离线可用）
- 可选：`dexador` + `cl+ssl` + `cffi` —— 进程内 HTTPS。没有它们时 REPL 仍能启动，但真实调用会报清晰的
  transport error（`scripts/smoke.lisp` 会退回 node 钩子 `scripts/http-request.js`）
- 可选：`hunchentoot`（控制台 GUI）、`python`（`code.exec` 的 python 语言）、Git for Windows（`sh` 与证书包）

---

## REPL 命令

| 命令 | 作用 |
|---|---|
| `/help` | 命令帮助 |
| `/tools` | 列出当前可用工具 |
| `/memory` | 列出跨会话记忆键 |
| `/export <file>` | 把当前会话导出为 JSONL |
| `/load <file>` | 载入 JSONL 会话继续对话（BOM/坏行都会跳过并提示） |
| `/new` | 另起新会话（当前自动存档） |
| `/sessions [all]` | 列出已保存会话（默认隐藏无对话的空会话） |
| `/use [编号\|id\|前缀]` | 切换会话；不带参数则交互选择并回放历史 |
| `/color on\|off` | 开关 ANSI 颜色（不带参数只报告状态） |
| `/usage` | 模型 / token 用量 / 工作路径 |
| `/model [名称]` | 从 API 拉取模型列表并选择，或直接切换 |
| `/plan <任务>` | Plan-then-Execute：拆步骤 → 逐步执行 → 汇总 |
| `/demo` | Markdown 渲染 + 状态栏自检 |
| `/engine new\|legacy` | 新/旧渲染引擎（legacy 无代码围栏高亮） |
| `/footer on\|off` | 开关底部常驻状态栏与输入栏 |
| `/quit` · `/exit` | 退出（没有对话内容的空会话不会保留） |

`Ctrl-C` 的行为：**执行中**（模型回合、`/plan`、`/model`）中断当前工作并保留会话；**在提示符处**退出。

---

## DSL 一览

```lisp
;; L2：领域工具 —— 声明即注册为模型可调用的工具（参数声明同时是 schema 与线上描述）
(defdsl-tool "calc.add" "两数相加"
    ((a :number :description "加数" :required t)
     (b :number :description "被加数" :required t))
  (values (format nil "~a" (+ (getf args :A) (getf args :B))) :ok))

;; L1：策略 / 守卫 / agent
(defpolicy chatty (:max-steps 30 :temperature 0.7 :parallel-tools t))

(defguard token-heavy (a)
  (when (> (agent-cl.loop:agent-usage-total a) 200000) "token 用量过高"))

(defagent my-bot
  (:model "deepseek-chat" :base-url "https://api.deepseek.com/v1"
   :system "你是 CL 工程师助手，可以自己写代码执行。"
   :tools (shell.run file.read file.write time.now code.exec calc.add)
   :policy chatty))

(agent-cl.loop:run my-bot "写段 Python 算 1..10 的平方和并执行，告诉我结果")

;; 审计规则：在工具执行前拦截（:applies-to 是工具名；:governed-by 只是引用）
;; 注意：:check 体只拿到 agent（引擎的工具守卫协议会把工具名与参数交给适配器，
;; 但适配器只转交 agent），所以规则依据的是可观察的 agent / 世界状态。
(defaudit stop-unbounded-work
  (:applies-to file.write)
  (:on-violation :block)
  (:check (when (agent-cl.loop:agent-stopped-p agent) "已停机，不再写文件")))

;; 目标契约：子目标按代码走，:done-when 是本地谓词（不花模型调用判断"做完了吗"）
(defgoal fix-bug
  (:intent "修好失败的测试")
  (:subgoals reproduce diagnose fix verify)
  (:done-when (and (probe-tests-pass) t))
  (:on-failure (retry :max 2)))

;; 原则与宪法：最高优先级原则在注册时被"冻结"，不可被静默降级
(defprinciple data-integrity (:priority 100)
  (:statement "用户数据完整性优先于任务完成速度")
  (:constrains workspace-write))

;; 元认知 / 身份 / 叙事记忆
(defintrospect auth-rework
  (:based-on ((has-relevant-file-p) (last-test-passed-p)))
  (:threshold 0.6) (:on-low :ask-clarifying-question))

(defidentity founder
  (:core-traits (:honesty 1.0) (:caution 0.7))
  (:anchor "诚实优先；不确定就说不确定"))

(defmemory failed-migration-42
  (:content "上次 auth 迁移边界条件挂了") (:salience 0.8)
  (:recall-when (goal-active-p 'refactor-auth)))
```

> 注意：`defaudit` **不吃** lambda-list（不要写 `(defaudit name () ...)`）；
> `defprinciple`/`defintrospect`/`defidentity`/`defmemory`/`defgoal` 后面那个装饰性的 `()` 是**可选**的，
> 写与不写都行（省略时不会再吞掉第一个 clause）。

沙箱（默认关闭）：

```lisp
(agent-cl.dsl:with-dsl-sandbox (:mode :interpreter :max-steps 100 :max-sequence 10000)
  (agent-cl.dsl:dsl-eval-safe '(+ 1 2)))     ; => "3"
```

---

## 测试与验证

```powershell
.\start.ps1 -Mode test                          # 或：
& "C:\Program Files\Steel Bank Common Lisp\sbcl.exe" --script scripts\run-tests.lisp
```

- 自研极简 harness（`tests/harness.lisp`，`deftest`/`ok`/`is-equal`/`signals-error`），不引入测试框架依赖
- **一个测试必须至少有一条断言**：没有断言的测试会被判为失败（这条规则上线后立刻抓出三个"永远通过"的测试）
- 测试全部用 mock transport / 本地文件系统，**不需要 key、不需要网络**；真实 API 路径由 `scripts/smoke.lisp`
  和 `.tools/verify-live-stream.lisp` 覆盖
- `.tools/` 下还留有本轮审计用的验证脚本（`check-scripts.py` 入口脚本零诊断检查、
  `drive-repl*.py` 脚本化 REPL 会话、`verify-fresh-clone.py` 全新克隆跑测试、
  `verify-fixes*.lisp` 安全项复现），可随时复跑

真机验证记录（本轮审计后）：

| 项目 | 结果 |
|---|---|
| 单元/集成测试 | 324 passed, 0 failed，无编译警告 |
| 入口脚本加载（repl / console） | 零编译诊断 |
| 真实 DeepSeek 冒烟 | `[SMOKE-OK]`：2 步、1 次工具调用、真实 UTC 时间 |
| 真实流式 | `[LIVE-STREAM-OK]`：24 个 delta，流式文本与最终答案逐字一致（无重复、无截断） |
| junction 越权（读写） | 均被拒绝；同目录普通路径不受影响 |
| 记忆键单射（585 键暴力测试） | 0 碰撞 |
| 全新 `git clone` 后跑测试 | 324 passed（无 `.tools/` 也能跑） |

---

## 项目结构

```
agent-cl.asd              系统定义（agent-cl / agent-cl-tests）
start.ps1 / start.bat     Windows 一键启动器
src/
  core/                   工具库：util（路径/进程看门狗/宽松读文件）、json、log、error
  llm/                    传输层：codec（OpenAI 兼容编解码）、sse（流式解析）、transport（mock/http）
  messages.lisp           消息信封（role/content/tool_calls/name）
  schema/                 JSON Schema 校验 + 类型强制
  tools/                  registry（注册与调用）+ builtin（9 个内置工具）
  loop/engine.lisp        ReAct 引擎、policy、守卫、工具守卫、上下文裁剪
  dsl/                    宏表面 (macros) + meta/audit/principles/goals/graph/identity/memory/introspect/sandbox
  session/store.lisp      事件日志式会话（JSONL，O(1) 追加 + 锁）
  render/                 Markdown 行分类器（纯）+ 终端几何/转义（纯）
  web/search.lisp         web.search：Tavily/DDG + 缓存 + 预算 + 熔断
  selfimprove/engine.lisp 带门禁的单文件自我改进
scripts/                  repl / plan / smoke / run-tests / dev-http / env / 安装脚本 / node 钩子
console/                  Hunchentoot 只读控制台（server.lisp + static/index.html）
tests/                    20+ 个测试文件（含 audit-round2/3 回归）
docs/architecture.md      架构与里程碑
```

---

## 已知限制

按优先级排列，都是已复现但尚未修的问题：

1. `scripts/http-request.js`（node 回退路径）**没有请求超时**：服务端只连不答会永久挂住；且没有把 transport 的 timeout 传下去。
2. `web.search` 的熔断器是**进程级**的（一个 backend 熔断会连带拒绝另一个），且仍做短语匹配，理论上可能被回显的查询文本误触发。
3. 控制台 `/api/session` 用 decode→encode 做校验，会把 JSON `false` 变成 `null`（当前 UI 只读 `role/content/type`，暂时不可见）；
   聊天框是 mock 但气泡标签写作 "Agent-CL"、没有"不写入会话"的提示。
4. `defaudit` 的 `:check` 体只拿到 `agent`，**看不到本次调用的工具名与参数**（适配器把两者丢弃了），
   所以无法写出"按参数拦截"的规则；要按参数判断目前只能自己注册工具守卫。
5. DSL 打磨项：`defagent` 拼错选项会静默丢掉限制（如 `:max-step`）；`:tools :all` 在 DSL 里表达不出来；
   `defdsl-tool` 在宏展开期往 `*package*` intern `ARGS`/`CTX`；依赖图不区分包；
   `:preconditions` 写多个形式会被当成一次调用；两个包里同名的 guard 会合并成一条。
6. 性能小项：transcript 追加仍是 O(n)（长会话是 O(n²)）；会话追加约 5ms/事件且被一把全局锁串行化。
7. 平台小项：POSIX 的终端探测只看 `COLUMNS`/`LINES` 环境变量、不看 tty；`path-inside-p` 在 root 为盘符根时全部拒绝。
8. 零散：`agent-cl.messages:role-*` 与 `agent-cl.render:make-md-line` 被导出但未定义；
   `schema-error`/`guard-triggered` 是死条件；`shell-command` 是死代码；`***x***` 渲染会多一个 `*`；emoji 宽度按 1 计。
9. 未跟踪草稿目录（`demo/`、`agent-console/`、`demo_gui/`、`lisp-modeler/`）里也有已知问题，尚未处理：
   例如 `demo/dsl-contract-demo.lisp` 的 `(defaudit … () …)` 会让第 7 节崩溃；
   `lisp-modeler` 的 capped cylinder 顶点索引有误、`(scale m 3)` 只缩 x 轴。

---

## 环境注记（为什么与标准 CL 工程不同）

项目最初在**无管理员权限、winget 别名损坏、schannel TLS 被禁、无法下载 Quicklisp 发行版**的
Windows 沙箱中构建，因此保留了几处自适应设计（在正常联网机器上均平滑可用）：

- **依赖引导**：`scripts/*.lisp` 先探测 Quicklisp（`~/quicklisp/setup.lisp`），存在则
  `ql:quickload` 四个依赖后 `asdf:load-system :agent-cl`；无 Quicklisp 时退回 vendored `.tools/deps`
  布局（沙箱时代产物，本仓库不携带；`scripts/env.lisp` 记录了该布局的加载方式）。
- **真实 HTTP**：`src/llm/transport.lisp` 把网络调用委托给 `*http-fetch-hook*`；正常机器走
  **进程内 dexador 直连**：`scripts/dev-http.lisp` 加载 cffi/cl+ssl/dexador、强制 usocket 后端
  （绕开 Windows 默认 WinHTTP/schannel）、用 Git 自带 CA 包校验证书（Windows 需把
  `C:\Program Files\Git\mingw64\bin` 加入 PATH，`start.ps1` 自动处理）。
  dexador 对 ≥400 响应先抛可继续错误，`dev-http.lisp` 已把它转成携带服务端正文的干净
  `transport-error`（4xx 不重试、5xx/429 可重试），连接层面的瞬态失败也会分类为可重试。
- **ASDF fasl 缓存**经 `XDG_CACHE_HOME` 重定向到仓库内 `.tools/cache`（已 gitignore）。
- **有意偏离架构文档的取舍**：测试框架 doc 首选 rove → 自带 harness；日志 doc 首选 log4cl →
  `src/core/log.lisp` 分级日志；CLI/时间/uuid 未引入 clingon/local-time/uuid，用极简实现替代。

---

## 里程碑

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0 | SBCL 2.6.8 + 依赖引导 + ASDF 骨架（包 / 错误层级 / 日志 / JSON） | ✅ |
| M1 | LLM 传输层：messages 信封、OpenAI 兼容 codec、SSE 流式（工具参数按 index 分片拼接）、mock transport | ✅ |
| M2 | ReAct 引擎：schema 校验、工具注册表、内置工具、守卫、CLOS 扩展钩子 | ✅ |
| M3 | DSL 层：`defdsl-tool`/`defcommand`/`defschema`/`defpolicy`/`defguard`/`defagent` + 默认关闭的白名单沙箱 | ✅ |
| M4 | 会话事件日志（JSONL）+ 导出/载入 + 暂停/恢复 + REPL 入口 | ✅ |
| M5 | 引擎窗口/预算裁剪 + Plan-then-Execute（`/plan`） | ✅ |
| M6 | 真实 API 冒烟 + Windows 真机全量回归 | ✅ |
| M7 | 可执行契约层：`defaudit`（执行前拦截）/`defgoal`/`defprinciple`（冻结宪法）/`defidentity`/`defmemory`/`defintrospect` + 依赖图 | ✅ |
| M8 | 两轮全项目审计与加固（安全边界、门禁诚实性、wire 名匹配、测试有效性） | ✅ |

---

## 文档

- [docs/architecture.md](docs/architecture.md) —— 架构、模块职责、里程碑、真机回归与审计记录
- `docs/` 下另有若干设计草稿（`dsl-contract-demo-brief.md`、`requirements-from-shared-chat.md`、`tonight-summary.md`）

## License

Apache License 2.0 —— 见 [LICENSE](LICENSE)。
（注：`agent-cl.asd` 的 `:license` 字段目前仍写着 MIT，两者需统一，以 LICENSE 文件为准。）
