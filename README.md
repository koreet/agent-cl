# agent-cl

> A "modern agent" built from scratch in Common Lisp (SBCL): OpenAI-compatible tool
> calling, a ReAct loop, streaming output, an event-sourced session log, a builtin
> tool set, and deep customization through a **Lisp-macro DSL**.

**Language**: English · [中文](README.zh-CN.md)

Architecture and milestone notes: [docs/architecture.md](docs/architecture.md) (Chinese).

---

## What it is

A self-hostable, deeply hackable coding/research agent. The core loop
(`src/loop/engine.lisp`) is deliberately small: **step → LLM round trip → if tool
calls arrived, validate and dispatch them → feed observations back → repeat, until
the model answers or a guard fires**. Every extension point is a CLOS generic
function with a no-op default, so behaviour is customized by *subclassing the agent
class*, never by editing the loop.

On top of that sits a macro DSL: tools, policies, guards, audit rules, goals,
principles, identity, memory and metacognition are declared as code — and a single
declaration is the source of truth for the schema, the wire description and the
validator.

**Status**: **324 unit/integration tests pass, 0 fail** (all offline, no key needed),
plus real end-to-end checks against DeepSeek: `[SMOKE-OK]` and `[LIVE-STREAM-OK]`.

---

## Highlights

**Engine and protocol**

- ReAct loop with parallel tool calls (`policy-parallel-tools`; in serial mode the
  skipped calls still get an explicit result so the transcript stays legal)
- SSE streaming: tool-call arguments are concatenated per `index`; `[DONE]`
  variants, heartbeat lines and truncated chunks are all handled explicitly
- Automatic retry of transient failures (5xx/429, exponential backoff, interruptible)
  — but a stream that already emitted tokens is **never** retried, because the text
  is already on screen
- Message-sequence invariants: every `tool_calls` entry always has a matching tool
  result; interrupts, serial mode and stop() all fill in placeholders, so a later
  request is never rejected with 400
- Token/cache accounting; truncated answers (`finish_reason: length`) are flagged;
  an empty answer is not reported as a completed turn
- Context trimming works on whole *turns*, so an assistant `tool_calls` message is
  never split from its tool results

**Builtin tools (9)**

| Tool | What it does |
|---|---|
| `shell.run` | Run a command with a real wall-clock watchdog (UIOP's `:timeout` is a no-op on Windows; this kills the whole process tree) |
| `file.read` / `file.write` | Text I/O, confined to the workspace root by default (see *Security model*) |
| `time.now` | Current UTC time (ISO-8601) |
| `code.exec` | The agent writes code and runs it (python / sbcl / sh), returning the real exit code and stderr |
| `memory.set` / `memory.recall` | Persistent memory across sessions (`~/.agent-cl/memory/`; the key→filename mapping is injective) |
| `web.search` | Web search: Tavily by default (needs a key), or `:backend "ddg"` for keyless DuckDuckGo; result cache, per-process budget, per-child allowance and a quota breaker |
| `task.delegate` | Spawn a child agent (own short session, returns only the conclusion); delegation is removed by object identity, the child's tools are intersected with the parent's, and depth is capped |

**Sessions and memory**

- Event-sourced sessions: `~/.agent-cl/sessions/<id>/events.jsonl`, one JSON event
  per line — auditable and resumable
- `/sessions` lists them (checkpoint-only sessions with no conversation are hidden by
  default; `/sessions all` shows everything), `/use` switches by number/id/prefix and
  replays recent history
- `/export` and `/load` round-trip JSONL; loading sanitizes truncated transcripts
  (leading orphan tool results, dangling `tool_calls`)
- Quitting without saying anything does not leave an empty session behind

**Front ends**

- REPL: streamed Markdown rendering (headings, bold, inline code, tinted code fences,
  aligned tables), a pinned status bar + input line when the terminal supports it;
  colour can be disabled with `NO_COLOR=1` or `/color off`
- Read-only console GUI (Hunchentoot on `127.0.0.1:8977`): browses the real session
  event logs; its chat box is a mock and does not write to sessions

**Security model**

- **Workspace confinement**: `file.read`/`file.write` stay inside the repository root.
  Two layers: lexical folding (normalizing `..`), then a **filesystem check that
  refuses links** (Windows reparse points / POSIX symlinks) — a junction can point
  outside the workspace, and a string comparison cannot see through it. Use
  `(set-file-workspace-root nil)` to opt out explicitly.
- **Audits are preventive**: a `defaudit` rule with `:applies-to` is consulted
  *before* the tool runs (`:on-violation :block` refuses the call, `:warn` runs it and
  annotates the result) instead of complaining after the fact. Rules accumulate per
  tool, and both the wire name (`file_write`) and the DSL name (`file.write`) match.
- **The executable sandbox is off by default**: `*dsl-execution-mode*` is `:off` until
  `with-dsl-sandbox` turns it on. Only whitelisted pure functions are callable, and
  they resolve through the `CL` package only (so a host function that shadows a
  whitelisted name is unreachable). Steps, argument size, integer magnitude and result
  length are capped, and circular structures are rejected outright.
- **Self-improvement is gated**: `improve-file` may only touch files inside the repo
  and refuses the gate itself (`scripts/run-tests.lisp`, `tests/`, `agent-cl.asd`,
  `.git/`, `.tools/`). It runs backup → patch → *real* test suite → adopt or roll back,
  and a cleanup failure after a patch went live is never reported as "rejected".

---

## Quick start

### Windows (one command)

```powershell
cd C:\path\to\agent-cl
.\start.ps1                 # interactive REPL (real model)
.\start.ps1 -Mode smoke     # real API smoke test (needs a key)
.\start.ps1 -Mode test      # all unit/integration tests (no key, no network)
.\start.ps1 -Key sk-xxxx    # pass a key for this run
.\start.ps1 -Model deepseek-chat -BaseUrl https://api.deepseek.com/v1
start.bat                   # equivalent entry point; double-clickable, forwards args
```

Key resolution order: `-Key` > `AGENT_CL_API_KEY` > `%USERPROFILE%\.agent-cl\api-key.txt`
> interactive prompt. `start.ps1` also puts Git's `mingw64\bin` on `PATH`, which
`cl+ssl` needs for the `libcrypto`/`libssl` DLLs.

### Any platform (direct)

```bash
sbcl --script scripts/run-tests.lisp    # tests
sbcl --script scripts/smoke.lisp        # real API smoke (needs a key)
sbcl --script scripts/repl.lisp         # REPL
sbcl --script console/server.lisp       # console GUI (http://127.0.0.1:8977)
```

### Requirements

- **SBCL 2.6.x** (on Windows the default install under
  `C:\Program Files\Steel Bank Common Lisp\` is found automatically)
- **Quicklisp** (`~/quicklisp/setup.lisp`) for four dependencies: `alexandria`,
  `yason`, `split-sequence`, `bordeaux-threads` (a vendored `.tools/deps` layout is
  used first when present, which is what makes an offline build possible)
- Optional: `dexador` + `cl+ssl` + `cffi` for in-process HTTPS. Without them the REPL
  still starts, but real calls fail with a clear transport error
  (`scripts/smoke.lisp` falls back to the node helper `scripts/http-request.js`)
- Optional: `hunchentoot` (console GUI), `python` (for `code.exec`), Git for Windows
  (`sh` and the CA bundle)

---

## REPL commands

| Command | Purpose |
|---|---|
| `/help` | command help |
| `/tools` | list the available tools |
| `/memory` | list persistent memory keys |
| `/export <file>` | export the current session as JSONL |
| `/load <file>` | load a JSONL transcript and continue (BOM and bad lines are skipped and reported) |
| `/new` | start a new session (the current one is archived) |
| `/sessions [all]` | list saved sessions (conversation-less ones are hidden by default) |
| `/use [n\|id\|prefix]` | switch session, or pick interactively; replays history |
| `/color on\|off` | toggle ANSI colour (without an argument it only reports) |
| `/usage` | model / token usage / working directory |
| `/model [name]` | fetch the model list from the API and pick, or switch directly |
| `/plan <task>` | Plan-then-Execute: split into steps → run them → summarize |
| `/demo` | Markdown rendering + status-bar self check |
| `/engine new\|legacy` | new/old renderer (legacy has no fenced-code tinting) |
| `/footer on\|off` | toggle the pinned bottom status/input rows |
| `/quit` · `/exit` | quit (an unused, conversation-less session is not kept) |

`Ctrl-C`: while work is **in progress** (a model turn, `/plan`, `/model`) it interrupts
that work and keeps the session; **at the prompt** it exits.

---

## DSL tour

```lisp
;; L2: a domain tool — the declaration is the schema AND the wire description
(defdsl-tool "calc.add" "Add two numbers"
    ((a :number :description "augend" :required t)
     (b :number :description "addend" :required t))
  (values (format nil "~a" (+ (getf args :A) (getf args :B))) :ok))

;; L1: policies / guards / agents
(defpolicy chatty (:max-steps 30 :temperature 0.7 :parallel-tools t))

(defguard token-heavy (a)
  (when (> (agent-cl.loop:agent-usage-total a) 200000) "token budget too high"))

(defagent my-bot
  (:model "deepseek-chat" :base-url "https://api.deepseek.com/v1"
   :system "You are a Common Lisp engineer; you may write and run code yourself."
   :tools (shell.run file.read file.write time.now code.exec calc.add)
   :policy chatty))

(agent-cl.loop:run my-bot "Write Python that sums the squares of 1..10, run it, report the result")

;; Audit rule: enforced BEFORE the tool runs (:applies-to names tools;
;; :governed-by is only a reference).
;; NOTE: a :check body receives only the AGENT — the engine's tool-guard protocol
;; passes the tool name and arguments to the adapter, but the adapter forwards the
;; agent alone — so rules decide from observable agent/world state.
(defaudit stop-when-stopped
  (:applies-to file.write)
  (:on-violation :block)
  (:check (when (agent-cl.loop:agent-stopped-p agent) "agent is stopped; no writes")))

;; Goal contract: subgoals are walked by CODE and :done-when is a LOCAL predicate,
;; so "am I done?" never costs a model call
(defgoal fix-bug
  (:intent "make the failing test pass")
  (:subgoals reproduce diagnose fix verify)
  (:done-when (and (probe-tests-pass) t))
  (:on-failure (retry :max 2)))

;; Principles and the constitution: a top-priority principle is FROZEN at
;; registration and cannot be quietly demoted
(defprinciple data-integrity (:priority 100)
  (:statement "User data integrity outranks task completion speed")
  (:constrains workspace-write))

;; Metacognition / identity / narrative memory
(defintrospect auth-rework
  (:based-on ((has-relevant-file-p) (last-test-passed-p)))
  (:threshold 0.6) (:on-low :ask-clarifying-question))

(defidentity founder
  (:core-traits (:honesty 1.0) (:caution 0.7))
  (:anchor "Honesty first; when unsure, say so"))

(defmemory failed-migration-42
  (:content "the last auth migration broke on a boundary case") (:salience 0.8)
  (:recall-when (goal-active-p 'refactor-auth)))
```

> Note: `defaudit` does **not** take a lambda list (do not write
> `(defaudit name () ...)`). For `defprinciple`/`defintrospect`/`defidentity`/
> `defmemory`/`defgoal` the decorative `()` after the name is **optional** — both
> shapes work, and omitting it no longer swallows the first clause.

Sandbox (off by default):

```lisp
(agent-cl.dsl:with-dsl-sandbox (:mode :interpreter :max-steps 100 :max-sequence 10000)
  (agent-cl.dsl:dsl-eval-safe '(+ 1 2)))     ; => "3"
```

---

## Tests and verification

```powershell
.\start.ps1 -Mode test                          # or:
& "C:\Program Files\Steel Bank Common Lisp\sbcl.exe" --script scripts\run-tests.lisp
```

- A ~90-line dependency-free harness (`tests/harness.lisp`: `deftest` / `ok` /
  `is-equal` / `signals-error`)
- **A test must make at least one assertion** — a test with none is reported as a
  failure. Since that rule landed it has caught three tests that could never fail
- Everything runs against mock transports and the local filesystem: **no key, no
  network**. The real API path is covered by `scripts/smoke.lisp` and
  `.tools/verify-live-stream.lisp`
- The audit tooling lives under `.tools/`: `check-scripts.py` (entry scripts must load
  with zero compile diagnostics), `drive-repl*.py` (scripted REPL sessions over piped
  stdin), `verify-fresh-clone.py` (clone into a temp dir and run the suite),
  `verify-fixes*.lisp` (security repros)

Real-machine results after the latest audit round:

| Check | Result |
|---|---|
| Unit/integration tests | 324 passed, 0 failed, no compiler warnings |
| Entry scripts (repl / console) | load with zero compile diagnostics |
| Real DeepSeek smoke | `[SMOKE-OK]`: 2 steps, 1 tool call, real UTC time |
| Real streaming | `[LIVE-STREAM-OK]`: 24 deltas; streamed text identical to the final answer (no duplication, no truncation) |
| Junction escape (read/write) | both refused; ordinary paths in the same root unaffected |
| Memory-key injectivity (585-key brute force) | 0 collisions |
| Fresh `git clone` + tests | 324 passed (works without `.tools/`) |

---

## Layout

```
agent-cl.asd              system definitions (agent-cl / agent-cl-tests)
start.ps1 / start.bat     Windows one-command launchers
src/
  core/                   util (paths, process watchdog, lenient file reads), json, log, error
  llm/                    codec (OpenAI-compatible), sse (stream parsing), transport (mock/http)
  messages.lisp           message envelope (role/content/tool_calls/name)
  schema/                 JSON Schema validation + coercion
  tools/                  registry + builtin (9 tools)
  loop/engine.lisp        ReAct engine, policy, guards, tool guards, context trimming
  dsl/                    macro surface (macros) + meta/audit/principles/goals/graph/identity/memory/introspect/sandbox
  session/store.lisp      event-sourced sessions (JSONL, O(1) append under a lock)
  render/                 Markdown line classifier (pure) + terminal geometry/escapes (pure)
  web/search.lisp         web.search: Tavily/DDG + cache + budget + breaker
  selfimprove/engine.lisp gated single-file self-improvement
scripts/                  repl / plan / smoke / run-tests / dev-http / env / installers / node helper
console/                  read-only Hunchentoot console (server.lisp + static/index.html)
tests/                    20+ test files (including audit-round2/3 regressions)
docs/architecture.md      architecture, milestones, real-machine regression log
```

---

## Known limitations

Prioritized; each was reproduced and is not fixed yet:

1. `scripts/http-request.js` (the node fallback path) has **no request timeout**: a
   server that accepts and never answers hangs the process forever, and the transport
   timeout is not forwarded.
2. The `web.search` breaker is **process-wide** (tripping on one backend also refuses
   the other) and still phrase-matches, so reflected query text could in principle trip it.
3. The console's `/api/session` validates by decode→encode, which turns JSON `false`
   into `null` (invisible today because the UI only reads `role`/`content`/`type`);
   the chat box is a mock but its bubble is labelled "Agent-CL" with no "not saved" hint.
4. A `defaudit` `:check` body receives only the `agent`, so it **cannot see the tool
   name or arguments of the call being made** (the adapter drops both) — a rule cannot
   be written against the arguments; register a tool guard directly if you need that.
5. DSL rough edges: a misspelled `defagent` option silently drops a limit (e.g.
   `:max-step`); `:tools :all` is not expressible through the DSL; `defdsl-tool`
   interns `ARGS`/`CTX` into `*package*` at macroexpansion time; the dependency graph
   ignores packages; multiple `:preconditions` forms are evaluated as one call;
   two same-named guards in different packages collapse into one.
6. Performance nits: transcript append is still O(n) (O(n²) over a long session);
   session append costs ~5 ms/event and is serialized by one global lock.
7. Platform nits: the POSIX console probe only reads `COLUMNS`/`LINES` (no tty check);
   `path-inside-p` denies everything when the root is a drive/filesystem root.
8. Odds and ends: `agent-cl.messages:role-*` and `agent-cl.render:make-md-line` are
   exported but undefined; `schema-error`/`guard-triggered` are dead conditions;
   `shell-command` is dead code; `***x***` renders one stray `*`; emoji count as width 1.
9. Untracked draft directories (`demo/`, `agent-console/`, `demo_gui/`, `lisp-modeler/`)
   have known issues too: `demo/dsl-contract-demo.lisp` crashes in section 7 because of
   an extra `()` in a `defaudit`; `lisp-modeler`'s capped cylinder has wrong cap indices
   and `(scale m 3)` only scales x.

---

## Environment notes (why this is not a textbook CL project)

The project was first built inside a Windows sandbox **without admin rights, with a
broken winget alias, schannel TLS disabled and no way to download Quicklisp dists**,
so a few adaptive designs survive (all of them work fine on a normal machine):

- **Dependency bootstrap**: every `scripts/*.lisp` probes Quicklisp
  (`~/quicklisp/setup.lisp`); when present it `ql:quickload`s the four dependencies and
  then `asdf:load-system :agent-cl`. Without Quicklisp it falls back to a vendored
  `.tools/deps` layout (a sandbox-era artifact that is *not* committed;
  `scripts/env.lisp` documents how that layout loads).
- **Real HTTP**: `src/llm/transport.lisp` delegates network calls to
  `*http-fetch-hook*`. On a normal machine the hook is **in-process dexador**:
  `scripts/dev-http.lisp` loads cffi/cl+ssl/dexador, forces the usocket backend (to
  bypass the default WinHTTP/schannel), and verifies certificates with Git's CA bundle
  (on Windows, `C:\Program Files\Git\mingw64\bin` must be on `PATH`; `start.ps1` does
  that automatically). dexador raises a continuable error for any status ≥ 400, which
  `dev-http.lisp` converts into a clean `transport-error` carrying the server's body
  (4xx is not retried, 5xx/429 is), and connection-level failures are classified as
  retryable too.
- **ASDF fasl cache** is redirected into the repo (`.tools/cache`, gitignored) via
  `XDG_CACHE_HOME`.
- **Deliberate deviations from the architecture doc**: the doc prefers rove for tests
  → this repo ships its own harness; log4cl for logging → `src/core/log.lisp`;
  clingon/local-time/uuid were not adopted, replaced by minimal implementations.

---

## Milestones

| Milestone | Content | State |
|---|---|---|
| M0 | SBCL 2.6.8 + dependency bootstrap + ASDF skeleton (packages / conditions / log / JSON) | ✅ |
| M1 | LLM transport: message envelope, OpenAI-compatible codec, SSE streaming (tool args concatenated per index), mock transport | ✅ |
| M2 | ReAct engine: schema validation, tool registry, builtin tools, guards, CLOS hooks | ✅ |
| M3 | DSL: `defdsl-tool`/`defcommand`/`defschema`/`defpolicy`/`defguard`/`defagent` + a whitelist sandbox that is off by default | ✅ |
| M4 | Event-sourced sessions (JSONL) + export/load + pause/resume + REPL entry point | ✅ |
| M5 | Engine window/budget trimming + Plan-then-Execute (`/plan`) | ✅ |
| M6 | Real API smoke + full Windows regression | ✅ |
| M7 | Executable contract layer: `defaudit` (pre-execution) / `defgoal` / `defprinciple` (frozen constitution) / `defidentity` / `defmemory` / `defintrospect` + dependency graph | ✅ |
| M8 | Two full-project audit rounds and hardening (security boundary, gate honesty, wire-name matching, test effectiveness) | ✅ |

---

## Docs

- [docs/architecture.md](docs/architecture.md) — architecture, module responsibilities,
  milestones, real-machine regression and audit records (Chinese)
- Other design drafts live in `docs/` (`dsl-contract-demo-brief.md`,
  `requirements-from-shared-chat.md`, `tonight-summary.md`)

## License

Apache License 2.0 — see [LICENSE](LICENSE).
`agent-cl.asd` declares the same license, so tooling (and GitHub's license
detection) sees one answer.
