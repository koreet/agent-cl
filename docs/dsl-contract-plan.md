# DSL 可验证执行契约 —— 落地方案与验收清单

> 上位需求：`docs/requirements-from-shared-chat.md`（源自分享对话归纳，提出"DSL 可验证执行契约 + 世界规则 + AI 审计"）。
> 本文件是**把那份宏大叙事压成可落地两件事 + 验收测试**的实现蓝图。只做"地基 + 起点"，不追完整依赖图与版本演化。
>
> 阅读约定：
> - §A 对齐仓库现状（我们**已经有的**底座，避免重复造）。
> - §B 本轮要做的两件事（P0 地基、起点），各给出宏形态、实现草图、验收断言。
> - §C 明确本轮**不做**的东西与理由。
> - §D 推进方式（用仓库现有的 selfimprove + run-tests 守门）。

---

## A. 对齐仓库现状（现有底座，直接复用）

| 文档要的东西 | 仓库现状 | 落点 |
|---|---|---|
| 宏里的**执行体** | `defdsl-tool`→`agent-cl.tools:register-tool` | `src/dsl/macros.lisp` |
| **命名→对象注册表**范式（反射层地基） | `defschema`→`register-schema`/`find-schema`（equal 哈希，`*schemas*`） | `src/dsl/schema-gen.lisp` |
| **可执行谓词挂靠点** | `defguard` 谓词 `(agent)→reason\|nil`，注册进 `*extra-guards*`，`check-extra-guards` 逐条跑 | `src/loop/engine.lisp` |
| **引擎扩展钩子**（goal 判定/审计拦截） | CLOS：`on-step-start`/`before-llm-call`/`on-tool-result`/`on-turn-done`/`choose-messages` | `src/loop/engine.lisp` |
| **事件溯源会话（P1）** | 已有：`session/store` + `.agent-cl/sessions/*/events.jsonl` + `/export`/`/load` | `src/session/store.lisp` |
| **测试守门** | 自研 harness（`deftest`/`is-equal`/`ok`/`signals-error`），全套基线 84 passed | `tests/*`、`scripts/run-tests.lisp` |
| **改自己也要守门** | `agent-cl.selfimprove:improve-file`（备份→补丁→真 run-tests 门→采纳/回滚） | `src/selfimprove/engine.lisp` |
| **mock transport（断言 LLM 调用次数）** | `agent-cl.llm:make-mock-transport` + `mock-script`/`mock-push` | `src/llm/transport.lisp` |

**结论**：文档 §7 说的"元数据对象 + 反射层"在本仓库几乎是**照 `register-schema` 的模子再做一个 `*declarations*` 注册表**即可；`:done-when`/审计谓词有 `defguard` 这个现成挂靠点；"不增加 LLM 调用"可用 mock transport 硬断言。**不引入任何新依赖。**

---

## B. 本轮两件事

### B1（P0 地基）—— 元数据对象与反射层

**目标**：给所有 DSL 声明一个统一的"元数据对象 + 注册表 + `describe-*`"，作为 `defgoal`/`defprinciple`/`defaudit` 的公共底座。

**形态**（草图，落在新文件 `src/dsl/meta.lisp`，包 `agent-cl.dsl`）：

```lisp
(defclass dsl-declaration ()
  ((name     :initarg :name     :accessor decl-name)     ; 符号
   (kind     :initarg :kind     :accessor decl-kind)     ; :goal | :principle | :audit ...
   (source   :initarg :source   :accessor decl-source)   ; 来源文件/行（写时捕获）
   (version  :initarg :version  :initform 1 :accessor decl-version)
   (refs     :initarg :refs     :initform nil :accessor decl-refs) ; 符号引用列表
   (spec     :initarg :spec     :initform nil :accessor decl-spec))) ; 关键字 plist

(defvar *declarations* (make-hash-table :test 'equal) "名字字符串 -> dsl-declaration")

(defun register-declaration (decl) ...)
(defun find-declaration (name &optional kind) ...)
(defun all-declarations (&optional kind) ...)
(defun describe-declaration (name) ... "人类可读摘要（结构可读投影）")
```

**关键约束（来自 §2.3/§2.4）**：
- 宏之间**只允许符号引用**（`(:governed-by data-integrity)`），编译期把引用符号收进 `refs`——**为将来依赖图留口子，但本轮不建图**。
- 每个新宏**必须**配一个 `describe-*`（DSL 写给人，反射写给 Agent）。

**验收（可写成 run-tests 断言）**：
1. `(register-declaration d)` 后 `(find-declaration "x" :goal)` 取回同一对象；不同 kind 同名不串。
2. `(describe-declaration 'g)` 返回含 name/kind/refs 的人类可读字符串（投影存在）。
3. 一个引用 `(:governed-by data-integrity)` 的声明，其 `decl-refs` 含 `data-integrity` 符号（**只收集、不评价**）。

### B2（起点）—— `defgoal` 最小可用版 + `:done-when` 本地判定

**目标**：跑通"目标树 + 本地可 eval 的完成谓词 + 失败重启策略"，并**用 mock 证明不增加 LLM 调用**。不做完整依赖图/版本演化。

**形态**（草图，`src/dsl/goals.lisp`）：

```lisp
(defgoal fix-bug ()
  (:intent "修复失败的测试")
  (:subgoals reproduce diagnose fix verify)          ; 子目标符号树
  (:budget (:tokens 50000) (:risk :workspace-write))
  (:preconditions (tests-pass-p))
  (:done-when (and (tests-pass-p) (no-new-warnings-p)))
  (:on-failure (retry :max 2)))
```

展开为：`(register-declaration (make-goal ...))`，并**不**在展开期 eval 谓词——谓词以**闭包/表单**形式存进元数据（`:done-when` 保留为可 `eval` 的 form，`subgoals` 存符号表）。

**运行支持**（最小）：
```lisp
(defun goal-done-p (goal &optional (env nil))
  "本地 eval (:done-when form)，失败返回 nil（不抛）。不产生任何 LLM 调用。")
(defun goal-subgoals (goal) ...)  ; 返回子目标符号列表（可遍历）
```
- **`goal-done-p` 只做本地 `eval`**：谓词体里的 `tests-pass-p`/`no-new-warnings-p` 是本仓库可用的纯函数或钩子；**语义不可判的谓词（如 "elegant-p"）明确不属于本轮**（见 §C）。
- `:on-failure` 本轮只做 **`(retry :max N)`** 的解释（本地计数重试），不接条件系统 `restart`（那是后续）。

**验收（可写成 run-tests 断言，重点第 2 条）**：
1. `(goal-done-p g)` 对 `(and t t)` → T，对 `(and t nil)` → NIL；谓词抛错 → NIL（不崩）。
2. **`defgoal` 从"检查完成"到"重试"全程不产生 LLM 调用**：用 `make-mock-transport` 记录请求次数，跑一个"done-when 恒真"的最小循环，断言 transport 请求数 = 0（或比未用契约时更少）。*这是本轮唯一真正证明"契约减少调用"的硬断言。*
3. `(goal-subgoals g)` 返回声明的 4 个子目标符号，顺序一致。
4. `(describe-goal 'g)` 人类可读（含 intent/subgoals/budget）。

---

## C. 本轮明确不做（及理由）

| 不做 | 理由 |
|---|---|
| 完整**依赖图 + 变更影响分析** | §8 自己也说"不一开始就做"。先让符号引用**被收集**（B1 的 `refs`），建图留待有真实用例。 |
| **版本演化 / 自动回滚 / 效果对比** | 需要"版本间效果对比机制"，是重工程；先把单版本跑通。 |
| `defprinciple` 的**冲突解决推理** / 宪法层不可改 | 依赖依赖图与优先级排序；等 B1/B2 稳了再做。 |
| `defaudit` 的**完整执行器** | 但**可以**先用现成的 `defguard`+`check-extra-guards` 做一版最小审计（见下）。 |
| `defidentity`/`defmemory`/`defintrospect` | 是更大的人格/记忆/元认知体系，非本轮。 |
| `:on-failure` 对接条件系统 `restart` | 先用本地 `retry :max N`。 |
| **语义级谓词**（"优雅"、"无 session 引用"这类需要判断的） | 诚实红线：本地不可判的谓词若塞进来，等于"换个地方问 LLM"，会虚增"减少调用"的账。本轮 predicate 只接受**本地可判**的。 |

**最小审计（可选的低成本一步）**：`defaudit` 先做成 `defguard` 的语法糖——`:check` 谓词直接注册进 `*extra-guards*`，`:on-violation :block` 复用 guard 的拦截路径。这样"越界即阻断"立刻可用，且**不新造执行器**。

---

## D. 推进方式（守门与提交）

1. **每个新宏配 run-tests 单测**，保持全套从 84 继续绿（只增不减）。
2. 改动若动到已有文件，走 `agent-cl.selfimprove:improve-file` + 真实 `scripts/run-tests.lisp` 当门（沿用既有可信闭环）。
3. **新文件**：`src/dsl/meta.lisp`（B1）、`src/dsl/goals.lisp`（B2）、`tests/dsl-contract-tests.lisp`；接入 `agent-cl.asd` 的 `:components`（追加，不改既有项顺序）。
4. 提交流程与既有三次 commit 一致（`feat(dsl): ...`），消息用文件避免 shell 转义。
5. **环境纪律**（参见 memory）：本机 Windows/GBK，验证优先纯 ASCII 测试输出；**禁**在 agent 上下文起/养常驻服务、**禁**按进程名 kill sbcl（会误杀宿主）。

---

## E. 一页速览（给未来的自己）

- 底座够用：`register-schema` 是反射层模板；`defguard` 是审计挂靠点；mock transport 是"少调用"的裁判。
- 本轮只做两件：**B1 反射层** + **B2 defgoal 最小版（done-when 本地 eval，mock 断言 0 LLM 调用）**。
- 红线：不做依赖图/版本演化；不做语义级谓词（那只是把问题挪给 LLM）。
- 验收锚：`describe-goal` 可读、`goal-done-p` 纯本地、mock 请求数为硬指标、全套测试只增绿。
