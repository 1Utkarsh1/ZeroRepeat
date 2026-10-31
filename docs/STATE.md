# ZeroRepeat durable working context

Updated: 2026-11-01, Australia/Sydney.

## Goal and locked decisions

Build the complete Zig coding harness in `PLAN.md`, optimized for correctness, time to correct solution, and tokens to correct solution. Preserve its full scope across turns and compaction. The active request also requires durable memory/context, a task list, every-turn rough logging, and native adoption of useful billion-context mechanisms.

- All first-party implementation and tests are Zig; no Python implementation or prototype.
- Zig 0.17.0; native SQLite/Tree-sitter C dependencies and Zig BLAKE3.
- Reference model: `Qwen/Qwen3.8-27B`. Cloud budget: US$7 total. Build locally first; paid validation and competitive benchmarks come later.
- Initial platforms: macOS ARM64 and Linux x86-64.
- Omitted source must actually be available to the next inference. A stored reference, earlier exposure, or a cache assumption is insufficient.
- Preserve user data and stale-edit checks; never automatically replay uncertain mutations.

## GitHub checkpoints

The public repository is https://github.com/1Utkarsh1/ZeroRepeat, configured as `origin`. The initial publication was verified at `275ea7296e481439b967aad173f658a20924fa03` on the default branch `Utkarsh/native-context-foundation`. Commit and push meaningful project checkpoints and before ending active work turns; compare the actual remote branch SHA with the intended local commit. Preserve history and report failures instead of force-pushing. The scoped personal instruction note is `/Users/utkarshrajput/.codex/memories/extensions/ad_hoc/notes/2026-10-29T230741Z-zerorepeat-github-checkpoints.md`. See `evidence/2026-10-30-github-publication.md`.

Current tested implementation is being published as `native-repository-edits-2026-11-01`; exact current bytes are in `evidence/CURRENT_SOURCE.sha256`. The publication receipt records its commit and independent remote verification. Prior verified source: `8a0f2594c624eb251a12560a478c1da8040c34a9`, tagged `native-task-driver-2026-10-30`; its history and evidence remain retained.

## Verified implementation and evidence

- `PLAN.md` is byte-identical to the full supplied attachment; it remains the release contract. Foundation source checkpoint: `28e053d63f586185b4e12ef61ef951edc0c3fd59` on `Utkarsh/native-context-foundation`. Later checkpoints are tagged `native-provider-request-2026-10-30`, `native-provider-http-2026-10-30` and `native-task-driver-2026-10-30`; current implementation hashes are in `evidence/CURRENT_SOURCE.sha256`.
- `COVERAGE.tsv` retains 70 baseline rows: 18 complete-harness subsystem contracts, 22 billion-context dispositions, 4 continuity requirements, and 26 research references. The native checker now rejects deletion or kind changes for every baseline ID, completion without a revision/evidence, unfinished required work, and unresolved reference audits at release. It validates evidence structure, not whether a claim is true.
- Native SQLite C-ABI/storage, immutable BLAKE3 originals, distinct event identities, transactional hierarchical folding, protection/rules, versioned restoration, bounded retrieval/offloading, lexical BM25 search, and budget diagnostics work locally. One database is one namespace; global/cross-session binding remains open.
- A native incremental Chat Completions SSE decoder assembles complete tool arguments, separates reasoning, validates usage, and rejects malformed/truncated streams before exposing calls. A typed request encoder preserves reasoning and complete tool exchanges, validates schemas/history, and bounds actual escaped bytes. Native HTTP transport sends one validated POST, decodes SSE, classifies bounded rejection responses and enforces deadline/caller cancellation.
- The exported native task journal and bounded driver connect scripted/HTTP providers to typed context and optional repository tools. Durable requirements, requests, planned/started/result actions, output reservations, observed usage, failures and transient guidance are verified locally. Unknown outcomes enter attention; no automatic replay occurs. Model stop awaits independent verification. Schema version 3 migrates versions one/two transactionally, preserving source and prior action records. Productive file edits remain distinct from context-management accounting/history pruning. See `research/task-driver.md` and `research/repository-editing.md` for exact scope and limitations.
- Native `inspect`/`act` dispatch supports status/search/retrieval/fold/expand/refold. Attaching a host-granted physical repository adds file paths/read/version; writable grants add replacement preview and `patch`. Exact-path capabilities, no-follow traversal, regular single-link checks, active-store protection and configured-key guards are verified. These checks are not an OS sandbox. Unknown/duplicate fields and privileged rule requests are rejected. `CommittedResultUnavailable` means inspect current state and never replay automatically.
- File edits validate current refs/generation, UTF-8 byte ranges, metadata and all candidates before intent publication. Native metadata copying, sync, retained displaced inodes, per-file journal states and fresh version-checked undo are verified. Actual SIGKILL cases cover staged and post-exchange boundaries. Atomic exchange is not content CAS: a final-check racing writer's bytes are retained, but the target path can already change before attention is reported. Batches are not globally atomic. Shared-workspace isolation, conflict UX, unified diffs, create/delete/rename and Git/index/LSP remain open.
- The public Zig module exports these components. Scripted/real loopback provider fixtures exercise real native folding, retrieval and task transitions; they are not real-model tests. The CLI still has no live task/model command.
- Integrated native tests: **144/144 passed** (140 core, 2 CLI parser, 1 CLI subprocess, 1 process-recovery test), including 14 repository tests, three additional driver tests and actual SIGKILL fixtures. Reports: `evidence/2026-11-01-repository-native-tests.txt` and `research/repository-editing.md`. Historical reports remain preserved at their named revisions.
- macOS native build and static Linux x86_64-musl `safe` build/link of the CLI, four test binaries and crash helper passed. Linux binaries have not been executed. The configured Docker context has an absent Colima socket; no daemon/container was started.
- billion-context source was audited at `52567f19bd7846e3fb91d7513c949b0751cd1c47` (package 0.1.206, kernel 0.0.163). See `research/billion-context.md` for the 22-feature adoption map. Preserve the exact license's additional attribution term and both visible upstream links. Published savings were not reproduced.
- The user-authorized personal memory note exists at `/Users/utkarshrajput/.codex/memories/extensions/ad_hoc/notes/2026-10-25T073047Z-zerorepeat-continuity.md`. It points back here; it does not replace these records.

## Recovery and local environment

The prior verified canonical recovery bundle is `/Users/utkarshrajput/.local/share/zerorepeat/checkpoints/zerorepeat-native-task-2026-10-30.bundle`; its 22-hash task-driver restore remains retained. This checkpoint creates `zerorepeat-native-repository-2026-11-01.bundle` and an owned `restored-repository-2026-11-01` clone beside it, containing primary Git history and all four provider/task/repository tags. See the new publication receipt for actual restore/hash/continuity/fsck results; do not infer a successful backup from this intended filename.

The physical project root is `/Users/utkarshrajput/Library/Application Support/Local AI Workspaces/ChatGPT/Harness`. `Documents/ChatGPT/Harness` resolves here through a compatibility symlink. New working files, outputs and scratch remain outside iCloud Drive; existing history and unrelated syncing are preserved.

The working compiler is `/Users/utkarshrajput/.cache/zerorepeat/bootstrap/zig-aarch64-macos-0.17.0/zig`; native build cache is `/Users/utkarshrajput/.cache/zerorepeat/zig-local`. The current native binary is `/Users/utkarshrajput/.cache/zerorepeat/build/native/bin/zerorepeat`. Zig 0.17 uses `-Doptimize=safe`; `ReleaseSafe` is not an accepted option in this installed version.

macOS dataless placeholders blocked reads of the old workspace toolchain, SQLite, some source files, and Git metadata. Exact pinned dependencies were reacquired and checksummed. `context.zig` was recovered from recorded edits and build files from recorded successful reads; original placeholder inodes remain under `.research/offloaded-originals/`. Current implementation source is readable and checksummed. Original `.git` is preserved. After metadata materialization, ordinary status completes and confirms no previous commits on main. Byte comparisons now also prove all recovered original source/build bytes match their preserved originals. A separate recovery Git directory is `/Users/utkarshrajput/.local/share/zerorepeat/checkpoints/harness.git`, used with this workspace as `--work-tree`. A complete recovery bundle at `/Users/utkarshrajput/.local/share/zerorepeat/checkpoints/zerorepeat-native-context-2026-10-30.bundle` was verified and cloned to `restored-2026-10-30` beside it; all 15 source/dependency hashes, the original plan, continuity check and Git object integrity passed there. See the verification record for exact recovery commands. Tracked project source/history is now also published to the explicitly authorized public GitHub repository. Runtime data and local recovery files remain separate.

No paid inference or cloud resources have been created during construction. No resource IDs or spend to reconcile; recorded project deployment spend is US$0. This is not a fresh account-wide billing audit.

## Next concrete actions

1. Add policy-backed isolated command execution and bounded result capture through M1's existing typed effect boundary, preserving durable intent/start/result records and uncertain-action rules.
2. Pass the complete inspect → edit → test → repair → verify workflow locally. Expose task CLI/events, independent verification and safe explicit reconciliation/resume through that shared runtime. Extend editing with unified diffs/create/delete/rename, conflict UX and Git/index reconciliation.
3. Keep auditing the remaining pinned reference features alongside implementation. Do not mark M0 or the full release complete from this component's results.

## Open work and evidence boundaries

All 18 full-harness subsystem contracts remain pending or in progress. Live HTTPS/model compatibility, provider variants/media, full verification/completion/resume, semantic graph, repository index/Tree-sitter/LSP, model residency/branch manifests, command/PTY/job lifecycle, sandbox/policy, complete editing/Git recovery, memory/skills, subagents, plugins/MCP, TUI/task CLI, complete SDK/ACP and distribution remain unfinished. Input-token/template/delegation/cost budgets and automatic pressure-triggered compaction remain open; current caps cover requests/tools/management rounds/wire bytes/output/time. Native projection does not implement pending jobs or general provider-history reconstruction. Cross-session references, disk-full/power-loss recovery, general crash recovery and complete accounting remain open. Two real process-kill edit boundaries and injected failure paths are tested; they do not prove every crash/persistence condition.

No billion-token scale test, real-model summary-quality result, token/time savings result, official benchmark, or competitor parity result exists. Fuzzy/CJK/embedding retrieval and optional upstream transforms/steering are not claimed. The active goal and complete release remain **incomplete**.
