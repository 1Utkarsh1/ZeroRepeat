# Native isolated execution and retained results

Source revision: tag `native-isolated-execution-2026-11-01`. Exact source/build/dependency inputs are in `../evidence/CURRENT_SOURCE.sha256`. This extends repository checkpoint `835a358df78af72fd4b699cb4e5771f82b674146`; the frozen schema-three fixture was extracted from its own SQL declarations.

## Current contract

The host attaches `agent.Options.execution` with an `Execution` capability bound to the same context database. If a repository is also attached, its root must match the execution workspace. The host supplies a physical read-only workspace, a separate writable scratch directory and optional physical read-only toolchain directories. Overlapping workspace/scratch roots, nonphysical roots, root replacement, reachable runtime SQLite stores and unsupported platform/backend combinations are rejected. Configured provider credentials are rejected in command arguments; output containing that credential is redacted before output blobs are committed. This is not detection of every possible project secret.

The model can discover `inspect exec.policy`, invoke `act exec.run` and page stored output with `inspect exec.read`. Run/read operations require the database scope; mutations also require the current generation. Executables are absolute and argv is bounded to 256 strings and 64 KiB combined. Timeout is bounded by host policy and the task's fixed remaining deadline. The model cannot select a backend, grant paths, change environment, enable network or acknowledge uncertainty. Whole-burst validation precedes commands.

The child receives explicit PATH/HOME/TMPDIR/LANG values; a shell can add normal bookkeeping. No parent environment or provider key is inherited. There is no unsandboxed mode or automatic fallback. A missing required backend fails closed. The backend process's observed termination is recorded; unknown output is not interpreted as a passing test.

**Commands read the workspace and write only scratch.** They cannot bypass expected-version source editing. A real Zig test uses explicit scratch caches, fails on an incorrect function result, then passes after a version-checked repair. General tools requiring source-tree writes still need a separately owned writable workspace implementation; this component does not grant write access to the user's checkout.

## Isolation and process lifecycle

macOS uses installed `/usr/bin/sandbox-exec` with a generated deny-default profile. Read/map grants cover selected system runtime paths, workspace, scratch and attached toolchains; only scratch and the null device receive writes. Ancestors receive metadata/existence access. Dyld needs literal root-directory access; it is not a subtree grant. Broad `/System` access is absent because it contains data-volume aliases. Network is not granted. Tests deny outside reads, source mutations, symlink/data-volume aliases, network and a nested invocation attempting to broaden permissions.

Linux uses fixed `/usr/bin/bwrap`, explicit user/PID/network/IPC/UTS namespaces, death-chain handling, a new session, dropped capabilities, clean environment, read-only runtime/toolchain/workspace mounts and writable scratch. Mandatory user namespaces are not a try-if-available option. The normal namespace init helper is retained. Actual Linux execution remains unverified; backend/namespace/mount failures do not cause unrestricted retries. [Pinned bwrap manual](https://github.com/containers/bubblewrap/blob/1fb0aa26d3eb66254f7742e704add7f82f41a582/bwrap.xml), [death-chain source](https://github.com/containers/bubblewrap/blob/1fb0aa26d3eb66254f7742e704add7f82f41a582/bubblewrap.c)

Processes start in a new owned group. Both output pipes drain under an absolute deadline and per-stream byte cap. Timeout, cancellation and output pressure trigger KILL before teardown. After pipe EOF, waiting for termination still has a deadline. A non-reaping wait keeps the owned PID reserved until group cleanup, avoiding identifier reuse. Cleanup blocks cancellation while joining/reaping.

Limits: macOS groups cannot contain descendants deliberately changing sessions/groups. Ignored signal errors or uninterruptible kernel waits prevent a universal hard cleanup-time guarantee. Parent crash can leave macOS children without the owner's deadline. Linux namespace/death behavior needs runtime tests. PTYs, interactive stdin, jobs and persistent shells remain open. Pending asynchronous read bytes can be omitted on interruption; output is labelled incomplete.

## Durability and re-entry

Schema four adds typed execution-run and argv tables. Policy bytes and bounded permitted output use immutable BLAKE3 blobs. Versions one/two/three migrate transactionally; source, file versions, metadata and action classification remain retained. Future/incomplete schemas are rejected.

A durable started record precedes spawn, linking action, expected generation, roots, backend and policy/argv evidence. A live owned PID is recorded after spawn. Known results commit termination kind/value, reason, output hashes, incomplete/redacted flags and elapsed time. Model prose cannot establish verification. Productive execution exchanges survive later context-management projection.

Failures after intent publication can follow effects. They become attention or an unavailable journal; dispatch maps these to `CommittedResultUnavailable`. Failed final action acknowledgement also leaves uncertainty. No command is repeated. Trusted owner-exit recovery marks unresolved records for attention; it never signals a historical PID or replays work. Host review advances generation to fence earlier responses. Full task reconciliation/resume/completion and general crash/retention/backup remain open.

## Source investigation and corrections

The reverse-engineer-anything source workflow included independent read-only process/isolation review. Complete source and installed policy text were available; unrelated artifact tools were not invoked. Review covered pinned Zig APIs and two Codex policy files, not the full Codex audit.

- Pinned Zig 0.17 `std/process/Child.zig` and `std/Io/Threaded.zig` show default kill sends TERM to one PID and waits, while canceled wait cleans handles. This executor signals before protected wait.
- `std/Io/File/MultiReader.zig` supports paired draining but grows buffers; explicit caps and one deadline are added.
- WNOWAIT leaves the child waitable before cleanup/reaping. Darwin flags match the installed SDK. [Linux wait manual](https://man7.org/linux/man-pages/man2/waitid.2.html)
- Installed Apple `/System/Library/Sandbox/Profiles/system.sb` and `dyld-support.sb` explain literal-root, executable-map and ancestor permissions. Initial minimal probes omitted exit status and did not prove success. Observed startup SIGABRTs were then fixed with narrow grants, without a data-volume subtree allowance.
- The first high-level network fixture panicked on legitimate sandbox PERM in pinned `Threaded.posixConnect`. The standard library remains unmodified. A test-only native C-ABI socket probe reports errno: it connects to a live host server outside isolation and is denied inside.
- Codex policies were reviewed at `67f0994b532b8740f14b5b738af7b7b2a915b1d6`. Their curated/default-deny approach informed the boundary; no policy file was copied/installed. [Base](https://github.com/openai/codex/blob/67f0994b532b8740f14b5b738af7b7b2a915b1d6/codex-rs/sandboxing/src/seatbelt_base_policy.sbpl), [restricted defaults](https://github.com/openai/codex/blob/67f0994b532b8740f14b5b738af7b7b2a915b1d6/codex-rs/sandboxing/src/seatbelt_read_only_platform_defaults.sbpl)

## Verification

Native suite: **163/163** (157 core, two CLI parser, one CLI stdout subprocess, three process tests). Nineteen extend the previous 144: 14 executor tests, three driver tests, one network probe and one real Zig compile/repair. Coverage includes scope/schema, whole-burst rejection, deadlines, both streams/caps, closed-pipe/TERM-ignoring processes, ordinary descendants, cancellation, read/write/network/nested restrictions, credentials, migrations, private/nonphysical roots, paging, allocation sweeps through final acknowledgement and failed receipts.

The driver fixture performs inspect/edit, failing shell check, repair, successful check, compaction and retrieval; the independent host checks source and runs fresh verification. A separate process test compiles/executes actual Zig tests through the same executor before/after versioned repair. These are deterministic fixtures, not real-model reasoning, general completion or official benchmark results.

Reports beside `../evidence/`: `2026-11-01-execution-native-tests.txt`, `2026-11-01-execution-native-build.txt`, `2026-11-01-execution-linux-build.txt`. Linux is build/link evidence only. Cross-built test options refer to builder paths; rebuild with the Linux toolchain for runtime testing.

~~~sh
zr_zig=/Users/utkarshrajput/.cache/zerorepeat/bootstrap/zig-aarch64-macos-0.17.0/zig
"$zr_zig" fmt --check src build.zig
"$zr_zig" build test --cache-dir /Users/utkarshrajput/.cache/zerorepeat/zig-local --summary all
"$zr_zig" build --cache-dir /Users/utkarshrajput/.cache/zerorepeat/zig-local --prefix /Users/utkarshrajput/.cache/zerorepeat/build/native --summary all
"$zr_zig" build test-build -Dtarget=x86_64-linux-musl -Doptimize=safe --cache-dir /Users/utkarshrajput/.cache/zerorepeat/zig-local --prefix /Users/utkarshrajput/.cache/zerorepeat/build/linux-tests --summary all
~~~

All first-party implementation/tests remain Zig, with SQL fixtures and native C dependencies/interfaces. No paid inference or cloud resource was created. A free CPU Linux VM could support runtime checks, subject to actual namespace permissions; no Lightning Studio was provisioned/authenticated. The US$7 ceiling is untouched.
