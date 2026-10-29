# billion-context investigation and native adoption contract

Investigation date: 2026-10-25, Australia/Sydney. Evidence class: source-established unless explicitly labelled otherwise. This is a source investigation, not an execution or a claim of full behavioral parity.

## Identity, scope, and answer

- Upstream: https://github.com/ranxianglei/billion-context
- Reviewed revision: `52567f19bd7846e3fb91d7513c949b0751cd1c47` (local checkout and GitHub commit read agree).
- Package identity at that revision: `billion-context` 0.1.206; bundled `acp-kernel` 0.0.163.
- Inventory boundary: all 85 kernel source paths and 126 kernel test paths inventoried; selected contracts, implementation paths, and regression tests traced below. The entire proxy, all integrations, and every test have not been executed or exhaustively traced.
- Local source cache: `.research/upstream/billion-context`, ignored by the ZeroRepeat build and Git source tree.

**Fit:** yes, its reversible hierarchical conversation folding, retained originals, protected obligations, and retrieval loop directly complement ZeroRepeat's semantic object store and context compiler. Adopt the mechanisms as native Zig behavior, connected to the same ledger and policy. Installing an npm proxy or wrapping its TypeScript kernel would not satisfy the Zig-only requirement.

The name describes cumulative history processed over time, not a model holding a billion tokens at once. Its long-session, cache-hit, and token-saving figures are upstream reports, not results established for ZeroRepeat or Qwen3.8-27B. A faithful archive can preserve original bytes; an LLM summary alone remains lossy.

The upstream use of “ACP” for context compression is separate from **Agent Client Protocol**, which ZeroRepeat also plans to implement. Do not conflate the interfaces or their schemas.

## License and provenance

The root `LICENSE` contains MIT text **plus** an “Additional Term — Attribution on Product Surfaces,” explicitly including kernels. It requires visible attribution in product documentation/home/About surfaces and links to billion-context and acp-kernel. Preserve the exact license in third-party notices and provide documentation attribution for the native adaptation; do not describe this as unmodified MIT merely because `package.json` says MIT.

The kernel's own `PROVENANCE.md` describes its authors' independent reimplementation boundary relative to AGPL DCP. This is an upstream statement, not an independently completed provenance audit. ZeroRepeat should write fresh Zig expression from the reviewed contracts, retain provenance, and avoid copying legacy DCP-derived implementations.

Evidence: [root license](https://github.com/ranxianglei/billion-context/blob/52567f19bd7846e3fb91d7513c949b0751cd1c47/LICENSE), [kernel provenance](https://github.com/ranxianglei/billion-context/blob/52567f19bd7846e3fb91d7513c949b0751cd1c47/kernel/PROVENANCE.md), [package metadata](https://github.com/ranxianglei/billion-context/blob/52567f19bd7846e3fb91d7513c949b0751cd1c47/package.json).

## Source-established mechanism

`createCore` exposes `processTurn` and `applyCompression`. The kernel orchestrates selection and state but **does not call an LLM**; a model-authored summary is passed into the apply operation. Storage and model interaction are host responsibilities. See [kernel design](https://github.com/ranxianglei/billion-context/blob/52567f19bd7846e3fb91d7513c949b0751cd1c47/kernel/DESIGN.md) and [compress.ts](https://github.com/ranxianglei/billion-context/blob/52567f19bd7846e3fb91d7513c949b0751cd1c47/kernel/src/compress.ts).

The canonical turn pipeline reconciles message identities, assigns references, synchronizes blocks, projects summaries, offloads tool results, applies optional output transforms, hides consumed compression calls, recommends eligible ranges, decides pressure nudges, performs emergency handling, and renders references. Its feature switches matter: optional absorption, deterministic transforms, and CCR offloading are not automatically enabled by the kernel defaults.

`CompressionBlock` retains direct messages, direct child blocks, transitive effective-message coverage, tier, summary, generation, and state. Parent folds deactivate consumed children without deleting their records or original bytes. Blocks progress through three summary tiers; surviving longer is not a reason to discard them. References, block IDs, and rule IDs are never reused within their generation. Source: `types.ts`, `state.ts`, `refs.ts`, `sync.ts`, `compress.ts`.

`applyCompression` clones state and validates boundaries, protected regions, tool/turn integrity, novelty of coverage, and summary limits. Apply-level failures reject the batch without leaving earlier sibling folds committed. An already-covered message range must not manufacture a successful empty block. Range and coverage claims are exact: sequence min/max is insufficient when there are gaps.

`collectBlockContent` retrieves one layer or deep original content without rewriting the existing folded prefix. `deactivateBlock` and inline restoration are separate operations. `content-store.ts` stores originals by content hash and binds each reference once; retrieval does not depend on a mutable live reference map.

Production search uses `searchBlocks` over active/inactive block summaries **and historical originals**, returning the owning block for expansion. Its hybrid scorer combines normalized BM25 and fuzzy scores. The legacy `CompressionCore.search` is a distinct substring-only path; copying it would not reproduce production retrieval. Sources: `decompress.ts`, `content-store.ts`, `search/index.ts`, `search/SEARCH.md`.

## Feature-by-feature native disposition

This table specifies integration scope; “required” is not a claim that implementation is finished. Actual completion belongs in `COVERAGE.tsv` with native test evidence.

| ID | Upstream capability and evidence | Native ZeroRepeat disposition |
|---|---|---|
| BC-01 | Persistent, nonreused message/block/rule references: `refs.ts`, `state.ts`, `rules.ts` | Required. Ledger-issued session-scoped IDs; content hashes deduplicate bytes without collapsing separate events. Persist counters across restart. |
| BC-02 | Canonical messages and cross-protocol identity: `wire/message-id.ts`, `instance-reid.ts`, `MESSAGE-IDENTITY.md` | Required semantics. ZeroRepeat owns canonical event IDs, avoiding host reserialization joins internally. Provider adapters retain tool-call pairing and attach external identities only as aliases. Ambiguity must not join unrelated events. |
| BC-03 | One-message/range folds and summary validation: `compress.ts`, `boundaries.ts`, `parse-compress-input.ts` | Required. Typed Zig inputs, explicit expected state, exact source ranges, nonempty bounded summary, no new state on invalid application. Do not add a permissive text-parser language before a provider needs one. |
| BC-04 | Hierarchical T1/T2/T3 blocks and transitive coverage: `types.ts`, `unit-projection.ts`, `state.ts` | Required. Source and child references retain provenance; parent composition never deletes original source. Cap nesting and reject cycles/cross-session refs. |
| BC-05 | Protected current intent, tools, skills, recent zones, and rule calls: `protected.ts`, `turn-integrity.ts` | Required. Pin current requirements, corrections, open tasks/decisions, and unresolved jobs; enforce protection at fold execution as well as recommendation. Do not rely on a summary to preserve obligations. |
| BC-06 | Closed tool-call/result and reasoning groups: `tool-pairs.ts`, `reasoning-pairs.ts`, `prune.ts` | Required. Never emit orphan pairs or insert a summary inside a provider-atomic assistant/tool burst. Conservative refusal is preferable to malformed or misattributed history. |
| BC-07 | Reversible summary projection and original retention: `prune.ts`, `decompress.ts`, `content-store.ts` | Required. Full original bytes remain retrievable; restore can return source as bounded tool data without rewriting the existing prefix. Explicit full expansion must fit a new request budget. |
| BC-08 | CCR lossless large-output offload and bounded retrieval: `ccr.ts`, `content-store.ts` | Required. Content-addressed native storage, stable arrival-time preview/reference, range retrieval for large payloads, explicit missing/corrupt errors. Do not reinsert a multi-megabyte log by default. |
| BC-09 | Search original messages plus active/inactive summaries: `search/index.ts`, `search/algorithms/*` | Required. Start with native deterministic lexical ranking and exact source/owner refs; SQLite FTS is compatible. Track fuzzy/CJK/stemming/embedding parity separately instead of claiming it from a substring test. |
| BC-10 | Array-adjacency segmentation and exact coverage: `segment.ts`, `recommend.ts` | Required. Derive ranges from actual visible/canonical order, not numeric ID adjacency. Sparse refs and inserted summary nodes must not swallow uncovered events. |
| BC-11 | Growth/pressure nudges and tier arbitration: `compress.ts`, `nudge-text.ts`, `viable.ts` | Required capability. Budget-aware native eligibility/status; positive benefit and bounded retries. Calibrate Qwen-specific thresholds later instead of copying 50K-token defaults into a small configured window. |
| BC-12 | Byte-stable rendered tags, placeholders, transform latches: `render-refs.ts`, `view-latch.ts` | Required cache discipline. Stable unchanged representations; record deliberate seams. Native canonical state eliminates several host-reencoding workarounds, but repeated compilation must still be deterministic. |
| BC-13 | Consumed/failed compression-call cleanup: `hide-consumed.ts`, `protected.ts` | Required. Exclude obsolete internal management chatter from compiled context while retaining its audit events. Bounded failed-fold attempts cannot pollute every future prompt. |
| BC-14 | Persistent user rules and handoffs: `rules.ts`, `handoff.ts`, `rebuild.ts` | Required. Evidence-linked explicit constraints, task checklist, decisions, re-entry capsule, and restart replay; maintain supersession and removal history. Tool-derived text cannot promote itself into privileged user instructions. |
| BC-15 | Atomic durable state, stale-writer fencing, corruption handling: `persist/store.ts`, `persist/state-merge.ts` | Required semantics, implemented with SQLite transactions and durable immutable blob publication rather than porting a second JSON state store. Never advance live state after a failed durable commit. |
| BC-16 | Cache economics and status/recap: `cache-report.ts`, `report.ts` | Required accounting. Distinguish input/output/reasoning/cache tokens, compression work, logical bytes, stored bytes, retrievals, and actual provider usage. No fixed cache-hit or savings claim. |
| BC-17 | Instant lossy absorption: `absorb.ts` | Explicit optional mode. Original is retained and the distillation labelled lossy; do not let forced absorption bypass protected obligations. Full model-driven activation awaits the native provider loop. |
| BC-18 | Deterministic JSON/code/log transforms: `crush.ts`, `filter/*`, `truncate-tools.ts` | Adopt only format-aware transformations with retained originals and tests. Unknown output must remain inspectable. Track exact strategies separately; do not call a preview exception extraction or a general compressor. |
| BC-19 | Emergency truncation and terminal escape: `compress.ts`, `truncate*.ts` | Required safe overflow behavior. Prefer offload/retrieval; report irreducible pinned context that cannot fit. Any display truncation is labelled and retrievable. Never silently discard protected source to force a request through. |
| BC-20 | Prompt packs and output verbosity/reasoning steering: `packs.ts`, `surface-config.ts`, `output-steering.ts` | Track as configurable surfaces/experiments, not prerequisite changes to user intent. Avoid automatic reasoning reduction in quality comparisons; account for effects separately. |
| BC-21 | OpenAI/Responses/Anthropic/Google wire codecs and unified proxy compression loop: `wire/*`, `src/loop/*`, `UNIFIED_LOOP_SPEC.md` | ZeroRepeat uses its own typed provider layer. Native compression dispatch must have bounded rounds and transient guidance. No local proxy, cert-MITM, or client-configuration rewriting is needed for ZeroRepeat's own loop. |
| BC-22 | Multi-client launchers, native host plugins, installers, self-updates, port zones, GUI panels | Outside the selected native runtime integration. Their outcomes may inform protocol/client tests; do not duplicate their deployment product or mutate installed Claude/Codex/Hermes settings. |

## Regression and acceptance contract

1. **Identity:** identical text in separate turns keeps separate event refs while sharing immutable bytes; IDs are not reused after restart or removal. A caller cannot overwrite the original behind an existing ref.
2. **Transactions:** a fold batch containing an invalid/protected/stale range leaves block state, source coverage, and persistent counters unchanged. Allocation and disk failures do not create fake success.
3. **Protection:** current user corrections, open requirements, pending jobs, and their evidence remain independently available after repeated folds and restarts.
4. **Pair integrity:** parallel tool bursts and required reasoning companions remain provider-valid; a range containing only one half is rejected or safely expanded as a whole according to a documented policy.
5. **Hierarchy:** nested folds preserve exact child lineage and transitive source coverage. Deep expansion recovers the original messages in source order; no age-based block deletion loses them.
6. **Sparse coverage:** non-monotonic display refs, holes, deleted items, and inserted summary nodes never cause numeric min/max over-selection.
7. **Retrieval:** a random nonce omitted from every summary remains searchable/retrievable from original source after restart. Large originals return bounded pages and stable references; missing/corrupt blobs return explicit failure.
8. **Caching:** recompiling unchanged state produces stable bytes; cache-safe retrieval does not rewrite preceding summary bytes. Record necessary changes rather than claiming zero repeated logical input.
9. **Overflow/livelock:** already-covered folds and nonbeneficial summaries do not report successful compression indefinitely. If pinned context cannot fit, return an actionable limit instead of losing it.
10. **Trust:** restored tool output and historical summaries preserve provenance and low trust; malicious content cannot create a new project/user rule.

Upstream regression anchors: `kernel/tests/range-coverage.test.ts`, `tool-pair-integrity.test.ts`, `seq-interval-coverage.test.ts`, `issue3003-all-or-nothing-length.test.ts`, `issue3939-wire-byte-stability.test.ts`, `issue3939-view-latch.test.ts`, `issue4348-receipt-lace.test.ts`, `ccr.test.ts`, `refold.test.ts`, `rules.test.ts`, `open-objectives.test.ts`, `persist.test.ts`, `terminal-escape.test.ts`.

## Boundaries and remaining work

No upstream package was installed or executed for this investigation. No token-savings experiment, cache reproduction, official benchmark, real-model summary-quality experiment, or billion-token scale test was run. A local native unit test establishes only the behavior it actually exercises. Native provider-loop integration, end-to-end lifecycle, language-specific retrieval quality, and large-scale performance need their own acceptance evidence.

The complete ZeroRepeat harness remains governed by `../PLAN.md`; this integration does not replace its provider, execution, sandbox, editing, UI, subagent, SDK, MCP, or ACP requirements. Keep every pending native capability visible in `../TASKS.md` and `../COVERAGE.tsv`.
