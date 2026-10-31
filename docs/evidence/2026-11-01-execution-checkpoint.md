# Native isolated-execution checkpoint and recovery

Tested source: `918d4fafa48a58d28988071553abc46ed151d8f0`, tag `native-isolated-execution-2026-11-01`, branch `Utkarsh/native-context-foundation`, [public ZeroRepeat repository](https://github.com/1Utkarsh1/ZeroRepeat). Push exited 0. GitHub branch API and Git transport independently matched that branch head, and transport matched the tag. No force/history rewrite occurred. This receipt changes documentation only.

The native suite passed **163/163** (157 core, 2 CLI parser, 1 CLI stdout subprocess, 3 process tests). It includes a scripted driver inspect/edit/check/repair/compaction/retrieval flow with independent host checks, actual isolated Zig compilation failing before a versioned repair and passing afterward, and a native fixture connecting to a live server on the host but denied under isolation. No model reasoning is implied by these fixtures.

Additional checks cover fixed deadlines, closed-pipe and TERM-ignoring processes, ordinary descendant cleanup, cancellation, paired output/caps, exact paging, configured-key redaction, filesystem/symlink/data-volume/nested policy denial, strict whole-burst decoding, task deadline propagation, uncertain receipts, allocation sweeps through final acknowledgement and schema-three migration. The scoped contract/source investigation is [isolated execution](../research/isolated-execution.md).

Evidence files beside this receipt:

- `2026-11-01-execution-native-tests.txt`: 163 passing native tests.
- `2026-11-01-execution-native-build.txt`: 5/5 native build steps.
- `2026-11-01-execution-linux-build.txt`: 20/20 static Linux safe CLI/test/helper build/link steps; no Linux execution.
- `2026-11-01-execution-continuity.txt`: all 70 baseline rows retained; 28 required and 25 reference audits remain open.
- `2026-11-01-execution-release-gate.txt`: expected exit 1, `ReleaseIncomplete`.
- `2026-11-01-execution-doctor.txt`: native storage/search/context probe; no model request.
- `2026-11-01-execution-reentry.txt`: bounded state/task/log snapshot captured during construction; current canonical files remain authoritative.
- `2026-11-01-execution-platform.txt`: observed macOS 27.0.1 build 26A434, installed sandbox/policy hashes and pinned Zig process-source hashes.
- `2026-11-01-execution-binaries.sha256`: observed native/Linux binary hashes, not a reproducible-release claim.
- `CURRENT_SOURCE.sha256`: 33 source/build/dependency hashes for this checkpoint. Only explanatory source comments changed after the final native test run; final native/Linux builds compiled those bytes.

Formatting, whitespace, source hashes and byte equality with the full original plan passed. Physical workspace and new outputs remain under local AI storage outside iCloud Drive. No existing history or unrelated syncing was removed.

Created `/Users/utkarshrajput/.local/share/zerorepeat/checkpoints/zerorepeat-native-execution-2026-11-01.bundle` through a verified `.next` file. It contains complete canonical history, branch and all five provider/task/repository/execution tags. A new owned clone `restored-execution-2026-11-01` beside it restored `918d4fafa48a58d28988071553abc46ed151d8f0` and passed all 33 hashes, exact state/task/log and original-plan comparisons, continuity, Git fsck and clean-worktree checks. Older bundles/clones remain intact. The restore's origin points to the local bundle; GitHub publishing remains from the primary checkout.

After this documentation receipt is committed/pushed, atomically refresh the same owned bundle, fast-forward its restore and repeat comparisons/fsck. Save final verified heads in an external receipt to avoid self-referential tracked hashes. This backup covers tracked history, not ignored caches/research files or all possible storage loss.

The verified ledger has **12 of 40 required rows complete**, 28 required rows open and 25 named reference audits open. All 18 major subsystem contracts remain pending/in progress; row counts do not weight engineering effort. No completion claim follows from the green native suite.

Open work includes Linux runtime, macOS session-escaping descendants/parent-crash cleanup, owned writable execution workspaces, PTY/stdin/jobs, trusted task verification/completion and safe resume/CLI, exact budgets, full graph/editing/Git/memory/skills/subagents/MCP/TUI/ACP and remaining audits. No paid inference, weights, Lightning Studio or Runpod resource was created. Construction cloud spend remains US$0 against the US$7 ceiling; no account-wide billing audit is implied.
