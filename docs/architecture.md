# Agent-CL 架构设计文档

- 状态：v0.4（评审 #1 决策已固化见 §0.1；M0–M6 已按本文实现并测试，增补见 §13；全真机回归记录见 §14；二次深度审查与可靠性强化见 §15）
- 语言：Common Lisp（实现：SBCL，Windows 11 / 可移植到 Unix）
- 日期：2025
- 本文回答三个问题：**做什么**（能力边界）、**怎么做**（模块与协议）、**怎么扩展**（DSL 深度定制机制）

---

## 0. 目标与验收

用 Common Lisp 从零构建一个「现代 Agent」骨架，具备：

1. **LLM 接入**：OpenAI 兼容 `chat/completions` REST 协议，支持 Function/Tool calling。**默认 DeepSeek**（决策 D1），同一 codec 以 base-url/模型配置切换 OpenAI / Ollama / LM Studio 等任意兼容端点。
2. **自主能力**：ReAct 式「思考 → 工具调用 → 观察 → 继续」循环，直至完成或触发守卫条件。
3. **内置工具集**：shell 执行、文件读写、HTTP 抓取、时钟/时间等（全部可插拔、可关闭）。
4. **会话与记忆**：多轮上下文管理、预算控制（截断/压缩）、会话持久化与恢复。
5. **流式与中断恢复**：SSE 流式输出、可中断长任务、断点续跑。
6. **结构化输出**：JSON Schema 约束 + 校验/修复回路。
7. **DSL 深度定制**（本项目特色）：
   - 用 **Lisp 宏**把领域 DSL 编译为 agent 可调用的工具；
   - 提供一套**声明式 agent 指令 DSL**（`defagent`/`defpolicy` 等）深度编排行为；
   - 扩展点以 CLOS 协议/宏钩子开放，用户无需改引擎即可定制。

### 0.1 决策记录（评审 #1）

| 编号 | 议题 | 决策 |
|---|---|---|
| D1 | 默认 LLM 端点 | 默认 **DeepSeek**（`https://api.deepseek.com/v1`，模型 `deepseek-chat`）；同一 codec 通过 `base-url`/`model` 配置切换 OpenAI / Ollama / LM Studio 等任意 OpenAI 兼容端点。测试矩阵以 DeepSeek 线格式为准，并保证兼容形态可配 |
| D2 | 模型动态生成 DSL 脚本并执行 | **v1 默认关闭**：白名单解释器等实现照常交付但默认禁用，仅显式配置（如 agent 级 `:dsl-exec :on` + 命令白名单）才开放执行路径（见 §6.5） |
| D3 | HTTP 服务入口 | **本期不做**；架构已留 orchestrator 边界，后续可加薄服务层 |
| D4 | 能力集 | ReAct 循环、内置工具、会话记忆（窗口+压缩）、流式+中断恢复、结构化输出——全部进入 v1 |
| D5 | DSL 定位 | L1 agent 指令 DSL（`defagent` 族）+ L2 领域 DSL（`defdsl-tool` 族，Lisp 宏）双层；DSL 层不依赖 loop 引擎（见 §4 依赖方向） |

**第一版验收标准（M1~M2 完成时）**：在无网络模型的 mock 后端下通过全部确定性集成测试；在真实 API 下跑通一轮「系统提示 → 用户任务 → 模型调用 ≥1 个工具 → 观察 → 给出最终答复」的完整会话，且会话可持久化后恢复、支持 `--stream` 模式。

---

## 1. 需求梳理（来自需求确认）

| 维度 | 决策 |
|---|---|
| LLM 通信 | OpenAI 兼容 REST `chat/completions` + Tool calling |
| 能力集 | ReAct 循环、内置工具、会话记忆、流式+中断恢复、结构化输出 |
| DSL 含义 | ① Lisp 宏构建的领域 DSL 工具；② 声明式 agent 指令 DSL |
| 交付节奏 | 先架构文档 → 评审 → 再环境安装与实现 |

---

## 2. 总体架构

### 2.1 组件图

```
                      ┌────────────────────────────────────────────┐
                      │                 用户入口层                   │
                      │   REPL/CLI (clingon) / 示例脚本 / (未来 HTTP) │
                      └──────────────┬─────────────────────────────┘
                                     │ 自然语言任务 / DSL 脚本
                                     ▼
┌──────────────────────────────────────────────────────────────────┐
│                       orchestrator/ 会话编排层                      │
│   SessionStore(事件日志)  MemoryMgr(窗口/压缩)   BudgetGuard         │
└───────────────┬───────────────────────────────────┬───────────────┘
                │ 上下文(消息信封)                    │ 策略/守卫/预算
                ▼                                   ▼
┌──────────────────────────────────────────────────────────────────┐
│                       loop/ ReAct 引擎 (核心状态机)                 │
│   step → llm 请求 → tool_calls? → 分派工具 → 观察 → 循环            │
│   (可中断/暂停/恢复; 每步可被策略钩子改写)                            │
└──────┬──────────────────────────────┬────────────────────────────┘
       │ OpenAI 兼容协议               │ 工具调用(JSON 参数)
       ▼                              ▼
┌────────────────────┐      ┌───────────────────────────────────────┐
│ llm/ 传输层         │      │ tools/ 工具注册表 + dsl/ 宏层          │
│ 消息编解码 · HTTP   │      │ 内置工具: shell/file/http/time         │
│ SSE 流解析 · 重试    │      │ DSL 工具: defdsl-tool(defcommand) 宏  │
│ 中止(取消令牌)       │      │ 安全求值器(沙箱) · Schema 生成          │
└─────────┬──────────┘      └───────────────────────────────────────┘
          │ HTTPS/JSON(SSE)
          ▼
  OpenAI / DeepSeek / Ollama / LM Studio ...(可配置 base-url)
```

### 2.2 一次完整轮次的时序（非流式）

```
User ──任务──▶ Orchestrator
                │ 1. 追加 user 消息, 落事件日志
                ▼
             ReAct Engine
                │ 2. MemoryMgr 裁剪/压缩历史 → 构造 messages
                ▼
             LLM Transport ──POST /chat/completions (tools=[...])──▶ Provider
                ◀── assistant(tool_calls:[call_1]) + finish=tool_calls
                │ 3. 校验参数 JSON, 查注册表
                ▼
             Tool Dispatch ──(name, args)──▶ 对应工具函数/DSL 求值器
                ◀── 结果: ok | error(code,message)
                │ 4. 追加 tool 消息(含 tool_call_id), 再次请求模型
                ▼
             LLM Transport ──▶ assistant(最终答复) + finish=stop
                │ 5. 追加 assistant 消息; 引擎判定 done
                ▼
             Orchestrator ──最终答复──▶ User
```

> 引擎层不关心「模型是哪一家」：传输层把统一的消息信封映射到各家线格式，工具层把 JSON Schema 映射到 Lisp 可调用对象。这是可移植性的核心。

---

## 3. 技术选型

| 关注点 | 首选 | 备选 | 理由 |
|---|---|---|---|
| HTTP 客户端 | **Dexador** | Drakma / cl-async | 支持流式响应体回调、超时、TLS；线程内同步 API 简单，易于配合读线程做 SSE |
| JSON 编解码 | **yason** | jsown / cl-json / json-mop | 快、依赖少、可流式解析；上层封装 plist↔string 适配层 |
| 正则/字符串 | **cl-ppcre** + split-sequence | — | 工具参数解析、SSE 分帧、脚本清洗 |
| 编码 | **babel**（UTF-8） | — | 中文内容与 JSON 的字节处理 |
| 并发 | **bordeaux-threads** + 自制 mailbox | chanl / lparallel | 只依赖线程原语；mailbox ~60 行自实现，行为可控 |
| 时间 | **local-time** | get-universal-time | 日志、会话时间戳、工具 time 需要时区 |
| 日志 | **log4cl** | 自制 | 异步可见、分级、模块命名空间 |
| 测试 | **rove** | fiveam / parachute | 现代、并行、ASDF 集成好；mock 传输层做确定性测试 |
| 命令行 | **clingon** | unix-opts | REPL/CLI 两用；参数化 base-url/model/key |
| 构建 | **ASDF + uiop** | — | 系统定义、路径、进程调用（shell 工具依赖 uiop:run-program） |
| 标识符 | **uuid** | — | 会话 ID、tool_call_id 本地生成兜底 |

依赖总量控制在 **10 个以内**，全部来自 Quicklisp。

**平台注意（Windows）**：SBCL on Windows 无 Unix 式 SIGINT；中断统一采用「协作式取消令牌 + 条件对象」（见 §5.8），不做硬性线程杀除，保证跨平台一致。

---

## 4. 目录结构与模块划分

```
agent-cl/
├── README.md
├── docs/
│   └── architecture.md        ← 本文档
├── agent-cl.asd               # ASDF 系统定义（包: agent-cl, 依赖: 见 §3）
├── src/
│   ├── packages.lisp          # 包定义与符号导出（agent-cl.* 多个包）
│   ├── core/
│   │   ├── util.lisp          # plist/哈希工具、字节/字符计数、剪裁
│   │   └── error.lisp         # 条件层级: agent-error → transport/tool/dsl/guard…
│   ├── llm/
│   │   ├── transport.lisp     # 协议: *base-url* *api-key* *model*; POST 封装
│   │   ├── codec.lisp         # 消息信封 ↔ OpenAI 线格式; yason 适配
│   │   ├── sse.lisp           # SSE 解析器（data: 行分帧、JSON 增量累积）
│   │   └── streaming.lisp     # 流式完成对象: 增量/工具调用增量/usage
│   ├── schema/
│   │   ├── json-schema.lisp   # 内部 Schema 表示 → LLM-facing JSON Schema
│   │   └── validate.lisp      # 对模型返回/工具返回的 JSON 校验与规范化
│   ├── messages.lisp          # 消息信封类型: system/user/assistant/tool + tool_calls
│   ├── loop/
│   │   ├── engine.lisp        # ReAct 状态机与步进
│   │   ├── policy.lisp        # 策略(温度/并行工具/工具选择)与守卫(步数/时长/预算)
│   │   └── hooks.lisp         # CLOS 协议方法（扩展点，见 §6.4）
│   ├── tools/
│   │   ├── registry.lisp      # 工具注册表: name → 描述+schema+函数
│   │   ├── builtin/
│   │   │   ├── shell.lisp     # shell.run（白名单/确认开关）
│   │   │   ├── files.lisp     # file.read/write/list
│   │   │   ├── web.lisp       # web.fetch / url 抓取
│   │   │   └── time.lisp      # time.now / datetime
│   │   └── protocol.lisp      # tool 函数约定: (args-plist &key ctx) → result
│   ├── dsl/
│   │   ├── defdsl-tool.lisp   # 宏: defdsl-tool / defcommand
│   │   ├── defagent.lisp      # 宏: defagent / defpolicy / defguard
│   │   ├── sandbox.lisp       # 安全求值: 白名单解释器 + 子进程沙箱
│   │   └── schema-gen.lisp    # DSL 声明 → JSON Schema（供 LLM 与校验共用）
│   ├── memory/
│   │   ├── budget.lisp        # 上下文预算: 字符/token 估算、窗口滑动
│   │   └── compact.lisp       # 压缩: 摘要旧历史（可插拔策略）
│   ├── session/
│   │   ├── store.lisp         # 会话事件日志(JSONL): 追加/回放/恢复
│   │   └── entry.lisp         # 程序入口: repl / cli 驱动
│   └── agent.lisp             # 顶层 API: make-agent / run / ask / interrupt / resume
├── tests/                     # rove: codec/sse/loop-dsl/session 各一套
├── examples/                  # 示例: defagent + 领域 DSL（见 §6）
└── scripts/                   # install 脚本（SBCL+Quicklisp）、mock 服务器
```

**依赖方向**（禁止反向）：`core ← {schema, messages} ← {llm, tools, dsl} ← loop ← {memory, session} ← agent`。DSL 宏层只依赖 schema/tools，不依赖 loop——因此领域 DSL 可以脱离「智能体」独立使用，这是刻意的解耦。

---

## 5. 核心设计

### 5.1 消息信封与消息模型

统一内部模型（不直接暴露 yason 哈希表）：

```lisp
(defclass message ()
  ((role     :initarg :role)            ; :system | :user | :assistant | :tool
   (content  :initarg :content)         ; string
   (tool-calls :initarg :tool-calls :initform nil) ; assistant 侧
   (tool-call-id :initarg :tool-call-id :initform nil) ; tool 侧回执
   (name     :initarg :name :initform nil)
   (meta     :initarg :meta :initform nil))) ; usage/时间戳等, 不入请求
```

- `content` 统一为字符串（不引入多模态数组，M0 简化；接口层预留）。
- 序列化：`encode-message`/`decode-message` 双函数做 OpenAI 映射，任何兼容端点差异只改这里（如某些端点不需要 `name`）。

### 5.2 LLM 传输层

- 可配置项（环境变量/`defagent` 覆盖，决策 D1）：`*llm-base-url*` **默认 https://api.deepseek.com/v1**（OpenAI 官方 https://api.openai.com/v1、本地 Ollama/LM Studio http://localhost:11434/v1 等经配置切换）、`*llm-api-key*`、`*llm-model*`（默认 `deepseek-chat`）、`*timeout*`、`*max-retries*`。
- 请求：`chat-completion (params &key stream)` 组装 JSON → Dexador POST → 按 `stream` 分派非流式/流式。
- 重试策略：429 与 5xx 指数退避 + 抖动；网络错误可重试；4xx 无效请求直接抛 `transport-error`（不浪费预算）。
- **错误语义**：传输错误 → 条件对象，携带阶段信息与可恢复标志；引擎捕获后决定终止还是用「工具错误消息」喂回模型。

### 5.3 流式（SSE）与中断

- `sse.lisp`：按行读取，识别 `data:` 前缀，空行分帧；`[DONE]` 结束。
- `streaming.lisp` 累积增量（`choices[0].delta`）：普通文本直接 append；`tool_calls` 增量**按 index 键控**（`arguments` 是分片 JSON 字符串，必须逐片拼接后整体解析）：

```lisp
(defclass tool-call-accum ()
  ((index :initarg :index)
   (id    :initarg :id :initform nil)
   (name  :initarg :name :initform nil)
   (arguments :initform (make-string-output-stream))))
```

- 流式下同样支持 tool calling：模型边生成参数边推送，`finish_reason=tool_calls` 后整段参数再校验。
- 终止条件：`stream_options.include_usage` 收 usage（token 记账）；请求 `:stream nil` 时从响应体取 usage。

### 5.4 ReAct 引擎与守卫

状态机（每状态均为事件日志中的一个可回放事件）：

```
idle ──start(task)──▶ thinking ──llm ok──▶ waiting_tool │ finish=stop ──▶ answering ──▶ done
   ▲                      │  finish=tool_calls          │ 参数合法
   └──────resume──────────┘                              ▼
                         ◀── observe(tool 结果) ◀── tool_running
                                │ finish=stop/出错
                                ▼
                             answering / failed
```

引擎 API（顶层 `agent.lisp` 对外）：

```lisp
(defclass agent () (model transport tools policy guards memory session ...))

(run agent task &key stream)          ; 完整执行到 done
(ask agent text)                      ; 单轮便捷入口(内部还是完整循环)
(interrupt agent)                     ; 协作式中断
(resume agent)                        ; 从事件日志恢复
```

**守卫（防失控）**——按序检查，命中即停并给出可读原因：
1. `:max-steps`（默认 20）——LLM 往返 + 工具执行轮数；
2. `:max-duration` / `:deadline`（挂钟时间）；
3. `:max-tokens` / `:budget-usd`（usage 记账，流式也要增量记）；
4. `:danger-ratio`——高危工具（shell 等）连续失败次数上限。

命中守卫抛出 `guard-triggered` 条件，携带已完成对话；上层可选择把该条件作为一条 tool 错误消息喂回模型让其收敛（可配置）。

**工具参数校验**：模型返回的 `arguments` JSON → plist，用 schema 校验器检查类型/必填，非法时把**校验错误**作为 tool 结果回给模型（而非直接失败），让模型自纠——这是 tool calling 健壮性的关键。

### 5.5 中断与恢复（事件溯源）

- 会话是**只追加事件日志**（JSONL，`session/store.lisp`）：每条记录 `{seq, type: user|assistant|tool-call|tool-result|guard|checkpoint, payload}`。
- `interrupt`：设置取消令牌 → 引擎在每个「等待点」（LLM 请求前、工具调用前）检查 → 抛 `agent-pause` → unwind-protect 把当前任务与半成品状态写为 `checkpoint` 事件。
- `resume`：读日志 → 重放消息序列还原上下文 → 从 checkpoint 继续。**同一会话可多次暂停/恢复**，天然支持长任务与审计。

### 5.6 结构化输出

双层策略：

1. **原生**：`response_format: {type:"json_schema", json_schema:{...}}`（模型支持时）。我们的 schema 声明同时驱动「请求格式」与「本地校验」。
2. **兜底修复**：模型返回文本 → 本地解析/校验失败 → 把解析错误作为新 user 消息回喂（`repair` 循环，≤N 次）。

本地 Schema 宏（与 §6 DSL 共用同一套描述）：

```lisp
(defschema invoice
  (:object (invoice-no :string :required t)
           (amount      :number :required t)
           (items       (:array :object) :required t)))
```

展开为：① LLM-facing JSON Schema 字符串；② `validate-json` 校验器；③ 可选 CLOS 类/结构体定义——**同一份声明，三个产出**。

### 5.7 记忆与上下文预算

- **token 估算**：请求前按字符启发式（CJK≈每字 1~1.5 token，ASCII≈4 字符/token）估算，并优先用流式返回的 `usage` 校正；长期目标是接入各家 `tokenizer`，但避免引入重量级依赖（MVP 启发式足够）。
- **预算策略**：`system`（固定）+ 最近窗口（`:history-window` 条）+ 压缩摘要（`:compact-threshold` 触发）：
  - 超预算 → 先把最旧的非工具消息压缩为一条摘要（调用模型 `summarize`，同模型即可）；
  - tool 结果过长 → 截断 + 提示（`:truncate-char`，如 8000 字）并注明「已截断」。
- **长期记忆**：定义为协议（`store-event`/`recall`），MVP 提供内存实现；向量库/RAG 留作 Phase-2 插件，不阻塞主线（记忆需求确认中未要求检索，先做会话内）。

### 5.8 并发与可取消性

- 每 Agent 一个 mailbox + 工作线程（或调用方线程直接驱动，CLI/REPL 下同步即可）。
- 取消令牌：`(defclass cancel-token () ((flag :initform nil) (lock :initform (bt:make-lock))))`，`cancel-p` 在**协作点**检查。LLM 请求在独立读线程，取消 = 关闭 socket → 读线程抛 `stream-aborted` → 干净回收（`unwind-protect` 关连接），不做 `interrupt-thread` 硬切（Windows 不可靠）。
- 工具执行设 `:timeout`（如 shell 30s），超时杀子进程（uiop 支持）+ 返回超时错误消息。

### 5.9 安全

| 风险 | 对策 |
|---|---|
| shell/file 工具被滥用 | 默认 `:dangerous t` 才启用；`shell.allow` 前缀白名单与 `*confirm-dangerous-tools*`；示例配置默认关 |
| 模型返回恶意/幻觉 JSON | schema 严格校验；只按注册表名字分派，不 eval 任意函数 |
| 用户 DSL 脚本不可信 | §6.5 沙箱双模式 |
| API key 泄露 | 只从环境变量读；日志脱敏（不打印 Authorization） |
| Prompt 注入（网页内容等） | `web.fetch` 结果标记为「外部内容」包裹引用，作为 user 消息且注明不可信来源（MVP 层防御 + 文档说明） |

---

## 6. DSL 深度定制设计（项目特色，重点）

CL 的**同像性**（代码即数据）使 DSL 不必单独发明解析器：DSL 就是 Lisp 宏 + 数据结构，天然可读、可生成、可校验、可组合。设计分三层：

```
 L0 宿主语言层    Common Lisp + 宏（用户可完全掌控）
 L1 指令 DSL       defagent / defpolicy / defguard / defschema   ← 编排 agent 行为
 L2 领域 DSL        defdsl-tool / defcommand + 领域包            ← 成为 agent 的工具
 L3 运行时求值     沙箱解释器 / 子进程，执行 L1/L2 产出的脚本/表达式
```

### 6.1 工具协议（L2 的落点）

工具 = 注册表条目 `{name, description, schema, fn}`，fn 约定：

```lisp
(defun my-fn (args-plist ctx)
  ;; args-plist: 已按 schema 校验的 plist; ctx: 当前 agent/会话环境
  (values result-plist-or-string status-code))
```

返回值统一 `(values payload kind)`，kind ∈ `:ok | :error(code) | :truncated`，引擎负责映射成 tool 消息。

### 6.2 领域 DSL 宏：`defdsl-tool` / `defcommand`

声明式地定义一个「DSL 工具」，宏负责：生成 schema（喂 LLM）+ 生成参数解构 + 注册 + 从 docstring 生成说明书。示例（日历 DSL）：

```lisp
(defdsl-tool calendar.book
  "在日历中创建事件。"
  ((date     :string :required t :doc "ISO 日期, 如 2025-06-01")
   (start    :string :required t :doc "HH:MM 24小时制")
   (end      :string :doc "HH:MM, 默认1小时")
   (title    :string :required t :doc "标题")
   (notify?  :boolean :doc "提前10分钟提醒"))
  (lambda (a ctx) (calendar-api:create (getf a :date) ...)))
```

而**深度定制**体现在：DSL 不必是扁平的「单函数工具」——用户可以用宏构造**复合 DSL**：多个 defcommand 共享一个领域包与状态；或用子宏定义「命令族」：

```lisp
(defdsl-package :calendar            ; 生成 calendar.* 命名空间工具族
  (:summary "日历操作：查询、创建、取消")
  (:state  (db :init (open-calendar-db))))
```

宏展开期自动为每个命令生成 OpenAI 侧 tool 条目（`name="calendar.book"`，description 取 docstring），LLM 看到的说明书与 Lisp 代码**同源**，永不漂移。

### 6.3 Agent 指令 DSL（L1）

用户用一个 Lisp 表单描述「一个 agent 长什么样、能干什么、边界在哪」，宏在编译期把它编译成 `agent` 实例构造代码并做静态检查：

```lisp
(defagent my-bot
  (:model "deepseek-chat" :base-url (env "DEEPSEEK_BASE")
          :temperature 0.3 :max-tokens 4096)
  (:system "你是 {persona}。回答用中文，需要动手时使用工具。")
  (:persona "资深 CL 工程师助手")
  (:memory :window 20 :compactor :summary :compact-at 0.8)
  (:tools shell file web time            ; 内置
          calendar.book                  ; 领域 DSL 工具族
          :exclude (file.write))         ; 按名排除
  (:guard :max-steps 25 :danger-ratio 3 :budget-usd 0.5)
  (:policy :parallel-tools t :tool-choice :auto))
```

配套宏：
- `defpolicy`——具名策略对象（供多 agent 复用）：并行工具开关、失败重试次数、工具结果截断长度、是否允许模型自纠等；
- `defguard`——新增守卫：编译成检查函数 + 可读消息；
- `defschema`——结构化输出的共享 schema 命名（§5.6）。

### 6.4 扩展点：CLOS 协议钩子（不改引擎即定制）

引擎把每个「关键时刻」开放为 CLOS 泛函，默认实现是平凡行为，用户用 `:before/:after/:around` 或 eql 特化叠加行为。示例（含 DSL 化的守卫与记忆策略）：

```lisp
(defmethod on-step-start ((a my-bot) step-ctx) ...)      ; 每步前
(defmethod on-tool-result ((a my-bot) tool-name result)  ; 工具返回后改写
  (if (and (eq tool-name 'calendar.book) (slot-value result 'conflict))
      (propose-alternatives a result) result))
(defmethod choose-compactor ((a my-bot)) (my-summarizer)) ; 记忆压缩策略
```

> 这样用户新增的是**策略/领域行为**，而引擎的步进、重试、预算、事件溯源是平台代码——职责边界清晰，也便于测试。

### 6.5 安全求值：让 agent 执行「用户 DSL 脚本」

「深度定制」还包括让 agent 动态执行 DSL 表达式（例如模型生成一段 DSL 脚本再执行）。**该能力 v1 默认关闭（决策 D2）**：实现随 v1 交付但执行路径默认禁用，仅当显式配置（agent 级 `:dsl-exec :on` 并给出命令白名单）时开放。启用后的执行分两种沙箱模式，由 `*dsl-execution-mode*` 选择：

1. **受限解释器（in-image）**：不调用 `eval`，而是走一个白名单 AST 遍历器：
   - 只接受受限语法（原子/列表/少量特殊形式）；
   - 符号白名单（如 `+ - * /`、领域命令、纯函数），黑名单包含 `eval/apply/read/shell` 等一切可达宿主 I/O 的符号；
   - 步骤数与结果长度上限；
   - 实现要点：解析用 `read` 加 `*read-eval*` 关闭 + 结果自校验，**绝不 eval 完整表单**。
2. **子进程沙箱（默认对 shell/未知脚本强制）**：把脚本写入临时文件 → `uiop:run-program` 于受限子进程（Unix 可用 `setrlimit`/`chroot` 或容器；Windows MVP 用独立低权限进程 + 超时）→ 只回收 stdout/退出码。

任何模式都遵循：**默认拒绝、显式放行、全程记账、超时即杀**。第一版把「不安全」定义为明确列表，文档化扩展方法。

### 6.6 DSL 与 LLM 的桥：说明书与 Schema 自动生成

`dsl/schema-gen.lisp` 保证三处信息永远同源：
1. 工具注册表条目（Lisp 侧可调用对象）；
2. 请求体里的 `tools:[{type:function,function:{name,description,parameters}}]`（LLM 侧）；
3. 校验器与文档。

编译期宏把 `:doc`/`:param` 声明展开成上述三份产出，运行期零推导开销。这样「改 DSL 声明 = 改模型可见行为」，深度定制不靠 prompt 手写，而是**声明即生效**。

---

## 7. 会话持久化与运行入口

- 会话目录 `~/.agent-cl/sessions/<id>/events.jsonl`；`session-id` 默认 uuid，可指定继续已有会话（`agent resume --session <id>`）。
- 运行入口：
  - `scripts/mock-server.lisp`：可脚本化的 mock provider（回放固定应答序列），**让全部集成测试无需 API key、完全确定性**；
  - REPL 驱动（SLY/命令行）：交互式多轮；
  - CLI（clingon）：`agent-cl ask "…" [--model] [--stream] [--session] [--tool …]`。
- 事件日志同时服务：审计（谁调了什么工具/花了多少 token）、调试回放、断点续跑、测试夹具。

---

## 8. 错误处理、重试与可观测性

**条件层级**（`core/error.lisp`）：

```
agent-error
├── transport-error (retryable? / status / phase)
├── tool-error      (tool / code / message)
├── dsl-error       (parse / validate / sandbox-denied / step-limit)
├── schema-error    (path / expected / actual)
└── guard-triggered (rule / limit / usage-so-far)
```

**约定**：LLM 层可重试（自动退避）；工具失败不重试整个回合，而是把错误作为观察回喂模型；守卫/沙箱拒绝不可重试，终止并给出原因。日志经 log4cl 分级：每个 LLM 请求/工具调用各一条带 id 的上下文日志。

**可观测性指标**（第一版输出到日志与事件）：步数、延迟、usage 增量、工具调用次数/失败率、预算消耗、压缩触发次数。

---

## 9. 项目结构落地与工具链

- `agent-cl.asd` 声明 `agent-cl` 主系统 + `agent-cl/tests`；依赖见 §3 表，全部 Quicklisp 可得。
- 包划分：`agent-cl.core` `agent-cl.llm` `agent-cl.schema` `agent-cl.loop` `agent-cl.tools` `agent-cl.tools.builtin` `agent-cl.dsl` `agent-cl.memory` `agent-cl.session` `agent-cl`（用户可见 API，仅导出 defagent/defdsl-tool/run/ask/resume 等稳定符号）。
- 开发流：SBCL + Quicklisp → SLY 连接 → `(ql:quickload :agent-cl)` → rove 跑测试。

---

## 10. 里程碑与验收

| 里程碑 | 内容 | 验收 |
|---|---|---|
| M0 环境 | 装 SBCL+Quicklisp，ASDF 骨架，包/错误层级/日志，ci 脚本 | `(asdf:load-system :agent-cl)` 零错 |
| M1 传输 | codec/sse/streaming/非流式+流式、重试；**mock provider** 测试 | mock 下编码往返、分片参数拼接、中止路径全绿 |
| M2 引擎 | 消息信封、ReAct 循环、工具注册表、内置工具、守卫、schema 校验修复 | mock 跑通 2 轮工具调用场景；schema 非法输入能自纠 |
| M3 DSL | defdsl-tool/defcommand/defdsl-package、defagent/defpolicy/defguard、schema-gen、白名单解释器（实现但默认禁用，`:dsl-exec` 显式放行） | 示例领域 DSL 被模型正确调用；危险符号被拒；默认配置下动态执行不可用 |
| M4 会话 | 事件日志、interrupt/resume、CLI/REPL、usage 记账与预算 | 中断→恢复等价于连续执行（确定性测试） |
| M5 记忆 | 窗口/压缩策略、压缩可插拔协议 | 超长会话不超预算且保真摘要 |
| M6 打磨 | 真 API 冒烟、文档、examples 全绿、Windows/Unix 双平台验证 | 真实 DeepSeek/OpenAI 端到端 1 轮 |

**测试策略**：传输与循环测试一律走 mock（不耗真实 token）；仅 `examples/` 冒烟与 M6 允许真实 API；SSE 用录制的真实响应片段作夹具。

---

## 11. 风险与开放问题

| 风险/问题 | 影响 | 对策/状态 |
|---|---|---|
| 各家 tool-calling 方言差异 | 高 | 端点差异收敛到 codec；默认以 DeepSeek（OpenAI 兼容）为准，Ollama 工具支持程度在 M1 用真端点验证（D1） |
| Windows 下流式读取线程取消 | 中 | 关闭 socket + 读线程抛错回收；无信号依赖（§5.8） |
| token 估算不准 | 低 | 启发式 + usage 校正；压缩阈值留裕量 |
| 模型把 DSL 脚本当任意代码执行 | 高 | v1 动态执行默认关闭（D2）；开放时沙箱默认拒绝 + 白名单 + 文档化放行路径（§6.5） |
| 长记忆（向量检索）是否需要 | — | 已决策：本期仅会话内记忆（D4），外部存储协议预留，确认后加插件 |
| HTTP 服务入口 | — | 已决策：本期不做（D3），架构已留 orchestrator 边界 |
| 内置 web 搜索是否需要专用搜索 API（vs 纯抓取） | — | 默认 `web.fetch`；`web.search` 作为后续插件，不影响主线 |

**已定案（评审 #1）**：端点默认与可配置性（D1）、DSL 动态执行默认关闭（D2）、本期无 HTTP 入口（D3）、能力集范围（D4）、DSL 双层定位（D5）——详见 §0.1 决策记录。剩余开放项仅「向量检索记忆引入时机」「专用搜索 API」两件，均不阻塞 M0~M3 主线。

---

## 12. 附录：线格式示例

### 12.1 请求（带 tools，非流式）

```json
{
  "model": "deepseek-chat",
  "messages": [
    {"role": "system", "content": "你是资深 CL 工程师助手……"},
    {"role": "user",   "content": "把当前目录列表写到 notes.md"}
  ],
  "tools": [{
    "type": "function",
    "function": {
      "name": "shell.run",
      "description": "执行一条 shell 命令并返回 stdout/stderr。危险操作需谨慎。",
      "parameters": {
        "type": "object",
        "properties": {"cmd": {"type": "string", "description": "要执行的命令"}},
        "required": ["cmd"]
      }
    }
  }],
  "tool_choice": "auto",
  "temperature": 0.3
}
```

### 12.2 响应（assistant 请求调用工具）

```json
{
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": null,
      "tool_calls": [{
        "id": "call_abc123",
        "type": "function",
        "function": {"name": "shell.run", "arguments": "{\"cmd\":\"ls -la\"}"}
      }]
    },
    "finish_reason": "tool_calls"
  }],
  "usage": {"prompt_tokens": 210, "completion_tokens": 18, "total_tokens": 228}
}
```

### 12.3 工具结果回执（下一轮请求追加）

```json
{"role": "tool", "tool_call_id": "call_abc123", "content": "drwxr-xr-x ..."}
```

### 12.4 流式分片（SSE，工具参数被拆散推送）

```
data: {"choices":[{"index":0,"delta":{"role":"assistant","content":null}}]}

data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_abc123","type":"function","function":{"name":"shell.run","arguments":""}}]}}]}

data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"cmd\":"}}]}}]}

data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"ls -la\"}"}}]},"finish_reason":"tool_calls"}]}

data: [DONE]
```

> 解析器必须按 `tool_calls[].index` 拼接 `arguments` 分片（见 §5.3 `tool-call-accum`）。

---

*本文档随评审意见修订；实现阶段以本文为准，冲突时以「模块依赖方向 + 协议定义」为最高约束。*


---

## 13. 实现状态与取舍记录（实现期增补）

### 13.1 进度对照

| 里程碑 | 本文范围 | 实现状态（Windows 本机） |
|---|---|---|
| M0 | SBCL + ASDF 骨架 | ✅ 2.6.8 离线引导；包/错误层级/日志/JSON；测试 harness |
| M1 | 传输层 codec/SSE/流式 + mock | ✅ `src/messages.lisp`、`src/llm/*`；确定性测试全绿 |
| M2 | 引擎/工具/守卫/schema | ✅ `src/loop/engine.lisp`、`src/tools/*`、`src/schema/*` |
| M3 | DSL 宏层 + 沙箱 | ✅ `src/dsl/*`；白名单解释器默认 :off（决策 D2） |
| M4 | 会话/中断/CLI | ✅ `src/session/store.lisp`（JSONL 事件日志、暂停/恢复语义）、`scripts/repl.lisp` |
| M5 | 记忆预算 | ✅ 窗口（max-history）+ Token 预算（context-budget）+ `before-llm-call`/`choose-messages` 钩子接线 |
| M6 | 真 API 冒烟/双平台 | ✅ DeepSeek 端到端冒烟（沙箱内经 node/OpenSSL 传输钩子 `scripts/http-request.js` + `scripts/smoke.lisp`）；双平台待办 |

测试：`.\start.ps1 -Mode test`（等价 `scripts/run-tests.lisp`）跑 66 个用例全部通过（全部 mock 确定性，零真实 API 消耗）；真机回归实录见 §14；二次深度代码审查与修复记录见 §15。

### 13.2 与原文档的取舍（均为离线沙箱驱动的工程适配，均有注释标记）

| 本文方案 | 实际 | 影响与回切 |
|---|---|---|
| rove | `tests/harness.lisp` 自带 ~90 行（宏兼容 deftest/ok/is-equal/signals-error） | 联网后可整文件替换为 rove，调用点不变 |
| log4cl | `src/core/log.lisp` 自带分级日志 | 接口固定，可换 log4cl |
| dexador HTTP | `llm/transport.lisp` 的 `*http-fetch-hook*` 注入点 + `make-http-transport`；沙箱内经 `scripts/dev-http.lisp` 实现**进程内 dexador+cl+ssl 直连**（usocket 后端 + Git CA 包），`scripts/smoke.lisp` 冒烟通过 | 已落地（M6） |
| clingon/local-time/uuid | 极简自实现 | CLI 目前仅 REPL 脚本 |
| Quicklisp | `.tools/deps` vendored + ASDF `(:tree …)` | 见 README「环境注记」 |

### 13.3 已知边界

- Windows 沙箱无 schannel 凭据、无管理员、winget 别名不可用 → 离线工具链（详见 README）；
- `defguard` 等"运行期策略"走 CLOS 钩子，改行为=子类/覆写方法，不触碰引擎；
- 真实模型行为（工具选择质量、schema 生成）只能由 M6 冒烟验证，本仓库测试负责的是协议与确定性语义。

---

## 14. 全真机回归记录（Windows 11 实机，DeepSeek API）

> 时间：2026-09-06（本机 UTC+8，服务端 UTC 时间戳写入见下）。环境：SBCL 2.6.8（`C:\Program Files\Steel Bank Common Lisp`）、Quicklisp `C:\Users\bings\quicklisp`、Git mingw64（供 OpenSSL DLL 与 CA bundle）、网络为真实互联网（DeepSeek API 可达）。API key 仅经环境变量 `AGENT_CL_API_KEY` 注入，不落盘不入库。

### 14.1 回归矩阵

| # | 项目 | 入口 | 结果 |
|---|---|---|---|
| 1 | 离线确定性测试（55 例） | `.\start.ps1 -Mode test` | ✅ `55 passed, 0 failed`（全部 mock 传输，零 API 消耗） |
| 2 | 真实 API 冒烟 | `.\start.ps1 -Mode smoke` | ✅ `[SMOKE-OK]` done=T steps=2 tools=1（time.now → 回答，roles=user/assistant/tool/assistant，usage total=744） |
| 3 | task.delegate 委派（省 token 子会话） | `.tools/regression.lisp` 用例 A | ✅ done=T steps=2 msgs=4；父 agent 只看到子 agent 结论：**6! = 720**（子 agent 经 code.exec/Python 计算） |
| 4 | Plan-then-Execute（/plan） | `.tools/regression.lisp` 用例 B | ✅ 规划出 3 步并逐一执行：① time.now 查 UTC ② file.write 写入 `.tools/regression-time.txt` ③ 汇报。落盘内容 `2026-09-06T16:23:00Z`（20 字节），文件实存验证 |

### 14.2 回归实录（节选）

**Plan 用例（#4）**——规划器输出、逐步执行、总结汇报：

```
[plan] 规划步骤...
[plan] 步骤: 查询当前 UTC 时间（time.now）。 | 将查询到的 UTC 时间写入文件
       C:/Users/bings/Documents/agent-cl/.tools/regression-time.txt（file.write）。
       | 汇报执行结果（一句话说明完成情况）。
[plan] 执行 1/3 查询当前 UTC 时间（time.now）。
[plan] 执行 2/3 将查询到的 UTC 时间写入文件 …/regression-time.txt（file.write）。
[plan] 执行 3/3 汇报执行结果（一句话说明完成情况）。
已查询当前UTC时间（2026-09-06T16:23:00Z）并成功写入指定文件，共写入20字节，任务完成。
[R] plan-out exists=…/regression-time.txt content="2026-09-06T16:23:00Z"
```

**Delegate 用例（#3）**——父 agent 把任务委派给独立子会话，只回收结论：

```
[R] delegate done=T steps=2 msgs=4 final=… 6 的阶乘 = 720
（子 agent 用 Python 代码执行了阶乘计算，返回结果为 720。）
```

### 14.3 回归中发现并修复的问题

- `scripts/plan.lisp` 括号失配（累计 −2，`run-step` 处多闭两个括号导致 `end of file` 读取错误）→ 从 `(defun run-step …)` 起整体重写尾部（`run-step`/`step-exec`/`run-planned` 三段，hand-verified 配平）。修复后用 SBCL 直接加载验证：`PLAN-LOADED`，`run-planned`/`step-exec`/`run-step` 三函数均 `fbound`，随后 #4 用例全绿。
- 回归脚本直启 `sbcl.exe` 时若 PATH 缺 `C:\Program Files\Git\mingw64\bin`，`cl+ssl` 报 `Unable to load libcrypto-3-x64.dll` → TLS 钩子未装、全部真实调用失败。`start.ps1` 已自动处理该 PATH；`.tools/regression.lisp` 手动跑时须先补 PATH（本次 #2–#4 均在补 PATH 后通过）。

### 14.4 本机边界（回归环境注记）

- `web.search`（DuckDuckGo HTML 端点）在**本网络环境**下超时（`USOCKET:TIMEOUT-ERROR`）——网络对 wikipedia/duckduckgo 不可达；工具注册、参数校验、错误路径的确定性测试通过，真实检索需换可达网络再验；
- 真实 API 只经**进程内 dexador+cl+ssl 直连钩子**（`scripts/dev-http.lisp`），不使用系统 WinHTTP；
- stdin 重定向读 UTF-8 会被 Windows 按 ANSI(GBK) 解码 → REPL 交互请用真实控制台；
- Markdown 着色需 VT 终端（`/color on`；`NO_COLOR` 可关）；
- `.sbclrc` 含 Quicklisp 引导行（安装脚本写入）。

---

## 15. 二次代码审查与可靠性强化（2026-09-07）

三路并行只读审查（引擎/LLM 传输层、scripts/ 运行时、工具+会话+DSL 层）后修复，全部 66 mock 用例 + 真实 smoke 通过。

### 15.1 引擎与传输层

| 严重度 | 修复 |
|---|---|
| 高 | `run` 串行工具模式此前把**全部** tool_calls 写入 assistant 消息却只执行第一个 → 悬挂 tool_call id，下轮请求非法（400）。改为只记录实际执行者（`let*` 修正了原 `let` 平行绑定的 unbound bug） |
| 高 | `dispatch-tool-call` 对畸形 arguments JSON（截断流/模型幻觉）直接崩溃整个 run → 捕获并作为工具错误反馈，transcript 保持一致 |
| 中 | 流式 EOF 未收到 `[DONE]` 且无 finish_reason 被当成功 → 静默截断；现在抛 `transport-error`（可重试） |
| 中 | 非流式 2xx 空 choices 被当空答案成功 → 显式报错 |
| 中 | **重试机制落地**：`call-model` 对 5xx/429（`transport-error-retryable-p`）指数退避重试，次数受 `agent-cl.llm:*max-retries*` 且受 policy `allow-model-retry` 门控；mock transport 新增 `script-error` 场景（3 个新测试覆盖重试成功/耗尽/关闭） |

### 15.2 消息裁剪与校验（易致 400 的静默缺陷）

- 引擎 `choose-messages` 此前按单消息/纯 token 切窗，会**拆散 assistant(tool_calls) 与其 tool 结果对**或以孤立 `:tool` 消息开头 → provider 拒绝。现按完整用户回合（turn chunk）裁剪，预算裁剪至少保留 1 个完整回合（宁超不拆）。（REPL `maybe-compact` 的同类边界净化同批完成，该 REPL 摘要压缩已于 2026-09-07 整体移除，见 §15.5。）
- `json-schema` `prop-key`/`find-prop` 未按 core/json 的 snake→kebab 规则规范化键名：带下划线属性（`max_steps`、`max_results`…）必填恒误报、类型校验被静默跳过。统一为 `norm-property-key`。
- `validate-value`/`validate-object` 的嵌套校验结果被**丢弃**（push 只作用于形参、返回值未接）→ 属性类型校验从未真正生效。`setf` 接收返回值后修复。
- `:integer` 校验现在容忍整数值浮点（模型常发 `3.0`）。
- `defschema` `:array` 的 items 声明把元素名混进 spec → 元素类型静默变 `:string`；`(cdr (decl->prop …))` 修复。

### 15.3 沙箱与工具安全

- DSL 沙箱 `allowed-symbol-p` 曾有"任意 fbound CL 函数"兜底放行（sleep/read-line/print/symbol-value/directory 均可达），与白名单承诺矛盾 → 白名单成为唯一闸门；新增逃逸面回归测试。
- **进程超时看门狗**：实测 Windows 上 `uiop:run-program :timeout 3` 对 30s 命令要跑 34s 才返回（超时失效）→ 新增 `run-program-with-timeout`：异步启动、轮询、超时杀进程树（taskkill /F /T；Unix SIGKILL），`shell.run`/`code.exec` 接入（2 个超时测试）。
- **file 工作区约束**：`file.read`/`file.write` 默认限制在仓库根（`*file-workspace-root*`，`set-file-workspace-root` 可改/设 nil 放开）；`file.write` 标记 dangerous。注册同 wire 名（如 `a.b`/`a_b`）冲突时告警。
- memory.set 键名改为**可逆编码**存储文件名（`a-b`/`a b`/`a/b` 此前全塌缩为 `a_b.json` 互相覆盖）+ 临时文件改名原子写。

### 15.4 REPL / 启动器 / 其它

- `render-inline` 未闭合 `**` 行尾强制复位（防终端残留加粗）。
- `import-transcript` 净化被截断导出的会话（去前导孤立 tool 与尾部悬空 tool_calls），续谈不再 400。
- `start.ps1` 恢复 UTF-8 BOM（PS 5.1 中文解析）并 `Set-Location` 到仓库根；`start.bat` 转 ASCII+CRLF（cmd 下 UTF-8 注释报错）。
- dev-http 429 视为可重试；HTML 实体解码扩展（quot/apos/nbsp/数字实体）；yason 解码语义实测并修正注释（null→NIL）。

测试计数：55 → **66**（新增 sandbox 逃逸、下划线属性校验、数组 items 类型、整数浮点容忍、重试三态、看门狗超时、code.exec 超时、workspace 约束、memory 键不碰撞等）。

### 15.5 REPL 摘要式上下文压缩已移除（2026-09-07）

决策：REPL 的"调模型把旧会话凝成摘要"方案不好用，整体移除，后续不再采用该思路。

删除范围（`scripts/repl.lisp`）：
- 自动触发：`maybe-compact`、`*context-budget-chars*`、`ctx-tokens`、`summarize-in-child`、`msg-line`（含 `ask-turn` 前的自动压缩调用）；
- 手动命令：`/compact`、`/budget`（连同 `/help` 中的说明行）。

保留：
- 引擎层上下文管理 `max-history` / `context-budget`（超限丢弃最旧完整回合，不调模型、不生成摘要；默认关闭、按 agent 配置启用）——已在 §15.2 做过配对安全的 turn 级裁剪；
- `task.delegate` 的子会话"只回结论"、`/plan` 的一次性子会话步骤执行不受影响（那属于任务委派而非上下文压缩）。

超长会话的后续方向：由用户主动 `/new` 或引擎窗口裁剪处理，不再自动调模型做摘要。

---


