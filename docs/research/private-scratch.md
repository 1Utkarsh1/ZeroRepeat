# Fresh private execution scratch and hardlink correction

Source checkpoint: `native-private-scratch-2026-11-01`. Exact inputs are in `../evidence/CURRENT_SOURCE.sha256`.

## Reproduced defect

The initial isolated-execution source `918d4fafa48a58d28988071553abc46ed151d8f0` (documentation head `b898852c3676b8d840ee76f89536a241fbeb2588`) accepted a caller-supplied existing scratch tree and granted it writable access. On macOS, a pre-existing hardlink there could alias a workspace or outside file. Writing that path changed the original inode despite the source path's read-only rule.

An independent disposable-fixture probe reconstructed the current policy without extra grants. It compared actual source bytes, hashes, device/inode/link counts and sizes. Every shell deliberately exited zero, so exit status alone was not treated as preservation evidence.

| Case | Observed result at the affected source |
|---|---|
| Child creates workspace-to-scratch hardlink | Creation denied; original unchanged |
| Scratch already contains a source hardlink | Writing succeeds; same inode/link count two, original bytes changed |
| Scratch already contains an outside-file hardlink | Outside original changes through its scratch alias |
| Child-created or pre-existing source symlink | Target write denied; original unchanged |
| Fresh child beneath an alias-containing parent | Parent/source/explicit-readonly aliases denied; internal child links work |

The original source/alias inode `78515268` changed from 27 original bytes to 13 bytes while retaining link count two. The outside-file case similarly changed inode `78515343`. These are owned fixtures, not user files. This explicitly corrects the earlier blanket read-only-workspace claim for arbitrary existing scratch trees.

Raw observations are `../evidence/2026-11-01-scratch-alias-observed.txt` and `2026-11-01-scratch-private-child-observed.txt` beside it. Complete profiles/commands and 42 verified checksums remain locally at `/Users/utkarshrajput/.cache/zerorepeat/execution-hardlink-review.vwxOcU/`; manifest SHA-256 is `8049513e4320b0739559b555b9ce827fefab046a0a5b303f86e0162fca964d77`. Probe differences: it launched sandbox-exec from a shell, without the native journal/capture path. The subsequent Zig regressions exercise the native factory and executor. No probe script is introduced as a runtime/test implementation.

## Native correction and SDK contract

`Config.scratch` now means a **caller-owned private parent**, with permission bits 0700 and no extended/default ACL. The runtime rejects unsupported permissions/ACLs; it does not chmod, clear ACLs or remove existing caller data. Workspace/parent overlap and explicit read-grant overlap remain rejected.

On every `Execution.open`:

1. Validate the physical parent, owner, permissions, ACL and active-store boundary.
2. Obtain 128 bits using fallible secure entropy, with no weaker fallback.
3. Exclusively create a new random 0700 child; an existing-name collision fails without adoption or removal.
4. Validate that child and grant read/write access only to it. The parent receives ancestor metadata access, not data/write access.
5. Set HOME/TMPDIR and advertised `exec.policy` scratch path to that child.

The same live capability can reuse its child for caches. A new/reopened capability always creates a new child and never adopts older output trees. Callers must derive cache/artifact paths from `execution.scratch.path` after opening, rather than from the configured parent. All in-repository callers and the real compiler fixture use that path.

Before commands, parent/child directory identities, owner/permissions and ACL requirements are rechecked. On close, the original child handle remains held during identity validation and attempted empty-directory removal. Replaced directories are preserved. Nonempty caches/artifacts and every pre-existing parent entry remain intact. Retention/garbage collection is still separate required work.

The process/journal/schema-four contracts remain unchanged. Actual private child paths enter policy evidence and execution records. No uncertain command is replayed.

## Verified scope and limits

Native suite: **170/170** (164 core, two CLI parser, one stdout subprocess, three process tests). Seven new regressions cover:

- Pre-existing workspace/outside hardlinks in the parent, with inode/link metadata and exact originals preserved.
- Permitted internal child hardlinks and ordinary cache writes.
- Fresh child on reopening while old nonempty artifacts remain retained.
- Permission/identity replacement rejection before command intent; close preserves a replacement.
- Unsupported parent ACL rejection without modifying caller permissions/content.
- Allocation failures before/after child creation, with no leaked handles or empty owned trees.
- Entropy failure and name collisions without fallback, adoption or deletion.

Existing real Zig compile/fail/versioned-repair/pass, cancellation, output, network/nested restrictions and uncertainty tests remain included. Linux static build/link passed; Linux runtime and cross-filesystem behavior remain unverified. Raw final reports are `2026-11-01-private-scratch-native-tests.txt`, `2026-11-01-private-scratch-native-build.txt` and `2026-11-01-private-scratch-linux-build.txt` in `../evidence/`.

**Host ownership assumption:** unsandboxed code running as the same host user remains trusted. It can inject an alias into a private child after creation; directory permissions and last-check identity observations cannot defeat that actor. The caller must not externally populate, reuse or mutate the live private child. macOS session-escaping descendants, parent-crash cleanup and general writable workspaces remain open. This is a correction of the observed pre-existing-tree bypass, not a universal sandbox audit.

The reverse-engineer-anything source/runtime evidence workflow was used, including independent scoped investigation. No user files, credentials, configuration, installs, network or paid resources were used in the probes. Full task verification/completion/resume/CLI remains the next implementation item; all other release requirements stay in the canonical plan and coverage ledger.
