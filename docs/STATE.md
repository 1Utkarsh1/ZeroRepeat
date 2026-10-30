# ZeroRepeat durable working context

Updated: 2026-10-30, Australia/Sydney.

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

## Verified implementation and evidence

- `PLAN.md` is byte-identical to the full supplied attachment; it remains the release contract. Foundation source checkpoint: `28e053d63f586185b4e12ef61ef951edc0c3fd59` on `Utkarsh/native-context-foundation`. Later checkpoints are tagged `native-provider-request-2026-10-30`, `native-provider-http-2026-10-30` and `native-task-driver-2026-10-30`; current implementation hashes are in `evidence/CURRENT_SOURCE.sha256`.
- `COVERAGE.tsv` retains 70 baseline rows: 18 complete-harness subsystem contracts, 22 billion-context dispositions, 4 continuity requirements, and 26 research references. The native checker now rejects deletion or kind changes for every baseline ID, completion without a revision/evidence, unfinished required work, and unresolved reference audits at release. It validates evidence structure, not whether a claim is true.
- Native SQLite C-ABI/storage, immutable BLAKE3 originals, distinct event identities, transactional hierarchical folding, protection/rules, versioned restoration, bounded retrieval/offloading, lexical BM25 search, and budget diagnostics work locally. One database is one namespace; global/cross-session binding remains open.
- A native incremental Chat Completions SSE decoder assembles complete tool arguments, separates reasoning, validates usage, and rejects malformed/truncated streams before exposing calls. A typed request encoder preserves reasoning and complete tool exchanges, validates schemas/history, and bounds actual escaped bytes. Native HTTP transport sends one validated POST, decodes SSE, classifies bounded rejection responses and enforces deadline/caller cancellation.
- The exported native task journal and bounded driver now connect scripted/HTTP providers to context tools. Durable requirements, requests, planned/started/result actions, output reservations, observed usage, failures and transient guidance are verified locally. Unknown outcomes enter attention; no automatic replay occurs. Model stop awaits independent verification. Schema version 2 preserves version-one source and adds journal tables transactionally. See `research/task-driver.md` for exact scope and limitations.
- Typed native context `inspect`/`act` dispatch supports status/search/retrieval/fold/expand/refold. Unknown/duplicate fields and privileged rule requests are rejected. `CommittedResultUnavailable` means inspect current state and never replay automatically. File `patch` is not implemented or advertised.
- The public Zig module exports these components. Scripted/real loopback provider fixtures exercise real native folding, retrieval and task transitions; they are not real-model tests. The CLI still has no live task/model command.
- Integrated native tests: **126/126 passed** (123 core, 2 CLI parser, 1 subprocess stdout regression), including 26 driver/journal regressions and allocation-failure sweeps. Reports: `evidence/2026-10-30-task-driver-integrated-tests.txt` and `research/task-driver.md`. The historical foundation/transport reports remain preserved at their named revisions.
- macOS native build and static Linux x86_64-musl `safe` cross-build passed. The Linux executable has not been run.
- billion-context source was audited at `52567f19bd7846e3fb91d7513c949b0751cd1c47` (package 0.1.206, kernel 0.0.163). See `research/billion-context.md` for the 22-feature adoption map. Preserve the exact license's additional attribution term and both visible upstream links. Published savings were not reproduced.
- The user-authorized personal memory note exists at `/Users/utkarshrajput/.codex/memories/extensions/ad_hoc/notes/2026-10-25T073047Z-zerorepeat-continuity.md`. It points back here; it does not replace these records.

## Recovery and local environment

The working compiler is `/Users/utkarshrajput/.cache/zerorepeat/bootstrap/zig-aarch64-macos-0.17.0/zig`; native build cache is `/Users/utkarshrajput/.cache/zerorepeat/zig-local`. The current native binary is `/Users/utkarshrajput/.cache/zerorepeat/build/native/bin/zerorepeat`. Zig 0.17 uses `-Doptimize=safe`; `ReleaseSafe` is not an accepted option in this installed version.

macOS dataless placeholders blocked reads of the old workspace toolchain, SQLite, some source files, and Git metadata. Exact pinned dependencies were reacquired and checksummed. `context.zig` was recovered from recorded edits and build files from recorded successful reads; original placeholder inodes remain under `.research/offloaded-originals/`. Current implementation source is readable and checksummed. Original `.git` is preserved. After metadata materialization, ordinary status completes and confirms no previous commits on main. Byte comparisons now also prove all recovered original source/build bytes match their preserved originals. A separate recovery Git directory is `/Users/utkarshrajput/.local/share/zerorepeat/checkpoints/harness.git`, used with this workspace as `--work-tree`. A complete recovery bundle at `/Users/utkarshrajput/.local/share/zerorepeat/checkpoints/zerorepeat-native-context-2026-10-30.bundle` was verified and cloned to `restored-2026-10-30` beside it; all 15 source/dependency hashes, the original plan, continuity check and Git object integrity passed there. See the verification record for exact recovery commands. Tracked project source/history is now also published to the explicitly authorized public GitHub repository. Runtime data and local recovery files remain separate.

No paid inference or cloud resources have been created during construction. No resource IDs or spend to reconcile; recorded project deployment spend is US$0. This is not a fresh account-wide billing audit.

## Next concrete actions

1. Extend M1's native bounded driver with repository inspection and expected-version patches. Keep one typed effect boundary and durable intent/start/result records; do not weaken stale-edit or uncertain-action rules.
2. Add policy and established isolation for command execution, then pass the complete inspect → edit → test → repair → verify workflow locally. Expose task CLI/events and safe explicit reconciliation/resume through that shared runtime.
3. Keep auditing the remaining pinned reference features alongside implementation. Do not mark M0 or the full release complete from this component's results.

## Open work and evidence boundaries

All 18 full-harness subsystem contracts remain pending or in progress. Live HTTPS/model compatibility, provider variants/media, full verification/completion/resume, semantic graph, repository index/Tree-sitter/LSP, model residency/branch manifests, command/PTY/job lifecycle, sandbox/policy, file edits/Git recovery, memory/skills, subagents, plugins/MCP, TUI/task CLI, complete SDK/ACP and distribution remain unfinished. Input-token/template/delegation/cost budgets and automatic pressure-triggered compaction remain open; current caps cover requests/tools/management rounds/wire bytes/output/time. Native projection does not implement pending jobs or general provider-history reconstruction. Cross-session references, process-kill/disk-full recovery and complete accounting remain open. Current interruption evidence uses committed-boundary close/reopen and an injected failed result acknowledgement; it does not prove real process-crash durability.

No billion-token scale test, real-model summary-quality result, token/time savings result, official benchmark, or competitor parity result exists. Fuzzy/CJK/embedding retrieval and optional upstream transforms/steering are not claimed. The active goal and complete release remain **incomplete**.
