# ZeroRepeat working agreement

## Local storage

Use `/Users/utkarshrajput/Library/Application Support/Local AI Workspaces` for new AI working files, scratch and generated outputs. Resolve `~/Documents/ChatGPT` or `~/Documents/Codex` before writing and use these compatibility paths only when they point into that local workspace. This project's resolved root is `/Users/utkarshrajput/Library/Application Support/Local AI Workspaces/ChatGPT/Harness`. Keep existing files/history and unrelated iCloud syncing intact; do not put new AI outputs in other synced folders unless explicitly requested.

## Every turn, including after context compaction

1. Read `docs/STATE.md`, `docs/TASKS.md`, and the newest entries in `docs/LOG.md` before changing code. Read `docs/PLAN.md` for the full release contract; chat summaries never replace it.
2. Inspect Git status and the actual files/processes/test evidence. Treat old status notes as pointers, not proof.
3. Append a dated start entry to `docs/LOG.md`: the current request, inspected state, and concrete next action. Append progress at meaningful checkpoints and an end entry before replying.
4. Update `docs/STATE.md`, the task list, and `docs/COVERAGE.tsv` when authoritative state changes. Preserve unresolved requirements and exact next steps. Never mark the complete harness finished because one component passes.
5. Save evidence and findings with source revision and limitations. Distinguish observed, source-established, inferred, proposed, and unknown facts. Record corrections explicitly.
6. Commit and push project work and continuity records to GitHub at meaningful checkpoints and before ending an active work turn. The user explicitly authorized a public repository: `https://github.com/1Utkarsh1/ZeroRepeat`. Verify the remote branch SHA against the intended local commit before claiming it is uploaded. Preserve unfinished work and report actual push failures; never force-push or rewrite history to conceal divergence.

## Non-negotiable scope

- All first-party runtime, compiler, CLI/TUI, SDK, orchestration, adapters, and tests are Zig. No Python prototype or Python implementation. Established native C libraries and unmodified external tools are allowed.
- Build the full coding harness from `docs/PLAN.md`: do not silently reduce it to a context plugin, wrapper, or benchmark demo.
- Initial reference model: `Qwen/Qwen3.8-27B`. Current total cloud budget: US$7. Build and verify locally first; benchmarks are later. No paid resources during the current construction stage.
- Context must be sufficient for each actual inference. Prior transmission and object IDs do not establish model residency. Missing bases require rehydration.
- Preserve user data, detect stale edits, and never replay an uncertain mutating action automatically after a crash.
- Use the reverse-engineer-anything skill for evidence-driven source/artifact investigation. Complete source repositories use normal repository tools; invoke REA only for evidence requiring shipped artifacts/runtime analysis. Use relevant tools rather than calling unrelated tools for coverage.
- The billion-context integration must be native Zig, traceable to reviewed upstream mechanisms, and tested. Do not install its proxy or rewrite other clients' configuration as a substitute.

## Completion and handoff

`docs/COVERAGE.tsv` tracks requirements, evidence, acceptance tests, and dispositions. Pending rows remain visible. The broader release remains incomplete until all required rows have real implementation and verification evidence. Log exact test commands/results, remaining failures, the verified GitHub checkpoint, cloud resource IDs/spend if any, and the next work item. Never persist API keys or credentials in these records.
