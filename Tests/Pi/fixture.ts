// In-process provider for the opt-in Pi host check. Never contacts a model service.
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
    pi.on("before_agent_start", async (_, ctx) => { await ctx.ui.confirm("Test", "Continue?"); });
    pi.registerProvider("fixture", {
        api: "fixture-api", baseUrl: "http://127.0.0.1", apiKey: "fixture",
        models: [{ id: "local", name: "Local", reasoning: false, input: ["text"],
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 32768, maxTokens: 512 }],
        streamSimple(model, _context, options) {
            const stream = createAssistantMessageEventStream();
            const failure = process.env.AW_FIXTURE_OUTCOME === "error";
            const message = { role: "assistant" as const, api: model.api, model: model.id, provider: model.provider,
                timestamp: Date.now(), content: [{ type: "text" as const, text: "ok" }],
                usage: { input: 8, output: 2, cacheRead: 0, cacheWrite: 0, totalTokens: 10,
                    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
                stopReason: "stop" as const };
            const timeout = setTimeout(() => {
                if (failure) stream.push({ type: "error", reason: "error", error: { ...message, stopReason: "error", errorMessage: "fixture" } });
                else stream.push({ type: "done", reason: "stop", message });
                stream.end();
            }, 900);
            options?.signal?.addEventListener("abort", () => {
                clearTimeout(timeout);
                stream.push({ type: "error", reason: "aborted", error: { ...message, stopReason: "aborted" } });
                stream.end();
            }, { once: true });
            return stream;
        },
    });
}
