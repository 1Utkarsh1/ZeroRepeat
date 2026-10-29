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

## Verified implementation and evidence

- `PLAN.md` is byte-identical to the full supplied attachment; it remains the release contract.
- `COVERAGE.tsv` retains 70 baseline rows: 18 complete-harness subsystem contracts, 22 billion-context dispositions, 4 continuity requirements, and 26 research references. The native checker now rejects deletion or kind changes for every baseline ID, completion without a revision/evidence, unfinished required work, and unresolved reference audits at release. It validates evidence structure, not whether a claim is true.
- Native SQLite C-ABI/storage, immutable BLAKE3 originals, distinct event identities, transactional hierarchical folding, protection/rules, versioned restoration, bounded retrieval/offloading, lexical BM25 search, and budget diagnostics work locally. One database is one namespace; global/cross-session binding remains open.
- A native incremental Chat Completions SSE decoder assembles complete tool arguments, separates reasoning, validates usage, and rejects malformed/truncated streams before exposing calls. HTTP transport and a live model loop remain open.
- Typed native context `inspect`/`act` dispatch supports status/search/retrieval/fold/expand/refold. Unknown/duplicate fields and privileged rule requests are rejected. `CommittedResultUnavailable` means inspect current state and never replay automatically. File `patch` is not implemented or advertised.
- The public Zig module exports these components. Scripted byte-fragmented provider fixtures exercise real native folding and exact retrieval; they are not real-model tests.
- Integrated native tests: **79/79 passed** (76 core, 2 CLI parser, 1 subprocess stdout regression). Separate continuity tests: 10/10. Commands, source hashes, and limitations are in `evidence/2026-10-30-verification.md` and adjacent raw reports.
- macOS native build and static Linux x86_64-musl `safe` cross-build passed. The Linux executable has not been run.
- billion-context source was audited at `52567f19bd7846e3fb91d7513c949b0751cd1c47` (package 0.1.206, kernel 0.0.163). See `research/billion-context.md` for the 22-feature adoption map. Preserve the exact license's additional attribution term and both visible upstream links. Published savings were not reproduced.
- The user-authorized personal memory note exists at `/Users/utkarshrajput/.codex/memories/extensions/ad_hoc/notes/2026-10-25T073047Z-zerorepeat-continuity.md`. It points back here; it does not replace these records.

## Recovery and local environment

The working compiler is `/Users/utkarshrajput/.cache/zerorepeat/bootstrap/zig-aarch64-macos-0.17.0/zig`; native build cache is `/Users/utkarshrajput/.cache/zerorepeat/zig-local`. The current native binary is `/Users/utkarshrajput/.cache/zerorepeat/build/native/bin/zerorepeat`. Zig 0.17 uses `-Doptimize=safe`; `ReleaseSafe` is not an accepted option in this installed version.

macOS dataless placeholders blocked reads of the old workspace toolchain, SQLite, some source files, and Git metadata. Exact pinned dependencies were reacquired and checksummed. `context.zig` was recovered from recorded edits and build files from recorded successful reads; original placeholder inodes remain under `.research/offloaded-originals/`. Current implementation source is readable and checksummed. Original `.git` is preserved. After metadata materialization, ordinary status completes and confirms no previous commits on main. Byte comparisons now also prove all recovered original source/build bytes match their preserved originals. A separate recovery Git directory is `/Users/utkarshrajput/.local/share/zerorepeat/checkpoints/harness.git`, used with this workspace as `--work-tree`. See the verification record for checkpoint/bundle status. No offsite backup is configured.

No paid inference or cloud resources have been created during construction. No resource IDs or spend to reconcile; recorded project deployment spend is US$0. This is not a fresh account-wide billing audit.

## Next concrete actions

1. Complete the dated subprocess smoke/evidence, continuity/release checks, and a verified local Git/bundle checkpoint of this foundation.
2. Continue M1: the actual headless provider/task/tool loop. Add portable request construction and HTTP transport with scripted local-server fixtures, bounded context-management rounds, cancellation/timeouts/budgets, and transient guidance that does not accumulate in canonical history.
3. Implement repository inspection, expected-version file patches and isolated execution, then pass a complete inspect → edit → test → repair → verify workflow locally.
4. Keep auditing the remaining pinned reference features alongside implementation. Do not mark M0 or the full release complete from this component's results.

## Open work and evidence boundaries

All 18 full-harness subsystem contracts remain pending or in progress. HTTP/provider variants, a task lifecycle, full semantic graph, repository index/Tree-sitter/LSP, model residency/branch manifests, command/PTY/job lifecycle, sandbox/policy, file edits/Git recovery, memory/skill promotion, subagents, plugins/MCP, TUI/headless task interfaces, complete SDK/ACP, full accounting and distribution remain unfinished. Native context projection does not implement pending jobs or provider-specific history reconstruction. Cross-session reference envelopes, injected process-crash/disk-full recovery, and bounded management rounds remain open.

No billion-token scale test, real-model summary-quality result, token/time savings result, official benchmark, or competitor parity result exists. Fuzzy/CJK/embedding retrieval and optional upstream transforms/steering are not claimed. The active goal and complete release remain **incomplete**.
