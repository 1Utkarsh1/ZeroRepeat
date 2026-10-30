# Initial native provider protocol

The initial native components are `provider_request.zig` (typed request/history validation), `provider_stream.zig` (incremental SSE response decoding) and `context_tools.zig` (strict native context operations). They are exported through `root.zig`. Subsequent native HTTP and bounded task-driver checkpoints are described below. Endpoint capability negotiation and the complete coding workflow remain open.

## Source-established model constraints

The official [Qwen3.8-27B model card](https://huggingface.co/Qwen/Qwen3.8-27B) was re-read on 30 October 2026. Its examples retain returned reasoning in assistant `reasoning_content` and request streamed usage. The native request codec preserves this field by default; it can explicitly encode the newer `reasoning` field, and rejects reasoning when configured unsupported rather than silently dropping it. Real endpoint compatibility for either alias still requires validation.

The reviewed [Qwen template](https://huggingface.co/Qwen/Qwen3.8-27B/blob/1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0/chat_template.jinja) is pinned to the main revision returned by the official model API: `1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0`. It requires a user query and a system message only at the beginning. Tools are rendered as their complete JSON definitions. Its default preserved-thinking behavior makes unlabelled reasoning removal an invalid efficiency assumption. This source review downloaded no weights and executed no template or model code.

The [vLLM reasoning documentation](https://docs.vllm.ai/en/latest/features/reasoning_outputs/) describes its output field rename from `reasoning_content` to `reasoning`; the response decoder accepts both and rejects conflicting simultaneous content. Endpoint/version pinning is still required before a real run. This is source-established compatibility guidance, not a tested deployment.

## Request contract and local evidence

`encode` returns a complete stateless Chat Completions JSON body for the initial text/function-tool flow. It retains every supplied message, explicit reasoning and exact tool-argument string. It does not replace source with handles or claim model residency. It requests one streamed choice and final usage, and reserves a configured `max_tokens` output cap. Optional temperature is finite and bounded; no reasoning or preservation control is silently changed.

The request must contain a user query and at most one initial system message. Tool calls have unique IDs across the request, complete JSON-object arguments, valid metadata, and exactly one result each. Parallel results may appear in either order, but another user/assistant/system message cannot interrupt an unresolved burst. Malformed, orphaned, repeated, or unfinished exchanges are rejected before transmission. Historical tool names need not remain in the currently exposed tool set, allowing future tool pruning without invalidating history.

Schemas are parsed at the wire boundary; malformed/duplicate-key JSON, unsupported tool kinds/fields, invalid schema field types and duplicate function definitions are rejected. Only implemented capabilities from the native context registry are encoded. This validates the protocol shape, not arbitrary JSON Schema semantics or a model's choice of tool.

Defaults bound raw/encoded request bytes to 8 MiB, messages to 4,096, tool definitions and per-message tool calls to 256, and each argument string to 1 MiB. Byte accounting checks cumulative supplied input before parsing, counts the actual escaped output without allocating that output, then allocates exactly the permitted size. These are byte/resource limits, not Qwen tokenizer counts or a completed task budget.

The integrated run passed **88/88 tests**, including eight request-codec tests, the actual context-schema integration fixture, and the prior decoder/context/CLI suite. Raw results: `../evidence/2026-10-30-provider-request-integrated-tests.txt`. Allocation-failure sweeps and exact-size/escaped-byte tests passed. Current implementation hashes are in `../evidence/CURRENT_SOURCE.sha256`; historical foundation manifests remain preserved at their named source revisions.

Missing: HTTP transport/status/retry handling, cancellation/deadline validation, Responses/Anthropic/media adapters, actual provider history reconstruction from context state, session/branch binding, aggregate accounting and the full coding loop. No live model request or competitive result is implied by these tests.

## Native HTTP transport checkpoint

The subsequent `native-provider-http-2026-10-30` checkpoint adds `provider_http.zig` and local Zig network fixtures. The module accepts a caller-owned `std.http.Client`, a full endpoint, explicitly supplied credential, typed request and byte/time limits. It reads no credential environment variables, installs no proxy, and changes no client configuration. The caller must keep the client alive, use a thread-safe allocator and deinitialize each returned `Outcome`.

Endpoint validation rejects embedded URL credentials, queries/fragments and header/control injection. HTTPS is the default; plain HTTP requires an explicit option and a literal loopback host (127.0.0.1 or ::1). System TLS verification is left enabled. Real HTTPS/model-server interoperability has not been run in this stage; runtime fixtures only connect to their own loopback server and use a nonsecret fixture credential.

A call makes one POST after validation and request construction. It does not retry or follow redirects. One absolute monotonic-awake deadline includes preflight and the network exchange; an already expired request is rejected before transmission. Deadline/caller cancellation joins owned operations and drains any completed allocated reply rather than leaking it. Tests verify both stalled headers and a stalled body, external cancellation, and empty connection pools afterward. A timeout or disconnect may occur after server execution; callers must not assume the server did nothing or replay a tool action.

Successful HTTP responses require status 200, an SSE media type and identity content encoding. The HTTP parser handles framing; payload slices feed the bounded decoder incrementally. No tool call is returned until HTTP/SSE completion validates. The API returns the final validated reply; live UI delta callbacks are not implemented. Length/content-filter finishes remain typed reply reasons, not evidence that a task succeeded.

HTTP rejection returns status/category, optional numeric Retry-After seconds and whether the bounded error body was truncated. Authentication, rate limit, server, redirect and recognized context-limit codes have explicit categories. Retry-After dates/duplicate/invalid values remain unknown; no automatic backoff occurs. Error-body reads are capped at 4,097 bytes (4,096 retained for code inspection); raw server messages are not retained or promoted to instructions. Allocation failure is reported rather than guessed into a model-error category. Full safe provider diagnostics/redaction and durable failure events remain open work.

New verification:

- **100/100 integrated native tests passed**: 97 shared-core tests, 2 CLI parser tests and 1 CLI subprocess regression. Raw report: `../evidence/2026-10-30-provider-http-integrated-tests.txt`.
- **34/34 focused HTTP/request/stream tests passed**, using actual ephemeral loopback TCP servers and HTTP requests. Raw report: `../evidence/2026-10-30-provider-http-tests.txt`.
- A real local HTTP response returned an `act` call which the native dispatcher validated and applied. The request carried actual compiled context and registered schemas; after folding, the current requirement stayed live and the exact original-only nonce was retrieved. This is a scripted provider fixture, not model reasoning or the complete agent loop.
- Native build/doctor passed. The doctor accurately reports that transport exists in the Zig module and that no CLI agent/model loop is exposed.
- Linux x86_64-musl semantic compilation of the HTTP tests passed with `-fno-emit-bin`; Linux execution was not performed. A separate CLI cross-build remains bounded by its raw report.

During development, a regression established that `std.Uri` retains brackets around the IPv6 loopback host; the explicit loopback check now accepts that representation. Error-code parsing was also corrected to propagate OOM instead of silently misclassifying it. Final tests include both cases.

Commands (compiler/cache paths are the verified locations in `STATE.md`):

```sh
"$zr_zig" build test --cache-dir "$zr_cache" --summary all
"$zr_zig" test src/provider_http_tests.zig --cache-dir /Users/utkarshrajput/.cache/zerorepeat/provider-http-tests
"$zr_zig" test src/provider_http_tests.zig -target x86_64-linux-musl -fno-emit-bin --cache-dir /Users/utkarshrajput/.cache/zerorepeat/provider-http-tests
"$zr_zig" build --cache-dir "$zr_cache" --prefix /Users/utkarshrajput/.cache/zerorepeat/build/native --summary all
"$zr_zig" build -Dtarget=x86_64-linux-musl -Doptimize=safe --cache-dir "$zr_cache" --prefix /Users/utkarshrajput/.cache/zerorepeat/build/linux-x86_64-musl --summary all
```

Current full source hashes are in `../evidence/CURRENT_SOURCE.sha256`; earlier dated manifests prove their named historical revisions. At this HTTP checkpoint the task driver, bounded management rounds/transient guidance and durable action/usage records were still pending. No model weights, paid inference or Runpod resources were used.

## Native bounded driver checkpoint

`native-task-driver-2026-10-30` adds `task.zig` and `agent.zig`, with typed scripted and HTTP providers, durable requirement/request/action records, complete-burst validation, conservative recovery, bounded management rounds, transient guidance, output usage reservations and request/tool/wire/output/time caps. Provider reply validation also applies to typed scripted implementations. Twenty-six local regressions exercise these paths; the integrated suite passes 126/126. See [task-driver contract, source review and limitations](task-driver.md) and `../evidence/2026-10-30-task-driver-integrated-tests.txt`.

Complete repository effects, independent verification/resume, live UI delivery, exact input/template/delegation/cost budgets, automatic pressure-triggered compaction, provider variants/media and real endpoint compatibility remain open. The CLI still exposes development context commands; this component does not complete the full coding harness.
