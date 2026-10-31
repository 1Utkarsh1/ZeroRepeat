# Native repository checkpoint and recovery

The tested implementation is commit `835a358df78af72fd4b699cb4e5771f82b674146`, tag `native-repository-edits-2026-11-01`, on `Utkarsh/native-context-foundation` at [the public ZeroRepeat repository](https://github.com/1Utkarsh1/ZeroRepeat). The repository visibility was read as public. Push exited 0; GitHub's branch API and `git ls-remote` independently returned that exact commit, with the tag also matching. No history was rewritten. This documentation receipt follows that verified source commit without changing runtime source.

Native verification passed **144/144**: 140 core, two CLI parser, one CLI subprocess and one process-recovery test. The actual owned child processes were SIGKILLed after staging and after exchange; the parent waited for signal termination, reopened storage, verified current/retained bytes and checked that a new edit remained blocked pending review. The 14 repository tests and three new driver tests also exercise expected-version checks, UTF-8/newlines, multi-file preflight/partial publication, metadata/ACL preservation, configured-key rejection, no-follow and active-store protections, allocation/receipt failures, v2-to-v3 migration and productive edit evidence surviving a later context fold.

Exact contract/source investigation: [repository editing](../research/repository-editing.md). Raw reports:

- `2026-11-01-repository-native-tests.txt`: native test command, 144/144 pass.
- `2026-11-01-repository-native-build.txt`: native build, 5/5 steps.
- `2026-11-01-repository-linux-build.txt`: static Linux x86_64-musl `safe` CLI, four test binaries and crash helper build/link, 18/18 steps; no Linux execution.
- `2026-11-01-repository-doctor.txt`: native storage/search/context probe pass; no model request.
- `2026-11-01-repository-continuity.txt`: 70 baseline rows retained; 28 required items and 25 reference audits remain open.
- `2026-11-01-repository-release-gate.txt`: expected exit 1, `ReleaseIncomplete`; the release gate was not weakened.
- `2026-11-01-repository-reentry.txt`: bounded state/tasks/log snapshot captured during the source checkpoint, not a replacement for current canonical files.
- `CURRENT_SOURCE.sha256`: 28 exact source/build/dependency hashes at this tag. `2026-11-01-repository-binaries.sha256`: observed local native/Linux binary hashes; this is not a reproducible-release claim.

Formatting, Git whitespace, all 28 source hashes and byte comparison with the original complete plan also passed. Reproduction commands are in the scoped contract above. The shell invoked installed tools for verification; first-party implementation/tests remain Zig, with SQL fixtures and the unchanged SQLite native dependency.

The physical workspace is `/Users/utkarshrajput/Library/Application Support/Local AI Workspaces/ChatGPT/Harness`; the Documents compatibility path resolves there. New AI working files, outputs, compiler/cache and recovery data are local. Existing history and unrelated iCloud syncing were preserved.

Created a complete-history recovery bundle:

`/Users/utkarshrajput/.local/share/zerorepeat/checkpoints/zerorepeat-native-repository-2026-11-01.bundle`

The bundle contains the primary branch and `native-provider-request-2026-10-30`, `native-provider-http-2026-10-30`, `native-task-driver-2026-10-30`, `native-repository-edits-2026-11-01` tags. `git bundle verify` reported complete history. A new owned clone at `/Users/utkarshrajput/.local/share/zerorepeat/checkpoints/restored-repository-2026-11-01` restored `835a358df78af72fd4b699cb4e5771f82b674146` and passed every source hash, exact state/task/log/original-plan comparisons, continuity, `git fsck --full` and clean-worktree checks. Older recovery snapshots remain intact. The clone's origin points to the local bundle; publishing remains from the primary GitHub-configured checkout.

After this documentation receipt is committed/pushed, refresh that bundle through a verified `.next` file and fast-forward the owned clone, repeat the source/continuity/fsck comparisons, and record final local/remote heads in an external receipt beside the bundle. This avoids a self-referential tracked commit hash. This backup covers tracked project history, not every ignored research/cache file or a guarantee against all storage loss.

Atomic exchange is not a content compare-and-swap. A final-check racing writer's bytes are retained, but the target can already have changed when attention is reported. A multi-file batch can be partially published; nothing automatically replays, rolls back over a possible user edit or garbage-collects retained inodes. Full isolation/conflict UX, unified diffs/create/delete/rename, Git/index/LSP, isolated commands/full coding workflow, task CLI/resume, Linux execution, disk-full/power-loss and real-model verification remain open.

No weights, credentials, paid requests or cloud resources were acquired. Project construction spend remains US$0 against the US$7 total ceiling; this does not imply a fresh account-wide billing audit. The full goal/release is incomplete; next work is policy-backed isolated execution and bounded results through the same driver, then inspect/edit/test/repair/independent verification.
