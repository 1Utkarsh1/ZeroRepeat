# Native context integration contract

The authoritative context implementation is `src/context.zig`; its callers include the CLI, typed context tools and bounded task driver exported through `src/root.zig`. Native tests are in `context_tests.zig`, `context_state_tests.zig`, `agent_tests.zig` and inline module tests. The full harness remains governed by `../PLAN.md`.

## Durable state

One context database is one session namespace. SQLite application ID `0x5a525054` marks ownership; the current schema is version 2. Version one migrates transactionally by adding the task journal, preserving source bytes/identity/generation. A nonempty database without that identity, a foreign identity, an incomplete owned schema, or a future version is rejected before journal/schema configuration. The database uses WAL, FULL synchronization, foreign keys, and no-follow opens. A failed migration can leave WAL configured after the ownership check, but cannot publish partial schema/data changes; see [task-driver evidence](task-driver.md).

Canonical message events have monotonically allocated IDs and a unique external-event alias. Re-ingesting the same alias with the same complete projection is idempotent; changed content or metadata behind that alias is rejected. Equal content in separate events still produces separate message references. BLAKE3 deduplicates and verifies immutable payload bytes; triggers reject canonical message/blob updates and deletes. Original history and summary revisions are retained. This is not yet the complete object graph or filesystem blob/retention/backup implementation required by ZR-03/04.

Folds record direct message children, direct block children, and exact transitive message membership. IDs are never interpreted as interval coverage. Active block coverage is disjoint by construction. Parents only reference older children, so the persisted graph cannot form a cycle through the native API.

All fold batches use one immediate transaction and an expected generation. A failure rolls back state, IDs, blobs, indexes, events, and generation. Read views, compilation, recommendations and status use a consistent snapshot and preserve a caller-owned transaction. Retrieval records a counter without rewriting the compiled projection.

## Protection and provenance

System messages, explicit pinned content, current user intent, configured recent messages/tokens, active rule sources, registered requirements/corrections of uncanceled tasks, unresolved tool calls, opaque media, and ungrouped reasoning are protected. Protection closes over call/result and provider group membership. The apply path enforces the same constraints as recommendation. A partial atomic group is rejected.

Explicit constraints/tasks/decisions/facts require user/project authority and a real user-message source. Model/tool authority and a tool-message source cannot create privileged records. Supersession and retirement retain history; active records govern current obligations. Supplied summaries are labelled external and low trust, not falsely described as model-generated or verified facts.

The complete task engine must still track unresolved jobs, provider-specific atomic groups, model residency, and plan state. Do not claim these are implemented merely because the native context module supports pinned sources and grouping fields.

## Projection and retrieval

The compiler projects visible messages, stable offload previews, and active summaries in source order. It does not reload every folded original to render the live view. An ordinary append preserves preceding compiled bytes; generation travels out of band. Expansion intentionally changes the projection; nonmutating retrieval preserves preceding summary bytes. Refolding requires explicit expansion and creates a new immutable summary revision under the same block identity.

Tool-output offloading retains the original BLOB and emits a labelled stable preview/reference. Byte retrieval is bounded to 64 KiB per call, validates BLAKE3, and fails explicitly on missing/corrupt objects. A block retrieval joins exact original messages with newlines; retrieve individual message refs when exact event boundaries matter. Deep expansion restores canonical roles, kinds, identities, order and bodies. Reads of a requested summary version must name an existing version.

SQLite FTS5 lexical BM25 search covers original messages and current summaries of active/inactive blocks. Replaced summary revisions remain archived in `block_versions`; only the current revision is in lexical search. Search is not advertised as fuzzy/CJK/stemmed/embedding parity with upstream. Query terms are quoted and bound as data, and results retain real BM25 scores plus actionable block versions.

## Budget behavior

The native default counts UTF-8 bytes conservatively. An external tokenizer callback can replace it; exactness is explicit. Token counts are checked before conversion to SQLite integers. Compilation includes its actual rendered labels and reserves output capacity. Overflow is a hard error; recommendation distinguishes normal/high/emergency pressure and an irreducible blocked context. Recommendations describe eligible positive-benefit, closed ranges, not a promise that any arbitrary summary is good.

The native driver now caps management rounds, suppresses repeated identical failures, records typed usage/unknown output reservations and supplies transient current-generation guidance. Its scripted/HTTP evidence is in [task-driver.md](task-driver.md). Automatic growth/pressure cadence, exact full-request input/delegation/cost budgets, real-model effects and cache economics remain open. Optional absorption/transforms/steering remain separately tracked. No provider cache is treated as evidence that omitted source is resident.

## Local regressions added during construction

- BM25 scores must use SQLite floating-point columns, not integer truncation.
- Volatile generation headers invalidated the earliest prompt prefix on every append; generation is now out of band.
- A multi-allocation arena result must finish every allocation before moving the arena into the returned owner. A 160-operation seeded mixed-history regression exposed this leak; the failing evidence was not counted as a passing run.
- Unrelated SQLite databases must not be switched to WAL or receive ZeroRepeat tables merely because a user supplied their path.

These are source/runtime-tested local contracts. Real-model behavior and complete-harness correctness are separate acceptance requirements.
