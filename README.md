# ZeroRepeat

A Zig coding harness under construction, with a working native context engine and durable project-continuity tools.

Public source: [1Utkarsh1/ZeroRepeat](https://github.com/1Utkarsh1/ZeroRepeat). Project and continuity checkpoints are committed and pushed during active work and before turn handoff; each push is checked against the remote commit.

The complete release contract is in [docs/PLAN.md](docs/PLAN.md). A bounded Zig task driver now connects providers to native context tools. Repository editing/execution, the task CLI, full verification/resume, repository graph, sandbox, subagents, TUI, MCP, and ACP remain tracked work. This repository does not currently expose a complete autonomous coding agent or claim competitive benchmark performance.

## Keep the project context across turns

Read [AGENTS.md](AGENTS.md), [docs/STATE.md](docs/STATE.md), [docs/TASKS.md](docs/TASKS.md), and the newest [work log](docs/LOG.md) before continuing. The full plan is retained unchanged from the supplied attachment. [docs/COVERAGE.tsv](docs/COVERAGE.tsv) tracks every subsystem and research reference; pending requirements remain visible.

```sh
zig build check
zig build run -- continuity context
zig build run -- continuity log "Work checkpoint" "Verified changes, evidence, unresolved work, and the next action."
```

The log command appends under a file lock and synchronizes the file. The continuity command emits current state/tasks and a bounded tail; it never deletes the full log. All 70 original feature/reference IDs and their kinds are checked. `continuity check --release` intentionally fails while required work or reference audits are unfinished. Coverage checks validate records and evidence-file presence, not the truth of performance or completeness claims.

Git history and an explicitly requested Codex memory note provide additional discovery/recovery pointers. These records survive chat compaction; they are not a guarantee against filesystem loss. No cloud backup is silently configured.

## Build

Use **Zig 0.17.0**, pinned in `.zigversion`. The first-party implementation and tests are Zig. The bundled, unchanged SQLite C library is a native dependency; no Python or npm runtime is required. Dependency origin, checksums, build flags, and acquisition details are in [the dependency record](docs/research/dependencies.md).

```sh
zig build
zig build test --summary all
zig build check
zig build run -- doctor
zig build -Dtarget=x86_64-linux-musl -Doptimize=safe --prefix zig-out/linux
```

This working environment uses `/Users/utkarshrajput/.cache/zerorepeat/bootstrap/zig-aarch64-macos-0.17.0/zig` and `--cache-dir /Users/utkarshrajput/.cache/zerorepeat/zig-local`. The old `.tools/` copy contains macOS file placeholders. Use a readable compiler/cache outside cloud-managed Documents when needed; recovery details are in the [dated evidence](docs/evidence/2026-10-30-verification.md). Compiler/research caches are ignored. SQLite is pinned in the repository so its build does not depend on a system SQLite version or network package extraction.

## Native billion-context integration

ZeroRepeat uses **billion-context and acp-kernel** mechanisms through a native Zig implementation:

- Upstream: https://github.com/ranxianglei/billion-context
- Kernel: https://github.com/ranxianglei/acp-kernel
- Reviewed revision: `52567f19bd7846e3fb91d7513c949b0751cd1c47`
- Source/license investigation and feature dispositions: [billion-context research](docs/research/billion-context.md)
- Exact upstream license, including product-surface attribution: [LICENSES/billion-context.txt](LICENSES/billion-context.txt)

There is no TypeScript wrapper, proxy installer, certificate interception, or modification of installed coding clients. The native module provides immutable content-addressed originals, separate event references, atomic hierarchical folds, protected obligations and tool groups, versioned restoration/refolding, exact byte retrieval, lexical search, and pressure/budget diagnostics. The original message data remains available when a lossy summary omits a fact.

Summaries are supplied by the caller/model through the typed operation and explicitly labelled low trust. The storage module does not call a model or validate a summary's semantic quality. The native driver can dispatch compression with bounded rounds and transient guidance. Three tiers, exact lineage, and transactional state are native behavior; full upstream host/plugin parity, optional transforms, fuzzy/CJK/embedding search and real-model summary quality are not claimed.

“Billion context” describes cumulative retained history, not billion-token resident model context. Upstream savings/cache figures have not been reproduced here. Logical context, actual provider tokens, cached computation, and transmitted bytes are distinct measures.

## Use the current context tools

```sh
zig-out/bin/zerorepeat help
zig-out/bin/zerorepeat context /absolute/physical/path/session.db init
zig-out/bin/zerorepeat context /absolute/physical/path/session.db add request-1 user /path/to/request.txt
zig-out/bin/zerorepeat context /absolute/physical/path/session.db status
zig-out/bin/zerorepeat context /absolute/physical/path/session.db recommend
zig-out/bin/zerorepeat context /absolute/physical/path/session.db compile
zig-out/bin/zerorepeat context /absolute/physical/path/session.db search "some diagnostic"
zig-out/bin/zerorepeat context /absolute/physical/path/session.db retrieve m1 0 4096
```

Use the current generation from `status` and actual visible references for `fold`, `expand`, `refold`, and rule retirement. A fold is an explicit range plus a summary file; originals remain retained. Large tool results have stable previews and paged retrieval. Retrieval offsets and limits count **bytes**, so a page can split a UTF-8 codepoint; concatenate exact pages before interpreting text. Full CLI syntax is available through `help`.

The parent directory must already exist and use a physical path. SQLite's no-follow mode rejects symlink paths, including macOS `/tmp` (use its physical `/private/tmp` target). Disk commands require explicit initialization. Foreign nonempty databases and unsupported owned schemas are rejected rather than converted. Databases made by an earlier unmarked development build are retained untouched and rejected as foreign; they are not silently migrated.

The default compiler uses conservative byte estimates, not measured Qwen tokenizer counts. The SDK can supply an exact counting callback. Compilation fails explicitly when protected/visible material cannot fit; it does not silently drop source. A previously sent reference does not establish model residency. Generation is an out-of-band mutation precondition and is excluded from the stable model-visible prefix.

## Verification and limits

Native tests cover disk reopen, ID/content separation, invalid-batch rollback, protected requirements, tool/reasoning groups, three-tier restoration, refold versions, bounded retrieval, stale writers, corruption, foreign-database preservation and seeded mixed-operation regression. The latest integrated 30 October run passed **126/126 tests**, including the bounded driver, real loopback task execution, cancellation, budget/usage rules, allocation failures, schema migration and conservative interrupted-action recovery. [Task-driver evidence](docs/research/task-driver.md), [provider protocol evidence](docs/research/provider-protocol.md) and the [historical foundation report](docs/evidence/2026-10-30-verification.md) record exact scope and source hashes.

The exported `provider_request`/`provider_stream` modules encode bounded Chat Completions requests and validate complete SSE replies, reasoning, tool groups and usage. `provider_http` supports a single explicit request with cancellation/deadline and typed rejection, without automatic retry/redirect. `context_tools` exposes strict native `inspect`/`act` operations and whole-burst preparation; file `patch` and model rule authority are not advertised. `task` and `agent` add the durable bounded SDK driver, with request/action journals, registered requirement protection and conservative recovery. `CommittedResultUnavailable` requires inspection and must never trigger automatic replay. A model stop awaits independent verification. Live inference, full task CLI/coding effects, general resume, UI deltas and complete input/delegation/cost accounting remain unfinished.

The current cloud budget is **US$7 total**. Construction is local; official benchmarks and paid model experiments are later work. Passing local context tests does not establish full-harness readiness, summary quality, billion-token scaling, or an improvement over Hermes, Pi, Codex, Claude Code, or OpenCode.
