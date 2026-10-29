# Initial native provider protocol

The native components are `provider_request.zig` (typed request/history validation), `provider_stream.zig` (incremental SSE response decoding) and `context_tools.zig` (strict native context operations). They are exported through `root.zig`. HTTP transport, endpoint capability negotiation and the actual bounded task loop remain the next work items.

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
