# LPES — Linux Privilege-escalation Scrutinizer

## Detailed Specifications for an Agentic System to Detect Linux Kernel Privilege-Escalation Vulnerabilities from Source Code and Generate Exploit Proofs of Concept

---

## 1. Overview

### 1.1 Problem statement

The Linux kernel is the most security-critical component of a Linux system. A single bug in kernel code can allow an unprivileged user to escalate to `root` (UID 0), compromising the entire machine. These bugs are found by manually auditing millions of lines of C code — a slow, expensive, and incomplete process.

**LPES** (Linux Privilege-escalation Scrutinizer) is an agentic system that reads Linux kernel source code and automatically detects potential privilege-escalation vulnerabilities. It uses a team of specialized AI agents, each covering a class of vulnerability, coordinated by an orchestrator. Each agent has deep expertise in one vulnerability pattern and uses a shared toolkit of static-analysis, data-flow, and code-search tools.

LPES also supports opt-in generation of exploit proof-of-concept (PoC) source code for verified findings, to help authorized researchers reproduce vulnerabilities and assess their impact. Detection remains source-only; compiling and executing generated exploits is a separate, explicitly approved validation workflow in disposable virtual machines.

### 1.2 Goals

| # | Goal | Success metric |
|---|---|---|
| G1 | Detect known classes of kernel privesc bugs from source alone | ≥ 60% recall on a held-out set of historical CVEs |
| G2 | Minimize false positives | ≥ 50% precision on the same set |
| G3 | Produce actionable, file:line-level reports | Every finding cites the exact line and the vulnerable data path |
| G4 | Scale source detection to the full kernel (~40 MLoC) | Complete source detection and reporting in ≤ 12 hours on 16 vCPUs; optional PoC generation/validation budgeted separately |
| G5 | Detect vulnerabilities without a compiled binary or runtime | Detection requires only source; no need for `vmlinux`, BTF, or a running kernel |
| G6 | Generate exploit PoC source code for verified findings in authorized research environments | On a curated, held-out subset with reproducible lab images, ≥ 50% of eligible findings yield PoCs that reproduce the documented security impact; report generation coverage and runtime validation separately |

G6 includes demonstrating privilege escalation where feasible, not just triggering a crash. A trigger, crash, or sanitizer report alone must never be labeled successful privilege escalation. Generation is best-effort: unsupported findings and failed attempts remain visible with reasons, and do not invalidate an otherwise verified source finding.

### 1.3 Non-goals

- Autonomous exploit deployment against production systems or systems without explicit authorization.
- Weaponization features such as persistence, stealth, or post-exploitation payloads.
- General-purpose fuzzing or dynamic vulnerability discovery; optional execution of generated PoCs is limited to validating already verified findings.
- Detection of non-privesc bugs (e.g., denial-of-service that does not escalate privileges).
- Applying patches automatically; LPES reports findings, recommends fixes, and optionally generates exploit PoCs.

### 1.4 Key design principle

**Deterministic engineering + agentic reasoning.** Each vulnerability class is handled by a dedicated agent with a purpose-built prompt, a constrained toolset, and a deterministic retrieval pipeline. The agent's job is *judgment*: confirm or reject a candidate surfaced by engineering logic. This mirrors the approach proven by Open Code Review and avoids the "hallucinated location" and "incomplete coverage" failure modes of purely LLM-driven review.

---

## 2. Threat model and vulnerability taxonomy

LPES targets vulnerabilities that let an **unprivileged user** (UID ≥ 1000, no capabilities) gain **kernel-level code execution** or **arbitrary read/write** to kernel memory, which is equivalent to root. We do **not** target bugs that require `CAP_SYS_ADMIN` or root to trigger.

### 2.1 Vulnerability classes

Each class maps to one specialist agent (Section 4).

| ID | Class | Canonical pattern | Example CVE |
|---|---|---|---|
| C1 | Use-after-free | Object freed, then accessed via dangling pointer; often refcount or RCU misuse | CVE-2024-1086 (nf_tables) |
| C2 | Double-free / invalid-free | Object freed twice, or freed on an error path that didn't own it | CVE-2022-32250 (openvswitch) |
| C3 | Heap buffer overflow | `kmalloc`'d buffer written past its size via unchecked index or `copy_from_user` length | CVE-2023-32233 (nf_tables) |
| C4 | Stack buffer overflow | Fixed-size stack array written via `copy_from_user` or `sprintf` | CVE-2010-3849 (netfilter) |
| C5 | Integer overflow → small alloc | `size = a + b` overflows, `kmalloc(size)` allocates too little, subsequent write overflows | CVE-2016-0728 (keyrings) |
| C6 | Uninitialized variable | Heap/stack variable read before assignment; `kmemdup` of uninitialized padding leaks kernel data | CVE-2024-50264 (separate class, but pattern overlaps) |
| C7 | Race condition / TOCTOU | Check-then-use across a dropped lock or `copy_from_user` followed by revalidation | CVE-2024-0582 (io_uring) |
| C8 | Missing / wrong capability check | `ioctl`/`setsockopt` handler reaches privileged operation without `capable(CAP_*)` or with wrong cap | CVE-2024-41055 (hidraw) |
| C9 | Missing permission check | `proc`/`sysfs`/`debugfs` write handler or `ioctl` lacks UID/EUID equality or `inode_permission` | CVE-2022-4378 (low-angle, but same pattern) |
| C10 | User-controlled format string | `printk(user_string)` or `snprintf(buf, len, fmt_from_user)` | (historical class) |
| C11 | Arbitrary kernel write via `setxattr`/`copy_from_user` into pointer | `copy_from_user` destination computed from user-supplied offset | CVE-2023-0386 (fuse + overlayfs) |
| C12 | Refcount overflow / underflow | `get_uid`/`put_uid`, `get_file`/`fput`, `kref_get`/`kref_put` imbalance | CVE-2019-11487 (refcount) |
| C13 | Type confusion | `container_of` on wrong type, or `void*` cast without runtime type check | (lateral class) |
| C14 | OOB read via unchecked user index | Array indexed by `copy_from_user`'d value without `>= 0 && < size` | CVE-2024-42076 (netfilter) |

### 2.2 Data sources (kernel-specific reachability)

An unprivileged user reaches kernel code through well-defined interfaces. LPES **must** trace from one of these entry points to confirm reachability:

| Interface | Examples | Header |
|---|---|---|
| `syscall` handlers | `SYSCALL_DEFINE*`, `__arm64_sys_*` | `<linux/syscalls.h>` |
| `ioctl` handlers | `.unlocked_ioctl`, `.compat_ioctl` | `<linux/fs.h>` |
| `setsockopt`/`getsockopt` | `nf_sockopt`, `sock->ops->setsockopt` | `<linux/net.h>` |
| Netfilter hooks | `nf_register_net_hook`, `nft_*` expressions | `<linux/netfilter.h>` |
| Netlink handlers | `.doit`, `.dumpit` in `genl_ops`/`nlmsg` | `<linux/netlink.h>` |
| `proc`/`sysfs`/`debugfs` write ops | `.write`, `.proc_write` | `<linux/proc_fs.h>` |
| `eBPF` helpers | `BPF_CALL_*`, `bpf_*_helper` | `<linux/bpf.h>` |
| Character device `.write`/`.ioctl` | `file_operations` | `<linux/fs.h>` |
| `io_uring` op handlers | `io_*` in `io_uring.c` | `<linux/io_uring.h>` |

LPES will **not** report a finding unless a path exists from one of these entry points to the vulnerable statement **with no intervening `capable()`/`ns_capable()`/permission check that blocks an unprivileged user**.

---

## 3. System architecture

### 3.1 High-level diagram

```
                       ┌─────────────────────────────────────┐
                       │          Orchestrator Agent          │
                       │  (planner, scheduler, deduper,      │
                       │   final triage & ranking)            │
                       └───────┬───────────────┬─────────────┘
                               │               │
              ┌────────────────┘               └────────────────┐
              ▼                                                 ▼
┌──────────────────────┐                          ┌──────────────────────────┐
│  Retrieval Pipeline  │                          │   Specialist Agents (×14) │
│  (deterministic)     │                          │  C1..C14 (one per class)  │
│                      │                          │                           │
│ • CPG builder        │  candidates ───────────► │  Each agent:              │
│ • Call graph         │                          │   • receives candidates   │
│ • Def-use / taint     │                          │   • uses shared toolkit   │
│ • Pattern queries     │                          │   • confirms/rejects      │
│ • Source indexer      │                          │   • emits structured FV   │
└──────────────────────┘                          └─────────────┬────────────┘
                                                                 │
                                                                 ▼
                                              ┌──────────────────────────────┐
                                              │     Verifier Agent            │
                                              │  • reachability check        │
                                              │  • dedupe against KB         │
                                              │  • confidence scoring        │
                                              │  • suppress known/fixed      │
                                              └─────────────┬────────────────┘
                                                            │
                                                            ▼
                                              ┌──────────────────────────────┐
                                              │   Report Agent               │
                                              │  • dedupe across classes     │
                                              │  • rank by severity          │
                                              │  • write LPES_REPORT.json +  │
                                              │    LPES_REPORT.md            │
                                              └──────────────────────────────┘
```

With exploit generation enabled, verified findings pass through the Exploit Agent before final reporting. Optional runtime validation is performed by a separately authorized VM runner, not by the source-analysis toolkit. Both stages attach artifacts and status to findings; failure in either stage must not prevent reporting.

### 3.2 Components

| Component | Implementation | Runs as | Stateful? | Key external tools (§5.4) |
|---|---|---|---|---|
| **Orchestrator Agent** | LLM (long-context, tool-use) | One process | Yes (plan, budget) | none (MCP client only) |
| **Retrieval Pipeline** | Python + Tree-sitter + custom pass + SAST adapters | Batch, before agents | No | Tree-sitter, ripgrep, Semgrep, Coccinelle, Smatch, Sparse, graphlib/Neo4j |
| **Specialist Agents** (14) | LLM, one per vulnerability class | Parallel subprocesses | No (stateless per candidate) | shared toolkit via MCP; per-class SAST rules (§4.2.3) |
| **Verifier Agent** | LLM + deterministic reachability | One process | No | toolkit: `find_entry_points`, `check_capability`, `sast_check` |
| **Exploit Agent** | LLM + constrained artifact writer; opt-in | Isolated worker per finding | No | none (writer only); advisory linting happens in validation |
| **PoC Validation Runner** | Allowlisted build/run harness; separately approved | Disposable VM per attempt | Yes (logs and results) | QEMU/KVM, gcc/clang, `clang --analyze` + `cppcheck` advisory checks |
| **Report Agent** | LLM | One process | No | none |
| **Shared Toolkit** | MCP server exposing code-search + CPG + SAST queries | One server | No | ripgrep, Tree-sitter, Semgrep, Coccinelle, Smatch, Sparse, Clang SA, CodeQL (opt.), graphlib/Neo4j |
| **Knowledge Base (KB)** | SQLite + JSON: historical CVEs, false-positive patterns | On-disk | Yes | SQLite |
| **Storage** | Working dir with `kernel_src/`, `index/`, `findings/`, `reports/` | Filesystem | Yes | none |

### 3.3 Execution flow

```
1.  Ingest kernel source         →  Retrieval Pipeline
2.  Build CPG + call graph        →  Retrieval Pipeline
3.  Run pattern queries           →  Retrieval Pipeline  →  candidates.jsonl
4.  Plan: partition candidates    →  Orchestrator
5.  Dispatch to specialists        →  Orchestrator → 14× Specialist Agents (parallel)
6.  Each specialist:              →  Specialist Agent
      a. read candidate context
      b. call toolkit (expand func, trace taint, check perms)
      c. confirm / reject
      d. emit Finding (or not)
7.  Verify each finding:          →  Verifier Agent
      a. reachability from entry point
      b. dedupe vs KB
      c. confidence score
8.  Generate exploit PoC source   →  Exploit Agent (opt-in; verified findings only)
9.  Build/run PoC in isolated VM  →  PoC Validation Runner (separate approval; optional)
10. Aggregate + rank + report     →  Report Agent
11. Write LPES_REPORT.md + .json   →  Report Agent (include PoC artifacts and status)
```

---

## 4. Agents

### 4.1 Orchestrator Agent

**Role:** Plan the scan, budget LLM calls, partition candidates across specialists, and perform final triage.

**Inputs:**
- `kernel_version` (e.g. `v6.10`)
- `candidates.jsonl` from the retrieval pipeline
- KB snapshot (known CVE IDs to suppress)

**Responsibilities:**
1. Load candidates and group by `(vulnerability_class, source_file)`.
2. Estimate token budget per specialist: `tokens ≈ candidates × avg_context_per_candidate`.
3. Partition candidates so each specialist batch fits the model context window (256 K tokens). Overlap batches by 1 function on either side to avoid boundary miss.
4. Dispatch batches to specialist agents with a per-batch prompt template.
5. Collect `Finding` records; forward to Verifier.
6. Track overall progress; abort a specialist if it exceeds 2× expected tool-call count.
7. When enabled, dispatch verified, non-suppressed findings to the Exploit Agent with a separate token budget. Never dispatch findings produced with `--no-verify`.
8. Request runtime validation only with explicit approval and a pinned lab image; preserve failures, timeouts, and skipped attempts in the final report.

**Model requirements:** Long-context (≥ 200 K tokens), strong tool-use, low hallucination. Configure `model_provider` and `model_name` explicitly; no specific provider is required.

**System prompt (excerpt):**

```
You are the orchestrator of LPES, a system that detects Linux kernel
privilege-escalation vulnerabilities. You do NOT analyze code yourself.
You plan, dispatch, and triage. You emit one JSON plan record per batch:

{"batch_id": "...", "class": "C1", "candidates": [...], "specialist": "C1-agent"}
```

### 4.2 Specialist Agents (C1–C14)

Each specialist covers exactly one vulnerability class. They share the same architecture but differ in their **prompt**, **pattern queries**, and **confirmation checklist**.

#### 4.2.1 Common specialist architecture

**Inputs (per batch):**
- `class_id` (e.g. `C1`)
- `candidates`: list of `(file, function, line_range, pattern_match_evidence)`
- Shared toolkit (MCP)

**Outputs:** Zero or more `Finding` records (JSON):

```json
{
  "finding_id": "LPES-2026-0001",
  "class": "C1",
  "title": "Use-after-free in nf_tables via NFT_MSG_NEWRULE race",
  "file": "net/netfilter/nf_tables_api.c",
  "function": "nf_tables_newrule",
  "lines": [3420, 3475],
  "severity": "critical",
  "confidence": 0.82,
  "entry_points": ["netlink: NFT_MSG_NEWRULE (unprivileged via unshare(CLONE_NEWUSER) + nft)"],
  "evidence": [
    {"kind": "free",     "file": "...", "line": 3440, "snippet": "kfree(rule);"},
    {"kind": "use",      "file": "...", "line": 3461, "snippet": "nft_rule_expr(rule, i);"},
    {"kind": "lock_drop","file": "...", "line": 3455, "snippet": "mutex_unlock(&nft_mutex);"}
  ],
  "data_path": "copy_from_user → NFT_MSG_NEWRULE → nf_tables_newrule → kfree(rule) → ... → nft_rule_expr(rule)",
  "capability_check": "none; reachable via unprivileged user netlink",
  "cve_match": null,
  "reasoning": "rule is freed at L3440 on the error path, but the error path at L3461 iterates the same rule via nft_rule_expr. The mutex is dropped between..."
}
```

**Shared toolkit (MCP server — Section 5):**

| Tool | Purpose |
|---|---|
| `read_file(path, start, end)` | Read a slice of a source file |
| `grep(pattern, glob, limit)` | Ripgrep over the kernel tree |
| `get_function(name)` | Return full body of a function by name |
| `get_callers(name)` | Who calls this function (call graph) |
| `get_callees(name)` | What this function calls |
| `taint_forward(var, file, line)` | Forward data-flow from a variable |
| `taint_backward(var, file, line)` | Backward data-flow to find sources |
| `find_entry_points(func)` | Is `func` reachable from an unprivileged entry point? Returns path or null |
| `check_capability(func)` | Does `func` or its callers invoke `capable()`/`ns_capable()`/`cap_raised`? |
| `cpg_query(cypher)` | Run a Cypher-like query against the CPG |
| `kbuild_context(file)` | Return the `Kconfig` + `Makefile` context (is the code built by default?) |
| `sast_check(tool, rule, target)` | Run a pinned external SAST query (Semgrep, Coccinelle, Smatch, Sparse, Clang Static Analyzer, CodeQL — §5.4) against a file or directory; returns structured matches `{file, line, rule, message}` |

**SAST corroboration rule:** specialists may call `sast_check` with their per-class rules (§4.2.3). SAST output is *corroborating evidence only*: a SAST hit never confirms a finding by itself, and a SAST miss never rejects one — the confirmation protocol below remains the only gate. Recall therefore depends on the deterministic queries plus LLM judgment, not on third-party rule coverage.

**Confirmation protocol (all specialists):**

Every specialist must answer these four questions before emitting a finding:

1. **Reachability:** Is the vulnerable statement reachable from an unprivileged entry point? Use `find_entry_points`. If null → reject.
2. **Capability gate:** Is there a `capable()`/`ns_capable()`/`inode_permission` check on the path that an unprivileged user cannot satisfy? If yes → reject (unless the check is bypassable, which must be justified).
3. **Trigger condition:** Can an unprivileged user supply the data that triggers the bug? Trace user-controlled data with `taint_backward`.
4. **Not already fixed:** Does the current source already contain a fix (e.g., the `kfree` is guarded by `if (rule)` or a refcount check)? If the fix is present → reject.

A finding is emitted only if all four answers support it.

#### 4.2.2 Per-class specialist definitions

For each class we specify: **trigger query** (what the retrieval pipeline searches for), **prompt focus** (what the LLM must reason about), and **confirmation checklist** (class-specific).

---

**C1 — Use-after-free specialist**

- *Trigger query (deterministic):* functions that call `kfree`/`kfree_rcu`/`kvfree`/`module_put`/`put_device`/`sock_put` and later dereference the same pointer, or call a function that reads through it, **within the same function or via a callee not protected by a refcount increment**.
- *Prompt focus:* "You are auditing for use-after-free. For each candidate, determine whether the freed object can be accessed again. Pay attention to: error-path frees that fall through to a use; RCU read-side accesses without `rcu_read_lock`; refcount increments that are missing on the `get` path; `list_del` without `list_del_init` followed by re-add."
- *Checklist:*
  1. Identify the free site and the use site.
  2. Verify no `kref_get`/`get_device`/`get_file`/`sock_hold` between them.
  3. Verify no `rcu_read_lock` + `synchronize_rcu` discipline that makes the use safe.
  4. Verify the error path from free to use does not `return` before the use.
  5. Confirm reachability.

---

**C2 — Double-free / invalid-free specialist**

- *Trigger query:* the same pointer is passed to a free-family function twice; or a pointer is freed on an `err:`/`out:` label that may be reached from a path that did not allocate it.
- *Prompt focus:* "You are auditing for double-free and invalid-free. Pay attention to `goto err` chains where an early `goto err` reaches a label that frees a pointer only allocated later. Look for `kfree(p)` at a label reachable when `p` is NULL or still owned by a caller."
- *Checklist:*
  1. Map every `goto` target and what is freed there.
  2. For each free at a label, enumerate all paths to that label and check ownership.
  3. Confirm reachability.

---

**C3 — Heap buffer overflow specialist**

- *Trigger query:* `kmalloc`/`kzalloc`/`vmalloc`/`kcalloc` whose size expression involves an arithmetic operation on a user-controlled length; `copy_from_user`/`memcpy` into a heap buffer with a length derived from `copy_from_user` of a separate field; `struct foo *p = kmalloc(sizeof(*p) + n * sizeof(X))` where `n` is user-controlled and unchecked.
- *Prompt focus:* "You are auditing for heap overflow. Compute the allocation size and the maximum write size. If the write can exceed the allocation, it's a finding. Pay attention to: `nla_for_each_attr` loops with user `n`; flexible-array members (`struct foo { ...; int data[]; }`) where the allocation uses `sizeof(*p)` without the flexible part; `copy_from_user` length equal to a user-supplied `len` without `len > X` check."
- *Checklist:*
  1. Determine allocation size expression.
  2. Determine max write size.
  3. Check for `if (len > ...) return -EINVAL;` guards.
  4. Check for `struct_size`/`array_size`/`kmalloc_array` (safe) vs raw `n * sizeof`.
  5. Confirm reachability.

---

**C4 — Stack buffer overflow specialist**

- *Trigger query:* `char buf[N]` on the stack with `copy_from_user(buf, ...)`/`sprintf`/`snprintf`/`strlcpy` from a user source; `__user` pointer used as format arg.
- *Prompt focus:* "Stack buffers are small and overflow corrupts the stack. Look for `copy_from_user(buf, src, len)` where `len` may exceed `sizeof(buf)`. Look for `sprintf` (unbounded) vs `scnprintf`."
- *Checklist:*
  1. `sizeof(buf)` vs `len`.
  2. Is `len` bounded before the copy?
  3. Is `sprintf` used instead of `scnprintf`/`snprintf`?

---

**C5 — Integer overflow → small alloc specialist**

- *Trigger query:* `kmalloc(a + b)`, `kmalloc(a * b)`, `vmalloc(n * size)` where `a`, `b`, or `n` are user-controlled and not wrapped in `array_size`/`struct_size`/`kmalloc_array`.
- *Prompt focus:* "Integer overflow in size computation leads to a tiny allocation and a subsequent heap overflow. Check whether `a + b` can wrap. The safe helpers `array_size`, `struct_size`, `kmalloc_array` perform overflow checks; their absence is a strong signal."
- *Checklist:*
  1. Identify the size expression.
  2. Are operands user-controlled or derived therefrom?
  3. Is an overflow-safe helper used? If not → candidate.
  4. After the (possibly small) alloc, is there a write sized by the original (pre-overflow) value? If yes → confirmed.

---

**C6 — Uninitialized variable specialist**

- *Trigger query:* `kmalloc` (not `kzalloc`) followed by `copy_to_user(to, p + offset, len)` where `offset + len > initialized_region`; `struct foo *p = kmalloc(...)` without `memset`/full initialization before `copy_to_user`.
- *Prompt focus:* "Uninitialized heap memory leaked to userspace via `copy_to_user` is an info leak; if the leak reveals kernel pointers it defeats KASLR and is a privesc enabler. Look for `kmalloc` + partial initialization + `copy_to_user` of the whole object."
- *Checklist:*
  1. Allocation: `kmalloc` vs `kzalloc`?
  2. Which fields are initialized before the copy?
  3. Does `copy_to_user` copy beyond the initialized region?
  4. Is the struct padded? Padding is uninitialized in `kmalloc`.

---

**C7 — Race condition / TOCTOU specialist**

- *Trigger query:* `copy_from_user` into a struct, then a re-validation or use after a lock drop; `access_ok` then `get_user` without recheck; `mutex_lock` → `copy_from_user` → `mutex_unlock` → use; `list_for_each_entry_safe` without holding the list lock across the whole loop body.
- *Prompt focus:* "Time-of-check-to-time-of-use. The classic kernel pattern: validate a user pointer or struct, drop a lock, then re-use the value which the user may have changed in between (via `userfaultfd` or two racing `ioctls`)."
- *Checklist:*
  1. Where is the value checked?
  2. Where is it used?
  3. Is a lock held continuously between check and use?
  4. Can the value be re-fetched from userspace between check and use (`get_user` twice, or `copy_from_user` then re-read)?
  5. Is `userfaultfd` a relevant reattack vector (slows the copy, lets a second thread mutate)?

---

**C8 — Missing capability check specialist**

- *Trigger query:* `ioctl`/`setsockopt`/`syscall` handler that performs a privileged action (sets system params, loads BPF, mounts, changes namespace, sets clock) without `capable(CAP_SYS_ADMIN)` etc.; or with `capable(CAP_SYS_NICE)` when `CAP_SYS_ADMIN` was intended.
- *Prompt focus:* "Does this operation require a capability, and is the right one checked? Cross-reference the operation against `Documentation/userspace-api/capabilities.rst`."
- *Checklist:*
  1. Identify the privileged operation (what does it modify?).
  2. Is any `capable()`/`ns_capable()`/`cap_raise` on the path?
  3. Is the capability the *correct* one for the operation?
  4. Is the check on the right namespace (`ns_capable(&init_user_ns, ...)` vs `ns_capable(current_user_ns(), ...)`)? The latter is reachable by unprivileged via `unshare(CLONE_NEWUSER)`.

---

**C9 — Missing permission check specialist**

- *Trigger query:* `proc_ops`/`proc_dir_ops`/`file_operations` `.write`/`.ioctl` that modifies global state without `capable()` or `inode_permission` or an explicit `uid_eq(current_fsuid(), inode->i_uid)`.
- *Prompt focus:* "Who can reach this handler, and is the write privileged? `proc`/`sysfs`/`debugfs` files are world-readable but should not be world-writable."
- *Checklist:*
  1. What mode is the file created with (`0644` vs `0666` vs `0200`)?
  2. Is there a permission check in the `.open`/`.write`?
  3. Does the write modify global kernel state?

---

**C10 — User-controlled format string specialist**

- *Trigger query:* `printk`/`snprintf`/`scnprintf`/`trace_printk` whose first non-constant argument is a `__user` string or a `char*` derived from `copy_from_user`.
- *Prompt focus:* "Format string vulnerability: `%n` writes, `%s` reads from an attacker pointer, `%x` leaks stack."
- *Checklist:*
  1. Is the format string a compile-time constant? If not → candidate.
  2. Is it user-controlled?
  3. `printk("%s", userstr)` is safe; `printk(userstr)` is not.

---

**C11 — Arbitrary kernel write via user offset specialist**

- *Trigger query:* `copy_from_user(kaddr + user_offset, ...)`; `put_user(val, (void __user *)(kernel_addr + off))` after a `get_user` of `off`; `setxattr` flows where the value is copied into a kernel structure field selected by user input.
- *Prompt focus:* "If a user controls the *destination* of a `copy_from_user`, they can write anywhere in kernel memory."
- *Checklist:*
  1. Is the destination address computed from user input?
  2. Is the offset bounds-checked?
  3. Is the destination a kernel address (not `__user`)?

---

**C12 — Refcount overflow / underflow specialist**

- *Trigger query:* `get_uid`/`put_uid`, `get_file`/`fput`, `kref_get`/`kref_put`, `sock_hold`/`sock_put`, `get_device`/`put_device` — count the `get` vs `put` on every path; `refcount_t` operations; `atomic_inc`/`atomic_dec` on a field named `*ref*`/`*count`/`*cnt`.
- *Prompt focus:* "A refcount that can be overflowed (to 0 via wrap) turns a UAF into a deterministically triggerable one. Underflow → premature free → UAF."
- *Checklist:*
  1. Enumerate every path and count `get` vs `put`.
  2. Is `refcount_t` (overflow-safe) or `atomic_t` (not)?
  3. Can the refcount wrap to 0 (32-bit overflow)?

---

**C13 — Type confusion specialist**

- *Trigger query:* `container_of(ptr, type, member)` where `type` differs from the type the pointer "logically" belongs to; `void*` casts between unrelated structs; union access of a different member than was stored; `list_entry`/`list_first_entry` on a list whose elements have heterogeneous types.
- *Prompt focus:* "If a `container_of` is used with the wrong type, fields after the common prefix are misinterpreted. Unions are dangerous if the writer and reader use different members."
- *Checklist:*
  1. What type was the object created as?
  2. What type does the `container_of`/cast assume?
  3. Are the layouts compatible up to the accessed fields?

---

**C14 — OOB read via unchecked user index specialist**

- *Trigger query:* array access `arr[idx]` where `idx` is user-controlled (`copy_from_user`) and not bounded; `array_index_nospec` absent; `min(idx, max)` guard absent.
- *Prompt focus:* "An unchecked user index gives a read (or write) past the array. The kernel provides `array_index_nospec` for speculative protection, but the bounds check itself must be present and correct."
- *Checklist:*
  1. Where is `idx` sourced?
  2. Is there a `if (idx >= max) return -EINVAL;`?
  3. Is the bound `max` the actual array size (not a larger related value)?
  4. For `copy_to_user` of `arr[idx]`: is it an info leak in addition to OOB?

#### 4.2.3 Per-class SAST dependency tools

Each specialist is backed by a pinned set of external static-analysis tools, invoked through `sast_check`. These tools (a) run during retrieval to seed candidates (§6.1) and (b) are callable by the specialist for corroboration. Per §4.2.1 they never gate a finding on their own.

| Class | Specialist | Primary SAST tools | Auxiliary tools | Contribution |
|---|---|---|---|---|
| C1 | Use-after-free | Smatch (UAF + cross-function analysis), Coccinelle (`scripts/coccinelle/free/`) | CodeQL CWE-416 | free-site/use-site pairs; refcount-discipline hints |
| C2 | Double-free / invalid-free | Coccinelle free-family rules | Smatch | duplicate frees; ownership at `err:` labels |
| C3 | Heap buffer overflow | Semgrep kernel heap-overflow rules, CodeQL CWE-122 | Coccinelle size-expression checks | alloc-size vs write-size mismatch |
| C4 | Stack buffer overflow | Semgrep `sprintf`/`copy_from_user`-to-stack rules | CodeQL stack-buffer queries, Clang SA stack checks | unbounded copies into fixed stack buffers |
| C5 | Integer overflow → small alloc | Coccinelle `array_size`/`struct_size`-absence checks | CodeQL CWE-190, Semgrep | overflowing size expressions lacking safe helpers |
| C6 | Uninitialized variable | Clang Static Analyzer (`core.uninitialized`) | Sparse, Coccinelle `kmalloc`-init checks | reads before assignment; partial init + `copy_to_user` |
| C7 | Race / TOCTOU | Smatch lock-state tracking | Coccinelle (`scripts/coccinelle/locks/`), CodeQL TOCTOU queries | check/use pairs across dropped locks |
| C8 | Missing capability check | Coccinelle capability rules, Semgrep ioctl-without-`capable()` rules | CodeQL capability-gated reachability | privileged ops lacking the correct `capable()` |
| C9 | Missing permission check | Semgrep proc/sysfs write rules | Coccinelle file-ops patterns | world-writable handlers modifying global state |
| C10 | Format string | Semgrep format-string rules | Coccinelle `printk` checks, GCC `-Wformat-security` build flags | non-constant format strings from `__user` data |
| C11 | Arbitrary write via user offset | CodeQL taint tracking (`__user` → pointer-arithmetic sink) | Smatch | user-controlled `copy_from_user` destinations |
| C12 | Refcount overflow/underflow | Coccinelle (`scripts/coccinelle/refcount/`) | Clang `refcount_t` checkers, Smatch | `get`/`put` imbalance per path |
| C13 | Type confusion | CodeQL type-hierarchy/cast queries | Sparse type checking | `container_of`/union/`void*` mismatches |
| C14 | OOB read via user index | CodeQL range analysis (CWE-129), Smatch bounds checks | Semgrep array-index rules | user index lacking a correct bounds check |

Rules live in `lpes/retrieval/sast_rules/` (Semgrep YAML, `.cocci` files, pinned Smatch/Sparse/Clang-SA invocation flags). CodeQL is optional and feature-gated from P3 (license + per-scan DB-build cost, §12); all other tools are part of the pinned toolchain container (§5.4).

### 4.3 Verifier Agent

**Role:** Confirm each finding from the specialists by re-checking the four confirmation questions independently, dedupe against the KB, and assign a confidence score.

**Inputs:** `Finding` records from specialists; KB (historical CVE signatures).

**Process:**
1. Re-run `find_entry_points(vulnerable_function)`; reject if no path.
2. Re-run `check_capability(vulnerable_function)`; reject if a blocking capability check exists and the specialist didn't justify its bypass.
3. Compute a structural similarity to each KB entry (file basename match + function-name token overlap + class match). If similarity > 0.85 and the KB entry is marked `fixed_in >= current_version`, mark the finding `suppressed: already_fixed`.
4. Confidence score:
   ```
   confidence = 0.4 × specialist_confidence
              + 0.3 × reachability_confidence
              + 0.2 × capability_confidence
              + 0.1 × (1 - kb_similarity_if_fixed)
   ```
5. Drop findings with confidence < 0.5.
6. Optionally re-run the class's primary SAST rule via `sast_check` (§4.2.3) for corroboration. A SAST miss is recorded in `verifier_notes` but does not by itself reject a finding; a SAST hit never substitutes for steps 1–4.

**Output:** Verified findings with `verifier_notes` and final `confidence`.

### 4.4 Report Agent

**Role:** Aggregate, dedupe across classes, rank, and write the final report.

**Dedup rule:** Two findings are duplicates if they share the same `(file, function, primary_line)` and the same root cause (judged by the LLM with the evidence snippets). Keep the higher-confidence one and merge `evidence` arrays.

**Ranking:** Sort by `(severity, confidence)`:
- `critical`: arbitrary kernel write or UAF reachable unprivileged.
- `high`: info leak of kernel pointer + OOB read.
- `medium`: DoS-only or requires unusual but unprivileged setup.
- `low`: theoretical, weak reachability.

**Exploit reporting:** Include links to generated source and instructions, generation/validation status, prerequisites, and observed impact. Clearly distinguish source verification, PoC generation, successful compilation, bug triggering, and demonstrated privilege escalation. Never infer runtime success from generated code or model reasoning alone.

**Outputs:**

`LPES_REPORT.md` (human-readable):

```markdown
# LPES Report — kernel v6.10

Scanned: 2026-11-13T14:00Z
Findings: 23 (critical: 3, high: 7, medium: 9, low: 4)
Suppressed as already-fixed: 11

## Critical

### LPES-2026-0001 — Use-after-free in nf_tables_newrule
- **Class:** C1 (Use-after-free)
- **File:** net/netfilter/nf_tables_api.c:3420–3475
- **Confidence:** 0.82
- **Reachability:** netlink NFT_MSG_NEWRULE, reachable via unprivileged user netlink (unshare CLONE_NEWUSER)
- **Capability gate:** none
- **Evidence:**
  1. L3440 `kfree(rule);`
  2. L3461 `nft_rule_expr(rule, i);`
  3. L3455 `mutex_unlock(&nft_mutex);`
- **Root cause:** On the error path, `rule` is freed, then the error-handling loop iterates `rule` to roll back expressions.
- **Recommended fix:** Use a separate `goto` label that does not touch `rule` after the free, or set `rule = NULL` after `kfree`.
- **Possible CVE match:** none (appears novel)
```

`LPES_REPORT.json` (machine-readable): the full list of verified findings, suppressed findings, scan metadata, timing stats, and exploit outcomes including the embedded PoC source (`exploit.poc`) and artifact references.

### 4.5 Exploit Agent

**Role:** Generate minimal, reviewable exploit PoC source code for a verified finding, including a privilege-escalation demonstration where feasible. Exploit generation is opt-in and must not weaken source-verification requirements.

**Inputs:** Verified, non-suppressed `Finding`; relevant source and evidence; pinned kernel commit, architecture, configuration, and mitigation assumptions; optional approved lab-image manifest.

**Responsibilities:**
1. Explain the relationship between the vulnerable path, trigger conditions, and intended security impact. Record unknown prerequisites rather than inventing offsets, symbols, or runtime observations.
2. Generate PoC source plus build/run instructions, expected observations, dependencies, limitations, and potential crash/data-loss warnings. Use a minimal local impact demonstration rather than a persistent payload.
3. Write artifacts only through a constrained writer rooted at `<out>/exploits/<finding_id>/`; no arbitrary filesystem writes, shell execution, or changes to the kernel source tree.
4. Emit `generated`, `unsupported`, or `failed`, with reasons and artifact references. Code is labeled unvalidated until an external validation result is attached.
5. Stop at configured attempt and token limits. Never suppress a verified finding merely because exploit generation fails.

**Artifact bundle:** `poc.c` (or another explicitly declared source entrypoint), `README.md`, and `manifest.json`. The manifest records the finding ID, source hashes, target kernel commit/configuration, architecture, prerequisites, expected impact, and generation status. Build/run logs and observed outcomes are added only by the validation runner. In addition, the Exploit Agent embeds the full content of every bundle file (path, SHA-256, entrypoint, build/run instructions) into the finding's `exploit.poc` field (§8.3); the embedded copy is canonical and must match the on-disk bundle byte-for-byte.

**Optional validation:** A separately approved deterministic runner builds and executes reviewed artifacts in a disposable VM booted into the pinned target kernel. The trigger process starts as an unprivileged user under the threat model in §2; privileged VM provisioning is not evidence of escalation. Capture initial/final credentials, exit status, serial/kernel logs, and evidence for the claimed impact. A crash or observed memory error is `triggered`; `impact_demonstrated` requires evidence of the stated privilege gain or security primitive. Compilation alone is `built`, never successful exploitation. Failed, inconclusive, and timed-out runs retain their logs and reasons. Host/container execution is prohibited because containers share the host kernel.

---

## 5. Shared Toolkit — MCP server

The toolkit is an MCP server (Model Context Protocol) exposing the tools in §4.2.1. Specialists call it via standard MCP tool-use.

### 5.1 Implementation

| Tool | Backing implementation |
|---|---|
| `read_file` | Direct file read (Pi `read`-style, with offset/limit) |
| `grep` | `ripgrep` over the kernel tree |
| `get_function` | Tree-sitter C parser; function-name → body + line range |
| `get_callers`/`get_callees` | Pre-computed call graph (from Tree-sitter + `scripts/tags.sh`-style indexing) |
| `taint_forward`/`taint_backward` | Lightweight intra-procedural def-use via Tree-sitter; inter-procedural via call-graph expansion (depth ≤ 3) |
| `find_entry_points` | Backward call-graph BFS from the function to any entry-point set member (§2.2); returns the path or null |
| `check_capability` | Regex + call-graph: does any caller-or-callee on the path contain `capable(`, `ns_capable(`, `cap_raise`, `has_capability`? |
| `cpg_query` | A Code Property Graph (AST + call graph + def-use edges) stored in a graph DB (Neo4j or in-process `graphlib`); Cypher-subset queries |
| `kbuild_context` | Parse nearest `Kconfig` and `Makefile`; return whether the file is built by `defconfig` and which `CONFIG_*` gates it |
| `sast_check` | Adapter subprocess over the pinned SAST binaries (§5.4); translates `(tool, rule, target)` into a fixed-flag invocation, normalizes findings to `{file, line, rule, message}`, enforces a 60 s per-call timeout and a kernel-tree read-only, offline execution policy |

### 5.2 Performance budget

- `find_entry_points` is the most expensive tool (BFS). Cap depth at 8 call levels. Cache results keyed by `(function, kernel_version)`.
- All tools return within 5 seconds for any single query; `taint_*` capped at 3 inter-procedural hops.
- The MCP server runs as a single process; specialists are rate-limited to 10 concurrent tool calls each.

The artifact writer and VM runner are separate from this read-only MCP server. Source-analysis agents do not gain execution or write permissions when exploit generation is enabled.

### 5.3 Determinism

The toolkit is **deterministic** (no LLM). This guarantees that two specialists auditing the same function see identical tool outputs, which makes findings reproducible and testable.

### 5.4 External toolchain and dependency matrix

All components run from a single pinned, hash-verified toolchain container. Every tool below is invoked with a fixed version and fixed flags so results are reproducible (§5.3). Tools marked *optional* are feature-gated by phase (§12) or license.

| Tool | Pinned to | License | Used by | Role |
|---|---|---|---|---|
| Tree-sitter | ≥ 0.22 | MIT | Retrieval, toolkit | C AST parsing for the CPG and `get_function` |
| ripgrep | ≥ 14 | MIT / Unlicense | Toolkit | `grep` tool |
| Semgrep | ≥ 1.90 | LGPL-2.1 (engine) | Retrieval step 8; specialists C3, C4, C8, C9, C10, C14 | rule-based pattern queries (`sast_rules/semgrep/`) |
| Coccinelle | ≥ 1.3 | GPL-2.0 | Retrieval; specialists C1, C2, C5, C7, C8, C9, C12 | semantic patches over kernel idioms (`.cocci` rules) |
| Smatch | kernel-tree revision | GPL-2.0 | Retrieval; specialists C1, C2, C7, C11, C14; Verifier | kernel-aware cross-function checks (UAF, locks, bounds) |
| Sparse | kernel-tree revision | MIT-0 | Specialists C6, C10, C13 | type checking, `__user` annotation discipline |
| Clang Static Analyzer | LLVM pin | Apache-2.0 | Specialists C4, C6, C12 | uninitialized-value, stack, and `refcount_t` checks |
| CodeQL *(optional)* | ≥ 2.17 | GitHub license | Specialists C1, C3, C11, C13, C14; Verifier | deep taint tracking, range analysis, type hierarchy |
| graphlib / Neo4j | per §5.1 | in-process / proprietary | Toolkit | CPG storage behind `cpg_query` |
| SQLite | ≥ 3.40 | Public domain | KB | CVE / false-positive / fix-pattern store |
| GCC + Clang | distro pins | GPL-2.0 / Apache-2.0 | PoC Validation Runner | advisory build + lint of generated PoCs (`-Wall -Wextra`, `clang --analyze`, `cppcheck`) |
| QEMU/KVM *(optional)* | pinned | GPL-2.0 | PoC Validation Runner | disposable target VMs |

Constraints:

- Only the toolkit MCP server and the retrieval pipeline invoke SAST binaries; agents never execute tools directly (no shell access, §11).
- Every SAST invocation is offline, read-only against the kernel tree, file-scoped, and time-boxed. A tool failure returns an explicit error, never an empty result — so "clean" is distinguishable from "did not run".
- Tool results are cached by `(tool, version, rule, target_hash)` and shared across specialists, making corroboration calls effectively free.

---

## 6. Retrieval Pipeline (deterministic)

This runs **before** any agent and produces `candidates.jsonl`. It is the engineering side of the "deterministic engineering + agentic reasoning" split.

### 6.1 Steps

1. **Parse.** Tree-sitter parses every `.c`/`.h` in the tree. Output: AST + symbol table.
2. **Build call graph.** Resolve function calls to definitions where possible. Record `(caller, callee, call_site_line)`.
3. **Build def-use.** Per function, compute def-use chains for every local variable and parameter.
4. **Index `__user` annotations.** Record every `copy_from_user`, `get_user`, `strncpy_from_user`, `import_single_range`, etc.
5. **Index frees.** Record every `kfree`, `kfree_rcu`, `kvfree`, `kmem_cache_free`, `module_put`, `put_device`, `sock_put`, `fput`, `kref_put`.
6. **Index locks.** Record `mutex_lock`, `mutex_unlock`, `spin_lock`, `rcu_read_lock`, `rcu_read_unlock`, `read_lock`, `write_lock`.
7. **Index caps.** Record `capable`, `ns_capable`, `cap_raise`, `has_capability`, `security_*`.
8. **Run pattern queries.** For each class C1..C14, run the trigger query (§4.2.2) as a CPG query, plus the class's SAST rules (§4.2.3) through the `sast_check` adapters (Semgrep / Coccinelle / Smatch / Sparse / Clang SA). Merge results and dedupe on `(class, file, function, primary_line)`. Emit a candidate per match:
   ```json
   {"class":"C1","file":"...","function":"...","lines":[a,b],"evidence":[...],"query_id":"C1-q3"}
   ```
9. **Write `candidates.jsonl`.** Grouped by class for the Orchestrator.

### 6.2 Why deterministic retrieval is critical

- It guarantees **coverage**: every `kfree` is examined; no LLM "skips" a file.
- It **reduces the agent's context**: the agent sees only candidates, not the whole tree.
- It makes false negatives attributable: a missed bug is a missing *query*, not a lazy agent, and the query can be fixed and re-run.

### 6.3 Performance

- Tree-sitter parse of the full tree: ~3 minutes on 16 vCPUs.
- CPG construction: ~8 minutes.
- Pattern queries: ~2 minutes.
- Total: ~15 minutes before the first agent runs.

---

## 7. Knowledge Base

### 7.1 Contents

| Table | Schema (SQLite) | Purpose |
|---|---|---|
| `cve` | `id TEXT, class TEXT, file TEXT, function TEXT, fixed_in TEXT, summary TEXT` | Historical CVEs for dedup and "already fixed" suppression |
| `false_positive` | `id TEXT, pattern TEXT, reason TEXT, source TEXT` | Known benign patterns (e.g., `kfree` under `if (p)` is safe) |
| `fix_pattern` | `class TEXT, pattern TEXT, fix TEXT` | Known fix shapes for the report's "recommended fix" field |

### 7.2 Seeding

The KB is seeded from:
- `linux-stable` CVE history (NVD `linux_kernel` CPE entries, last 5 years).
- Manual entries for the 14 classes (§2.1 example CVEs).
- False-positive patterns collected during LPES's own regression testing (§9).

### 7.3 Growth

Each scan appends new *verified* findings to `cve` (with `id = LPES-…`) so future scans can dedup against them. False positives confirmed by a human reviewer are appended to `false_positive`.

---

## 8. Interfaces

### 8.1 CLI

```bash
lpes scan --kernel /path/to/linux --version v6.10 \
          --provider model_provider --model model_name \
          --out reports/
```

Flags:

| Flag | Default | Purpose |
|---|---|---|
| `--kernel` | required | Path to kernel source tree |
| `--version` | `git describe` | Kernel version label for the report and KB |
| `--classes` | all 14 | Comma-separated subset (e.g. `C1,C3,C8`) |
| `--subsystem` | all | Limit to a subsystem path (e.g. `net/netfilter/`) |
| `--provider`/`--model` | env | LLM for the agents |
| `--budget` | 1_000_000 | Max LLM tokens for source detection and reporting; excludes the separate exploit budget |
| `--concurrency` | 8 | Parallel specialist processes |
| `--out` | `./reports` | Output directory |
| `--kb` | `./lpes_kb.sqlite` | Knowledge base path |
| `--resume` | none | Resume from a previous `scan_state.json` |
| `--no-verify` | off | Skip the Verifier (debugging); incompatible with exploit generation |
| `--generate-exploits` | off | Generate PoC source bundles for verified, non-suppressed findings; does not execute them |
| `--exploit-budget` | 200_000 | Additional maximum LLM tokens for PoC generation per scan |
| `--validate-exploits` | off | Requires `--generate-exploits`, explicit approval, and `--lab-manifest`; run reviewed PoCs only in disposable VMs |
| `--lab-manifest` | none | Approved VM image, target kernel commit/configuration, architecture, limits, and expected impact checks |

Invalid flag combinations must fail before starting the scan. Validation requires a positive approval decision; supplying an image path alone is not approval.

### 8.2 Output files

```
reports/
├── LPES_REPORT.md          # human-readable
├── LPES_REPORT.json        # machine-readable
├── candidates.jsonl         # retrieval pipeline output
├── findings.jsonl           # raw findings from specialists
├── verified.jsonl           # post-Verifier findings
├── scan_state.json          # resume state
├── timing.json              # per-stage timing
└── exploits/                # optional; restricted-access artifact bundles
    └── LPES-2026-0001/
        ├── poc.c
        ├── README.md        # prerequisites, build/run instructions, warnings
        ├── manifest.json    # target identity, hashes, generation status
        └── validation.json  # optional; outcomes and relative log paths
```

### 8.3 `Finding` JSON schema (canonical)

```json
{
  "$schema": "https://vulneraser.dev/lpes/finding.schema.json",
  "finding_id": "LPES-2026-0001",
  "class": "C1",
  "class_name": "Use-after-free",
  "title": "string",
  "file": "path/to/file.c",
  "function": "function_name",
  "lines": [start, end],
  "primary_line": 3440,
  "severity": "critical|high|medium|low",
  "confidence": 0.0,
  "entry_points": ["string"],
  "evidence": [
    {"kind": "free|use|lock|unlock|alloc|copy_from_user|capable|...", "file": "...", "line": 0, "snippet": "..."}
  ],
  "data_path": "source → ... → sink",
  "capability_check": "none|CAP_SYS_ADMIN|...",
  "cve_match": "CVE-YYYY-NNNN or null",
  "kb_status": "novel|already_fixed|known_fp",
  "recommended_fix": "string",
  "exploit": {
    "generation_status": "not_requested|generated|unsupported|failed",
    "artifact_dir": "relative/path/or/null",
    "poc": {
      "entrypoint": "poc.c or null",
      "source_files": [
        {"path": "poc.c", "sha256": "hex digest of content", "content": "full file source"}
      ],
      "build_run_instructions": "string or null"
    },
    "validation_status": "not_requested|not_run|built|triggered|impact_demonstrated|failed|inconclusive|timed_out",
    "intended_impact": "string or null",
    "observed_impact": "string or null",
    "validation_result": "relative/path/or/null",
    "reason": "string or null"
  },
  "reasoning": "string",
  "verifier_notes": "string",
  "scan_id": "uuid",
  "kernel_version": "v6.10",
  "timestamp": "ISO-8601"
}
```

**Embedded PoC source.** When `generation_status = "generated"`, the `exploit.poc` object stores the **complete source code of every file in the artifact bundle** inside the finding record: file path, full content, SHA-256 of the content, the declared entrypoint, and build/run instructions. The on-disk bundle under `exploits/<finding_id>/` is a byte-for-byte duplicate of this canonical copy. Consumers must verify `sha256(content) == sha256` and bundle equality before use. This makes `LPES_REPORT.json` self-contained: a verified finding and its PoC source travel together, survive relocation or deletion of the `reports/` tree, and remain auditable without the bundle directory. For every other `generation_status` value, `poc` is `null` and `reason` carries the explanation.

---

## 9. Testing and evaluation

### 9.1 Ground-truth dataset

Build `tests/corpus/` from historical CVEs with:
- The vulnerable version (pre-fix commit).
- The fix commit SHA.
- The class label.
- The expected `file:function:line`.

Target: ≥ 150 CVEs across the 14 classes, weighted by real-world frequency (C1, C3, C5, C7, C8, C14 dominate).

### 9.2 Metrics

| Metric | Definition | Target |
|---|---|---|
| Precision | TP / (TP + FP) | ≥ 0.50 |
| Recall | TP / (TP + FN) | ≥ 0.60 |
| Location accuracy | fraction of TP with `primary_line` within ±5 lines of the true fix | ≥ 0.70 |
| False-positive rate | FP / (FP + TN-candidates) | ≤ 0.10 per class |
| Scan time | wall clock for full tree | ≤ 12 h on 16 vCPUs |
| LLM cost | $ per full scan | ≤ $50 (with caching) |

### 9.3 Regression suite

`tests/regression/` runs LPES on each corpus CVE and checks:
1. `finding_id` exists for the expected `(file, function)`.
2. `class` matches the label.
3. `primary_line` is within ±5 of the fix commit's hunk.
4. No regression: findings that passed in a previous LPES version still pass.

### 9.4 False-positive harvest

Any finding rejected by a human reviewer is appended to `false_positive` with the rejecting reason. A follow-up test asserts the FP is not re-emitted on the next scan of the same code.

### 9.5 Unit tests for the toolkit

Each MCP tool has unit tests:
- `get_callers("nf_tables_newrule")` returns a non-empty set.
- `find_entry_points("nf_tables_newrule")` returns a path through netlink.
- `find_entry_points("some_internal_helper")` may return null.
- `taint_backward` on a known `copy_from_user` reaches the `__user` source.
- `sast_check("coccinelle", "refcount", file)` returns pinned, hash-comparable output; a tool-version drift must fail the test.

### 9.6 Exploit generation and validation

- Maintain a separate held-out subset with reproducible vulnerable/fixed kernel pairs and pinned VM manifests. Declare eligibility before generation; report exclusions and reasons to avoid cherry-picking.
- Measure generation coverage (generated bundles / eligible findings) and demonstrated-impact success (eligible findings with runtime-demonstrated intended impact / eligible findings). G6's ≥ 50% target uses the latter, including generation failures in the denominator.
- Track build success, trigger reproduction, privilege-escalation success, attempts, validation time, and generation cost separately. Repeat runtime trials and report success counts rather than claiming reliability from one run.
- Test that a PoC demonstrates the claimed impact on the vulnerable image and does not demonstrate it on the corresponding fixed image under the same conditions. A fixed-image reproduction requires investigation, not automatic success.
- Assert that disabled generation creates no exploit artifacts; unverified/suppressed findings are ineligible; unsafe artifact paths and missing approvals are rejected; failed/timed-out runs remain in reports.
- Assert that findings with `generation_status = "generated"` embed the complete PoC source in `exploit.poc`, and that each embedded file's SHA-256 matches both its declared hash and the on-disk bundle under `exploits/<finding_id>/`; deleting the bundle directory must leave `LPES_REPORT.json` fully self-contained.
- Verify VM isolation, absence of host execution, resource limits, unprivileged initial credentials, and artifact/log integrity. Treat generated source as untrusted even when static checks pass.

---

## 10. Performance and cost model

### 10.1 Token budget

Assume:
- ~80 000 candidate matches across the full tree (all 14 classes).
- ~2 000 tokens of context per candidate (function body + call graph snippets + tool outputs).
- Specialist visits ~3 candidates per batch of 1 (two are rejected).
- Total specialist input ≈ 80 000 × 2 000 = 160 M tokens. This is too much for a single pass; mitigation:

**Mitigations:**
1. **Subsystem scoping.** Most privesc bugs are in `net/`, `fs/`, `drivers/`, `kernel/`, `security/`. Default scan excludes `Documentation/`, `tools/`, `samples/`, `arch/` (except `x86`/`arm64` entry code). Cuts ~40%.
2. **Pre-filter by reachability.** Run `find_entry_points` deterministically during retrieval; drop candidates whose function is not reachable. Cuts ~60% of the remainder.
3. **Batching.** Specialists process ~20 candidates per LLM call (they share context). Cuts calls by 20×.
4. **Caching.** The toolkit cache (per `(function, version)`) is shared across specialists; repeat tool calls are free.
5. **Dedup.** Candidates that map to the same KB `cve` entry and are `fixed_in >= current_version` are suppressed before dispatch.

With mitigations, effective LLM input ≈ 160 M × 0.6 × 0.4 / 20 ≈ 1.9 M tokens. At ~$3/Mtok input + ~$15/Mtok output (Sonnet-class), a full scan costs ~$15–$30.

### 10.2 Wall-clock

- Retrieval pipeline: ~15 min (one-time, deterministic).
- Specialists: 14 classes × (80 000 × 0.6 × 0.4 / 20) batches ≈ 1 344 batches. At 8 parallel and ~12 s/batch (incl. tool calls): ~34 min. With 16-way parallel: ~17 min.
- Verifier: ~1 000 findings × 3 tool calls × 0.5 s ≈ 25 min.
- Report: ~1 min.
- **Total: ~1 hour** (well within the 12 h budget; the budget is a ceiling for slow providers).

The scan-time and cost estimates above cover source detection and reporting only. Opt-in exploit generation uses `--exploit-budget` separately; report its tokens, cost, and latency independently. VM validation has explicit per-attempt CPU, memory, disk, wall-clock, and retry limits in the lab manifest. Exhausting either budget yields a recorded partial result, not a stalled scan.

### 10.3 Disk

- Kernel source: ~2 GB.
- CPG + index: ~4 GB.
- `candidates.jsonl`: ~500 MB.
- `findings.jsonl`: ~50 MB.
- Total working set: ~7 GB.

---

## 11. Security and operational notes

- Source-analysis agents use only the read-only toolkit. The Exploit Agent has a separate, constrained artifact writer but no execution access. The MCP server remains read-only.
- API keys are passed via environment variables; never written to reports, generated artifacts, guest environments, or logs.
- The SAST toolchain (§5.4) is pinned and hash-verified in the container image; tools run offline with fixed flags. Any tool upgrade requires re-running the regression suite (§9.3).
- LPES itself runs in a container (see `pi-local/Dockerfile_pi` for the agent runtime; the toolkit runs as a sidecar). Generated exploit code must never execute there or on the host.
- Runtime validation requires explicit authorization and human review of generated code/build instructions, followed by execution in disposable VMs with no external network, host filesystem shares, credentials, or access to production systems. Provision approved dependencies before validation; enforce resource limits and destroy/reset guests after each attempt.
- Treat kernel source, model output, build instructions, and generated code as untrusted input. Enforce artifact path containment and runner policies outside the LLM; source comments cannot authorize execution.
- Reports and exploit bundles contain sensitive vulnerability details, and `LPES_REPORT.json` embeds complete, buildable exploit source in `exploit.poc` when generated (§8.3); restrict access, record approvals and artifact hashes, define retention, and require human review before sharing or disclosure.

---

## 12. Roadmap

| Phase | Scope | Exit criteria |
|---|---|---|
| P0 | Retrieval pipeline + CPG + toolkit; 3 classes (C1, C3, C8); no LLM; Semgrep + Coccinelle adapters online | candidates.jsonl matches 5 hand-checked CVEs |
| P1 | + Specialist + Verifier + Report for the 3 classes | recall ≥ 0.5 on 30-CVE corpus |
| P2 | + all 14 classes; full SAST adapter set (Smatch, Sparse, Clang SA) | recall ≥ 0.6 on 150-CVE corpus |
| P3 | + KB seeding from NVD; FP harvesting; optional CodeQL integration | FP rate ≤ 0.10 |
| P4 | + `--resume`; CI integration; cost tuning | full scan ≤ $30 (source-detection workflow) |
| P5 | + opt-in Exploit Agent, artifact bundles, reporting, and budget controls | Verified findings produce reviewable bundles or explicit failure/unsupported reasons; no host execution |
| P6 | + approved disposable-VM validation and vulnerable/fixed-image evaluation | Meet G6's demonstrated-impact target on the declared eligible subset; isolation and approval tests pass |

---

## 13. Glossary

| Term | Definition |
|---|---|
| CPG | Code Property Graph: AST + call graph + def-use edges |
| UAF | Use-after-free |
| TOCTOU | Time-of-check-to-time-of-use |
| Entry point | A kernel function reachable from userspace without capabilities |
| Capability | POSIX capability (`CAP_SYS_ADMIN`, etc.) gating a privileged operation |
| `__user` | C annotation marking a userspace pointer; data from it is untrusted |
| `copy_from_user` | Copies bytes from userspace into kernel memory; primary taint source |
| `capable(CAP_X)` | Check that the current task has capability X; if absent on a privileged op, it's a candidate finding |
| KB | Knowledge Base of historical CVEs, false positives, and fix patterns |
| SAST | Static Application Security Testing: pinned deterministic analyzers (Semgrep, Coccinelle, Smatch, Sparse, Clang SA, CodeQL) used to seed and corroborate candidates; never the sole gate (§4.2.3) |
| Candidate | A code location matching a deterministic pattern query; input to a specialist |
| Finding | A candidate confirmed by a specialist and verified by the Verifier |
| Specialist | An LLM agent for one vulnerability class |
| Orchestrator | The planning/scheduling agent |

---

## 14. File layout (repository)

```
vulneraser/
├── lpes_specs.md                    # this document
├── lpes/
│   ├── cli.py                       # CLI entrypoint
│   ├── retrieval/
│   │   ├── parser.py                # Tree-sitter parse
│   │   ├── callgraph.py             # Call graph builder
│   │   ├── defuse.py                # Def-use chains
│   │   ├── patterns.py              # C1..C14 trigger queries
│   │   ├── sast_rules/              # per-class SAST deps: semgrep/*.yaml, coccinelle/*.cocci, smatch/, sparse/
│   │   └── pipeline.py              # Orchestrates retrieval
│   ├── toolkit/
│   │   ├── mcp_server.py            # MCP server exposing tools
│   │   └── sast_adapters.py         # Pinned Semgrep/Coccinelle/Smatch/Sparse/Clang-SA/CodeQL subprocess adapters
│   │   ├── cpg.py                   # CPG storage + query
│   │   ├── taint.py                 # Forward/backward taint
│   │   ├── reachability.py          # Entry-point BFS
│   │   └── capability.py            # Capability check
│   ├── agents/
│   │   ├── orchestrator.py
│   │   ├── specialist_c01.py ... specialist_c14.py
│   │   ├── verifier.py
│   │   ├── report.py
│   │   └── exploit.py               # Opt-in exploit PoC generation
│   ├── kb/
│   │   ├── seed.py                  # Seed from NVD
│   │   └── schema.sql
│   ├── prompts/
│   │   ├── orchestrator.md
│   │   ├── c01_uaf.md ... c14_oob_read.md
│   │   ├── verifier.md
│   │   ├── report.md
│   │   └── exploit.md
│   ├── validation/
│   │   ├── artifacts.py             # Constrained artifact writer
│   │   ├── runner.py                # Approved disposable-VM validation
│   │   └── manifest.schema.json     # Pinned lab environment and limits
│   └── finding.schema.json
├── tests/
│   ├── corpus/                      # CVE reproducer trees
│   ├── regression/
│   └── toolkit/
└── reports/
```

---

## 15. Open questions (to resolve before P1)

1. **Inter-procedural taint depth.** Depth-3 may miss deep `setxattr` → overlayfs → fuse chains (CVE-2023-0386). Consider depth-5 for C11 only.
2. **`userfaultfd` as a TOCTOU enabler.** Should the retrieval pipeline flag `copy_from_user` in a region that also takes a shared lock as a C7 candidate by default? Risk: high FP rate.
3. **BPF and io_uring reachability.** These are fast-changing; the entry-point set (§2.2) must be version-aware.
4. **Config-gated code.** A finding in `drivers/staging/` built only under a rare `CONFIG_*` is low-value. Default: mark such findings `severity: low` with a `kbuild_context` note.
5. **LLM determinism.** Use temperature 0 and a fixed seed for reproducibility. Accept that findings may vary ~5% across runs; the regression suite tolerates this by checking `file:function` not exact `line`.
6. **Exploit evaluation scope (before P5).** Define eligible classes, target architectures, mitigation profiles, and the held-out VM corpus before measuring G6. Do not assume every verified bug supports a reliable privilege-escalation PoC.
7. **Validation infrastructure (before P6).** Select the VM backend, approval mechanism, impact-evidence checks, per-attempt limits, and artifact retention policy; these are prerequisites for enabling runtime validation.

---

*End of specifications.*
