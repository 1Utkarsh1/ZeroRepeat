# Native context, continuity and protocol verification — 30 October 2026

Scope: the current native component foundation and its exported Zig callers. **The complete ZeroRepeat harness and active goal remain unfinished.** The unchanged `../PLAN.md` is the release contract. Implementation hashes are recorded in `2026-10-30-source-manifest.sha256`; primary implementation source revision is `28e053d63f586185b4e12ef61ef951edc0c3fd59`. Subsequent handoff commits change records/evidence only. Published upstream performance claims and real-model behavior are not evidence for these results.

## Observed results

| Check | Result | Raw evidence |
|---|---|---|
| Integrated macOS ARM64 Debug tests | 79/79 passed, no reported allocator leaks: 76 core, 2 CLI parser, 1 actual child-process stdout regression | `2026-10-30-native-tests.txt` |
| Focused continuity suite | 10/10 passed, including removal of each of the 70 baseline IDs and unresolved reference-audit release rejection | `2026-10-30-continuity-tests.txt` |
| Native executable build | Succeeded | `2026-10-30-native-build.txt` |
| Linux x86_64-musl safe cross-build | Succeeded; file inspection identifies a statically linked ELF x86-64 executable; not executed | `2026-10-30-linux-cross-build.txt`, `2026-10-30-linux-artifact.txt` |
| SQLite linkage and configuration | Bundled 3.54.1; FTS5/THREADSAFE/OMIT_LOAD_EXTENSION assertions pass; native dynamic linkage lists only libSystem | `2026-10-30-doctor.txt`, `2026-10-30-native-linkage.txt`, source test in `src/root.zig` |
| CLI subprocess persistence workflow | Fresh initialized database, immutable exact retrieval, stable compiled prefix, nonce search through folded originals, deep expansion, versioned refold, rule retirement and stale generation rejection pass | `2026-10-30-context-cli-smoke.txt` |
| Continuity audit | Full plan/state/tasks/log and coverage records validated; required/research work remains visible | `2026-10-30-continuity-check.txt` |
| Release gate | Expected failure while required work and reference audits remain unfinished | `2026-10-30-release-gate.txt` |
| Re-entry | Current state/tasks plus bounded recent log emitted; full original plan retained | `2026-10-30-reentry.txt` |

The smoke workflow used a random 128-bit nonce absent from its summary. Every CLI operation ran in a separate process and reopened the same database. `cmp` verified retrieved original bytes and unchanged compiled bytes across retrieval; a generation-6 mutation was rejected after state reached generation 10. The disposable fixture path is recorded in `2026-10-30-context-smoke-path.txt`; it is local scratch, not a release dependency.

## Exact verification commands

Run from `/Users/utkarshrajput/Documents/ChatGPT/Harness`:

```sh
zr_zig=/Users/utkarshrajput/.cache/zerorepeat/bootstrap/zig-aarch64-macos-0.17.0/zig
zr_cache=/Users/utkarshrajput/.cache/zerorepeat/zig-local
zr_native=/Users/utkarshrajput/.cache/zerorepeat/build/native/bin/zerorepeat
"$zr_zig" build test --cache-dir "$zr_cache" --summary all
"$zr_zig" test src/continuity.zig --cache-dir /Users/utkarshrajput/.cache/zerorepeat/continuity-tests
"$zr_zig" build --cache-dir "$zr_cache" --prefix /Users/utkarshrajput/.cache/zerorepeat/build/native --summary all
"$zr_zig" build -Dtarget=x86_64-linux-musl -Doptimize=safe --cache-dir "$zr_cache" --prefix /Users/utkarshrajput/.cache/zerorepeat/build/linux-x86_64-musl --summary all
"$zr_native" doctor
"$zr_native" continuity check
"$zr_native" continuity context
"$zr_native" continuity check --release
shasum -a 256 -c docs/evidence/2026-10-30-source-manifest.sha256
```

The last continuity command is deliberately expected to return nonzero. The test build steps always execute tests rather than reuse cached passing executions; compiled artifacts may still be reused. Compiler 0.17 accepts `safe`, not `ReleaseSafe`, and this build command has no `--global-cache-dir` option. Earlier documentation spelling those flags differently is superseded by these actual successful commands.

## What the tests establish

- Original events keep distinct identities even with equal bytes; immutable BLAKE3 payloads deduplicate and are verified on read. IDs, summary versions, rules and counters survive reopen.
- Invalid or overlapping fold batches, stale generations, invalid summaries and protected/partial groups do not partially commit. Hierarchy tests cover exact direct/transitive membership and reversible T1/T2/T3 views. A separate regression reopens the persisted three-tier database before shallow restoration, reopens again before deep restoration, and verifies exact original refs, roles, kinds, order and bytes.
- Bounded offloaded-result retrieval returns exact bytes, preserves the folded prefix, and reports missing/corrupt data. FTS5 lexical BM25 finds original history absent from summaries and returns source/owning-block references. This is not fuzzy/CJK/embedding parity.
- Supersession, user corrections and source authority are enforced locally; tool/model text cannot create privileged rules. Pending task jobs and complete provider history reconstruction remain open.
- Compilation is deterministic for unchanged state, append preserves preceding bytes, and irreducible context overflow is explicit. Counts are conservative UTF-8 byte estimates unless an exact tokenizer callback is supplied; they are not Qwen/provider token measurements.
- The SSE decoder's 15 tests cover arbitrary network splits, UTF-8, CRLF/BOM/comments/multiline events, interleaved arguments, distinct call IDs with repeated function names, reasoning aliases, strict usage, truncation, malformed arguments, limits and allocation failures. Completed calls are exposed only after the final stream validates.
- The typed context dispatcher validates entire bounded requests before effects, rejects duplicate/unknown fields, and exposes no privileged rule or file-edit operations. Allocation-failure sweeps distinguish `CommittedResultUnavailable` from a failure before mutation; callers must inspect rather than replay uncertain effects.
- Integration fixtures feed byte-fragmented SSE into that decoder, dispatch the resulting native fold/retrieval calls, and recover an original-only nonce. These fixtures do not implement HTTP or a model/task loop.
- The coverage checker retains all 70 original IDs/kinds and requires revisions/evidence for completed rows. Release mode rejects required pending work and unresolved reference audits. Evidence-file presence is not a proof that its conclusions are true.

## billion-context fit and adoption boundary

Source audit: `../research/billion-context.md`, revision `52567f19bd7846e3fb91d7513c949b0751cd1c47`, package 0.1.206 / acp-kernel 0.0.163. It is useful prior art for reversible hierarchical context, immutable originals, protected groups, stable references, search/retrieval, pressure guidance and cache-aware rendering. Those mechanisms fit the content-addressed native design. Its npm proxy, certificate interception, client installers/updaters, and GUI do not constitute a ZeroRepeat integration and were not installed.

Native adoption is traceable through the 22 BC rows, source files and tests. BC-01/03/07/08/09/10/12/19 have component-level acceptance evidence here. Hierarchy's cross-session reference guard, provider alias/group reconstruction, pending-job protection, bounded management rounds/transient chatter, complete accounting, and process-crash/disk-full injection remain in progress. Optional absorption/transforms/steering are still separate investigations.

The exact upstream license is retained in `LICENSES/billion-context.txt`, including its additional visible attribution term. README, help/version and doctor credit billion-context/acp-kernel and show both upstream links. No billion-token resident window or independent savings result is claimed.

## Durable continuity and recovery

`AGENTS.md`, complete `PLAN.md`, current `STATE.md`, `TASKS.md`, append-only `LOG.md` and `COVERAGE.tsv` are the canonical re-entry records. The explicit personal memory pointer exists at `/Users/utkarshrajput/.codex/memories/extensions/ad_hoc/notes/2026-10-25T073047Z-zerorepeat-continuity.md`; unrelated memories were not edited. The native log uses an exclusive lock and sync, preserves earlier bytes, and re-entry reads a bounded tail without deleting the full log.

The initial fresh build was observed blocked in `preadv` on a dataless Zig standard-library file. File flags also established placeholders for SQLite, source and Git metadata. This was an input-materialization failure before test execution. The old compiler's later exit-137 attempt yielded no usable doctor evidence; this record uses the reacquired compiler and successful current binary instead. No signature/security setting was changed.

Pinned Zig archive SHA-256: `b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a`. SQLite was reacquired from the pinned official archive; its shipped SHA-256 remains `0c657666d819f261cc4007526ad57e1669de9949df7a8ea847aa284a2bf0ee52`. Current toolchain/build caches live outside Documents.

`context.zig` was recovered by replaying its 11 recorded patches and formatting: 49,939 bytes, matching original metadata. The 1,919-byte build file and 409-byte package manifest were recovered from recorded complete successful reads. Original placeholder inodes are preserved under `.research/offloaded-originals/`, not discarded. Reconstructed current files then passed compilation/tests and are hashed in the manifest.

Original `.git` remains intact. Status initially blocked on placeholder metadata, including `.git/info/exclude`; after materialization it completes and confirms no previous commits on main. Byte comparisons against the now-readable preserved originals verify the recovered source/build bytes exactly; see `2026-10-30-source-recovery.txt`. A separate local recovery Git directory was initialized at `/Users/utkarshrajput/.local/share/zerorepeat/checkpoints/harness.git`, with this workspace as `--work-tree`. Its initial source snapshot is `aa425f52330194f7500a83f7e1a8d84b3ccd7a73`; this independent recovery commit has the same implementation hashes and plan, plus the binary manifest. A complete bundle was verified and restored to `restored-2026-10-30` beside it. Source hashes, original-plan comparison, continuity audit, clean checkout and `git fsck --full --no-reflogs` all passed in that clone. The bundle is refreshed with final handoff records before the turn ends. A local snapshot improves recovery across chat compaction and cloud-placeholder problems. It is not an offsite backup or a guarantee against physical disk loss.

## Corrections and remaining risks

The earlier coverage checker guarded only the 18 ZR IDs; claims that it protected every original requirement/reference were too broad. It now tests removal of each of all 70 baseline IDs, original kinds, completion revisions, and pending reference-audit gating. Future newly discovered feature IDs must also be retained when the audit expands the contract.

The combined CLI smoke log exposed a positional stdout writer overwriting prior redirected output. Streaming stdout fixes this, and a native subprocess regression verifies two consecutive commands preserve both their output and an earlier shared-file prefix. The refreshed smoke log contains the entire workflow.

Not verified: actual Linux execution, HTTP/model connections, quality of model-written summaries, cross-session references, pending-job protection, injected process death/disk-full, full semantic graph/retention/backup, official benchmark results, or competitive superiority. All full-harness subsystem rows remain open. No paid inference, Runpod deployment, proxy installation, or client configuration rewrite occurred.

## Local recovery commands and checkpoint details

The working source commit is on `Utkarsh/native-context-foundation`. The independent recovery Git directory is outside Documents; its commit IDs differ from the primary repository because it has its own snapshot history. The source/dependency manifest proves the implementation bytes match. Bundle path: `/Users/utkarshrajput/.local/share/zerorepeat/checkpoints/zerorepeat-native-context-2026-10-30.bundle`. Verified restore path: `/Users/utkarshrajput/.local/share/zerorepeat/checkpoints/restored-2026-10-30`. The adjacent `2026-10-30-checkpoint-receipt.txt` records final primary/recovery revisions and the bundle checksum.

```sh
git bundle verify /Users/utkarshrajput/.local/share/zerorepeat/checkpoints/zerorepeat-native-context-2026-10-30.bundle
git clone --branch Utkarsh/native-context-foundation --single-branch /Users/utkarshrajput/.local/share/zerorepeat/checkpoints/zerorepeat-native-context-2026-10-30.bundle /new/physical/restore/path
# In the restored directory:
shasum -a 256 -c docs/evidence/2026-10-30-source-manifest.sha256
git fsck --full --no-reflogs
```

The original source commit succeeded. Its automatic Git maintenance then blocked reading an older Codex checkpoint ref; the owned housekeeping child was terminated, and the commit command completed with exit 0. Later checkpoint commands disable automatic maintenance for that command only. Existing Codex refs/history, hooks, global configuration and security settings were not replaced. Broad whitespace checking flagged existing blank final lines in the exact upstream license and raw command reports; those evidence bytes were preserved, and authored source/records passed the scoped check.

The user subsequently authorized a public GitHub repository and regular pushes. `2026-10-30-github-publication.md` records the verified publication and supersedes the earlier absence of an offsite tracked-source copy; local recovery remains available.
