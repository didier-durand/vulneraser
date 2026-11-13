# LPES — Technical Architecture: Agent Deployment & Isolation Options

Evaluation of deployment options for LPES agents (Orchestrator, 14 Specialists, Verifier, Report, Exploit Agent, PoC Validation Runner), all implemented on **Pi Agent** (`@earendil-works/pi-coding-agent`). Companion to `lpes_specs.md`.

Dimensions evaluated: isolation, communication, orchestration, cost/performance, failure semantics, debuggability, and fit with the trust boundaries already defined in the specs (§4.5, §11).

---

## 1. Pi Agent integration surfaces

The choice is which of Pi's three integration surfaces each agent runs on:

| Surface | How an agent runs | Control channel |
|---|---|---|
| **SDK in-process session** | `createAgentSession()` inside one Node process; `prompt()`, `subscribe()`, `abort()`, `steer()`/`followUp()`; `SessionManager.inMemory()` for stateless agents | Direct function calls, in-memory events |
| **CLI subprocess** | `pi -p --json` per batch, spawned by a driver (TS, Python, bash) | stdin/stdout JSON, exit codes; process kill for abort |
| **Extension-based subagents** (pi-subagents) | Parent session gets a `subagent` tool; each invocation spawns a fresh `pi -p` subprocess from a Markdown agent definition (frontmatter: `name`, `tools`, `model`; body: system prompt) | Tool call from the parent LLM; JSON-mode stdout captured back into the parent context |
| **Whole-process container / sandbox** | Plain Docker, Docker Sandboxes, OpenShell, Gondolin micro-VM | Network / volume mounts |

Pi facts that shape the decision:

- **Tool restriction is enforceable in-process.** `tools` / `excludeTools` / `noTools` / `customTools` let a specialist session be denied `bash`, `write`, and `edit` entirely (including user `!` commands). For read-only agents, this is a stronger control than container count.
- **MCP is stdio-oriented.** SDK sessions need `createMcpExtension()` added explicitly and `session.bindExtensions()` called. Cross-container access to the Shared Toolkit requires a stdio↔network bridge or an HTTP-tool wrapper extension.
- **Graceful abort is in-process only.** `abort()` / `waitForIdle()` implement the Orchestrator's budget-kill rule (specs §4.1, item 6) cleanly; a CLI subprocess can only be SIGKILLed, losing partial reasoning and tool-call counts.
- **Session persistence is a choice.** `SessionManager.inMemory()` keeps transcripts out of the container filesystem (smaller attack/leak surface); file-backed sessions provide an audit trail (required by §11 for human review before disclosure).
- **Subagents are subprocesses, not threads.** Pi's `subagent/` example extension implements agent dispatch as a parent-session tool: agents are Markdown files discovered from `.pi/agents/` (project) or `~/.pi/agent/agents/` (user), each invocation is a fresh `pi -p` process with `--tools <allowlist>` and optional `--model`, and output is captured back with per-task token/cost stats. This makes LLM-driven dispatch possible with almost no custom code — and is evaluated as Option E below.

---

## 2. Option A — All agents in one container, one process (SDK sessions)

All agents are `createAgentSession()` instances inside a single Node process in a single container. The Shared Toolkit MCP server runs as an in-process extension or stdio sidecar in the same container. The Orchestrator is host TypeScript code driving an LLM session.

| Dimension | Assessment |
|---|---|
| **Isolation** | ⚠️ Weakest. All agents share process, filesystem, and credentials. A specialist compromised via prompt injection (kernel source is untrusted input, §11) shares the Orchestrator's blast radius. A process crash kills all 14 specialists mid-batch. |
| **Communication** | ✅ Best. Findings passed by value; `subscribe()` streams tool calls for live budget monitoring; no serialization, retries, or service discovery. |
| **Orchestration** | ✅ Trivial. A TS concurrency pool; `abort()` implements the "2× expected tool-call count" kill rule; the toolkit cache is shared in-process for free (§5.4 constraint 3). |
| **Cost / performance** | ✅ Best. LLM latency dominates; 14 concurrent sessions are I/O-bound and cheap. One container image to pin → the whole SAST toolchain (§5.4) is deterministic by construction. |
| **Debug / failure** | ✅/⚠️ One log stream, easy to reproduce; but no fault isolation — one runaway allocation affects everyone. |
| **Mitigations** | Tool allowlists (deny `bash`/`write`/`edit` to specialists), `SessionManager.inMemory()`, read-only kernel-tree mount. The real security boundary becomes the **tool allowlist**, not the process boundary. |

**Verdict:** ideal for P0–P2 and the detection tier generally — *if* tool restriction is treated as a hard, tested security control (see §6, cross-cutting rules).

## 3. Option B — One container, one process per agent (CLI subprocesses)

Each batch runs as `pi -p --json` spawned by a driver process; the driver owns the plan, pool, retries, and budgets.

| Dimension | Assessment |
|---|---|
| **Isolation** | ⚠️→✅ Process-level only: an OOM or hang in one specialist no longer kills siblings; `ulimit`s per subprocess give real resource isolation. But same-container filesystem and credentials mean the prompt-injection blast radius is ≈ Option A. |
| **Communication** | ✅ Structured JSON on stdout per batch enforces the `Finding` schema (§8.3) at a process boundary — parse failures are hard errors, which is good conformance discipline. ⚠️ No steering mid-run; abort = kill, losing partial work. |
| **Orchestration** | ✅ Simple pool + retries in the driver; the driver can be **Python**, matching the retrieval pipeline — one language for everything except the agents. |
| **Cost / performance** | ✅ Node boot ~1 s per batch vs ~12 s per batch — negligible. |
| **Debug** | ✅ Each agent's transcript is a self-contained session file; per-agent replays are reproducible. |

**Verdict:** attractive if the driver should stay in Python and process-level fault isolation is wanted; loses the Orchestrator's ability to steer or abort gracefully.

## 4. Option C — Container per agent (or per agent class)

Orchestrator container + N specialist containers (optionally replicated) + verifier + exploit agent; kernel tree and CPG on a shared read-only volume; findings delivered via network or orchestrator pull.

| Dimension | Assessment |
|---|---|
| **Isolation** | ✅ Strong. Per-container filesystem (kernel tree read-only), per-container network policy (egress = LLM API only; no lateral ports except the Orchestrator), per-container resource quotas, scoped credentials. A compromised Exploit Agent cannot see the detection tier's writable state at all. Naturally implements "isolated worker per finding" (§4.5). |
| **Communication** | ⚠️ The pain point. Requires network transport, retries, and **MCP bridging** (Pi's toolkit MCP is stdio; across containers you need an stdio↔HTTP proxy or a custom HTTP-tool extension). New failure modes: partitions, container restarts, partial findings delivery. |
| **Orchestration** | ⚠️ Heavier: compose/k8s, health checks, log aggregation, and image pinning across N images — determinism (§5.3) requires *all* images pinned identically by digest. For a batch tool with ~1 h runtime, ops overhead is disproportionate on a single host. |
| **Scaling** | ✅ The one real win: horizontal specialist replicas if the 12 h / 16-vCPU budget (G4) is ever threatened, or parallelism across machines. |
| **Cost** | ≈ Same LLM tokens; container overhead is minor on one host, irrelevant across hosts. |

**Verdict:** right answer for the **Exploit Agent tier** (defense-in-depth around generated exploit code, §11) and for multi-host scale-out; over-engineering for 14 stateless, read-only specialists.

## 5. Option D — Managed sandboxes / micro-VMs per agent (Docker Sandboxes, OpenShell, Gondolin)

| Dimension | Assessment |
|---|---|
| **Isolation** | ✅ Strongest: host-kernel isolation plus **credential proxying** — provider keys never enter the agent environment (Docker Sandbox proxy substitutes placeholders; OpenShell routes inference). Directly serves §11 ("keys never written to reports, artifacts, guest environments, or logs"). |
| **Communication** | ⚠️ Worst: remote gateways lack bind mounts → explicit upload/download of candidates and findings per batch; every hop adds latency to tool-heavy specialist loops. |
| **Orchestration** | ⚠️ Sandbox lifecycle management per batch; significant CI complexity. |
| **Cost / performance** | ⚠️ VM boot + memory per agent materially cuts into the batch budget at 14× parallelism. |
| **Gondolin caveat** | Gondolin isolates *tools*, not the agent process. LPES's threat model is the **agent being manipulated by untrusted source**, so agent + tools must be isolated together — whole-process sandboxes. Gondolin inverts the boundary in the wrong direction for LPES. |

**Verdict:** reserved for the Validation tier — which already uses disposable VMs per specs, so Option D adds little there. Not worth it for detection-tier agents.

---

## 6. Option E — Extension-based subagents (pi-subagents)

One parent Pi session (the Orchestrator) plus a set of **agent definitions as Markdown files**. This is a distinct orchestration model — not just another container layout — because dispatch becomes a *tool call made by the LLM* rather than host code.

**Mechanism** (from Pi's `subagent/` example extension):

- Agents are Markdown definitions (frontmatter: `name`, `description`, `tools` allowlist, `model`; body: system prompt) discovered from `.pi/agents/` (project) or `~/.pi/agent/agents/` (user). The 14 specialist prompts already specified as `lpes/prompts/c01_uaf.md … c14_oob_read.md` map 1:1 to these files — single source of truth for prompts, tool allowlists, and per-class model routing.
- The parent session gets a `subagent` tool with three modes: **single** (`{agent, task}`), **parallel** (task list; example caps: 8 tasks, 4 concurrent), and **chain** (`{previous}` output templating) — the last maps naturally onto Orchestrator → Specialists → Verifier → Report.
- Each invocation spawns a fresh `pi -p` subprocess with `--tools <allowlist>`, optional `--model`, and the agent's system prompt; JSON-mode output returns to the parent with per-task usage stats (tokens, cost) and an output cap (~50 KB in the example).

| Dimension | Assessment |
|---|---|
| **Isolation** | ✅ Per-invocation subprocess with a fresh, isolated context window — no cross-batch contamination; per-agent tool allowlist is enforced by the extension (`tools:` frontmatter → `--tools`). Same-container trust tier as Option B: credentials and filesystem are still shared container-wide. |
| **Communication** | ⚠️ One-shot: task string in, final text/JSON out; no mid-run steering, and abort = process kill. The ~50 KB output cap is ample for findings JSONL. ✅ Per-subagent token/cost stats come back for free, feeding budget tracking (§10.1). |
| **Orchestration** | ✅/**⚠️** By far the least custom code of any option — the parallel/chain modes cover the whole LPES flow. But dispatch becomes **LLM-driven**: which subagents run, on what, and how many times is decided by the parent model. This directly conflicts with the deterministic coverage guarantee (specs §1.4, §6.2: "every `kfree` is examined; no LLM skips a file") — an Orchestrator that truncates or rewrites the batch list is a coverage hole. See the mandatory mitigation below. |
| **MCP caveat** | ⚠️ Each spawned `pi -p` subprocess opens its own stdio MCP connection → **one Shared Toolkit server process per concurrent subagent**: no shared in-process cache, multiplied CPG-query processes (§5.2's rate limits assume a single server). Mitigations: move the toolkit cache to disk/Redis, or expose the toolkit over an HTTP transport shared by all subagents. |
| **Cost / performance** | ✅ ≈ Option B; subprocess boot ~1 s per batch. ✅ Free bonus: per-agent model routing in frontmatter (cheap model for C10, strong long-context model for C1/C11) without any host code. |
| **Debug / hardening** | ⚠️ Audit trail depends on session-persistence flags passed to spawned processes; the example's caps (8 parallel, 4 concurrent, 50 KB output) are example values LPES must tune. The `subagent/` extension is an *example*, not a hardened product — budget for forking and testing it (assert allowlists, coverage, and budget kills). |

**Determinism mitigation (mandatory if adopted):**

1. **Partitioning stays in host code** (specs §4.1, items 1–3): `candidates.jsonl` → deterministic batch list, computed before any LLM call.
2. The batch list is handed to the `subagent` tool as a **precomputed parallel task list**; the Orchestrator LLM triages results and adjusts ordering, but cannot add/drop/merge batches.
3. **Coverage assertion** in the regression suite (§9.3): tasks dispatched ≡ batches in the partition; every candidate appears in exactly one dispatched task.

**Verdict:** the strongest candidate for *implementing* the Detection tier with minimal code — effectively "Option B where the pool manager is the extension instead of custom TS/Python". Adopt only with the determinism mitigation and the toolkit cache fix. The same agent-markdown pattern suits the Exploit Agent (frontmatter `tools` = artifact writer only), which should still run in its own container.

## 7. Recommendation: tiered hybrid

Deployment follows the trust tiers already present in the specs:

| Tier | Agents | Deployment | Rationale |
|---|---|---|---|
| **Detection** | Orchestrator, 14 Specialists, Verifier, Report Agent, Shared Toolkit MCP | **One container** — Option A (SDK sessions), or **Option E** (pi-subagents extension) as the low-code variant, or Option B if the driver must be Python | Agents are read-only by design; enforce with Pi tool allowlists (deny `bash`, `edit`, `write`, `!` shell), `SessionManager.inMemory()` or per-invocation `pi -p` subprocesses, read-only kernel mount. Option A: Orchestrator budget-kill maps to `abort()`/`waitForIdle()`, toolkit cache shared in-process. Option E: 14 specialist prompts become agent Markdown files 1:1, parallel/chain modes replace the pool — but requires the determinism mitigation (host-computed batch list + coverage assertion) and a shared toolkit-cache backend. |
| **Exploit generation** | Exploit Agent + constrained artifact writer | **Own container** (Option C-lite): Pi session with *only* the artifact-writer tool; no MCP; no shell; egress = LLM API only; kernel tree not mounted | Cheap defense-in-depth around the one agent that produces executable-looking code; matches §4.5 and §11. |
| **Validation** | PoC Validation Runner | **Disposable VMs, as already specified** (§4.5, §9.6) | This tier's isolation requirements already exceed anything Pi containers provide. |

### Cross-cutting rules (apply regardless of option)

1. **Pin everything by digest** — Pi SDK version, Node, the SAST toolchain image (§5.4). Determinism (§5.3) must survive the deployment choice; any upgrade re-runs the regression suite (§9.3).
2. **Pass findings by value between tiers** — never via shared mutable files — so a compromised specialist cannot tamper with sibling findings or the report.
3. **Persist session files for the audit trail** where disclosure review requires them (§11), but keep specialist/exploit sessions out of any directory another tier can write or read.
4. **Test the tool allowlist as a security control** — extend §9.5/§9.6 with assertions that: specialist sessions cannot invoke shell/write/edit tools (`session.getActiveToolNames()`); the Exploit Agent cannot reach MCP or the kernel tree; the toolkit remains read-only.
5. **If Option E (pi-subagents) is used, coverage must not depend on the LLM** — the host generates the batch list deterministically, the Orchestrator cannot add/drop batches, and the regression suite asserts dispatched tasks ≡ planned batches. A dispatch mechanism the model can silently shrink is a false-negative machine.

### Security-per-effort observation

The biggest jump in security per unit of effort is **Option A + strict tool allowlists**, not container sprawl. Container-per-agent buys real blast-radius reduction for the Exploit tier, but for read-only detection agents it mostly buys operational complexity that a well-tested allowlist already provides.

---

## 8. Comparison at a glance

| | A: 1 process, 1 container | B: 1 process/agent, 1 container | E: pi-subagents extension | C: 1 container/agent | D: sandbox/VM per agent |
|---|---|---|---|---|---|
| Isolation | ⚠️ weakest | ⚠️ process-level | ✅ process-level, per-invocation context | ✅ container-level | ✅✅ strongest |
| Communication | ✅ in-process | ✅ stdout JSON | ✅ tool call; ⚠️ one-shot, no steering | ⚠️ network + MCP bridge | ⚠️ network + file transfer |
| Orchestration | ✅ trivial (host code) | ✅ simple pool (host code) | ✅✅ least code; ⚠️ LLM-driven dispatch | ⚠️ compose/k8s | ⚠️ lifecycle mgmt |
| Coverage determinism | ✅ host-controlled | ✅ host-controlled | ⚠️ needs mitigation (§6) | ✅ host-controlled | ✅ host-controlled |
| Budget kill / steering | ✅ `abort()`, `steer()` | ⚠️ SIGKILL only | ⚠️ SIGKILL only; ✅ per-task cost stats | ⚠️ SIGKILL or RPC | ⚠️ SIGKILL |
| Shared toolkit cache | ✅ in-process | ⚠️ per-process MCP | ⚠️ per-subprocess MCP; needs shared backend | ⚠️ needs bridge | ⚠️ needs bridge |
| Determinism pinning | ✅ 1 image | ✅ 1 image | ✅ 1 image (+ forked extension pin) | ⚠️ N images | ⚠️ N images + VMs |
| Horizontal scaling | ⚠️ within host | ⚠️ within host | ⚠️ within host | ✅ across hosts | ✅ but costly |
| Ops complexity | ✅ lowest | ✅ low | ✅ low | ⚠️ medium | ⚠️ high |
| Best for | Detection tier (max control) | Detection tier (Python driver) | Detection tier (minimal code, with mitigations) | Exploit tier, scale-out | Validation tier (already VMs) |

---

*Update history: Option E (pi-subagents extension) added after initial A–D evaluation.*

---

*Companion document to `lpes_specs.md`. Update §5.4 (toolchain), §9.5/§9.6 (tests), and §11 (security notes) of the specs if the recommended tiered hybrid is adopted.*
