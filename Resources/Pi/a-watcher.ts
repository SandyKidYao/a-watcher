// Optional Pi extension. All state stays on this Mac.
import { VERSION, getAgentDir, type ExtensionAPI, type ExtensionContext } from "@earendil-works/pi-coding-agent";
import { createHash, randomUUID } from "node:crypto";
import { mkdirSync, realpathSync, renameSync, writeFileSync, unlinkSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export default function (pi: ExtensionAPI) {
    const [major, minor, patch] = VERSION.split(".").map(Number);
    if (major !== 1 || minor < 5 || (minor === 5 && patch < 2)) return;
    const directory = join(process.env.A_WATCHER_DATA_DIR ?? join(homedir(), "Library/Application Support/a-watcher"), "pi-status");
    const instance = randomUUID();
    let status = "unknown";
    let outcome: string | undefined;
    let completions: number[] = [];
    let sessionID: string | undefined;
    let busy = false;
    let waiting = false;
    let timer: ReturnType<typeof setInterval> | undefined;

    function publish(ctx: ExtensionContext, value: string, completed = false) {
        status = value;
        if (!ctx.sessionManager.getSessionFile()) return;
        // One compact, atomically replaced record per session and Pi instance.
        // Never serialize event objects, UI text, messages or tool arguments.
        try {
            const id = ctx.sessionManager.getSessionId();
            if (sessionID !== id) { completions = []; sessionID = id; }
            const time = Math.max(Date.now(), (completions.at(-1) ?? 0) + 1);
            if (completed) completions = [...completions.slice(-31), time];
            const root = createHash("sha256").update(realpathSync(getAgentDir())).digest("hex");
            const name = createHash("sha256").update(id + instance).digest("hex");
            const file = join(directory, name + ".jsonl");
            mkdirSync(directory, { recursive: true, mode: 0o700 });
            const temp = join(directory, "." + randomUUID());
            try {
                writeFileSync(temp, JSON.stringify({ version: 1, id, root, pid: process.pid, status, time, completions, cwd: ctx.sessionManager.getCwd() }), { mode: 0o600, flag: "wx" });
                renameSync(temp, file);
            } finally { try { unlinkSync(temp); } catch {} }
        } catch { /* Observability must never interrupt the agent. */ }
    }
    function stopTimer() { clearInterval(timer); timer = undefined; }
    function heartbeat(ctx: ExtensionContext) {
        stopTimer();
        timer = setInterval(() => {
            if (waiting || (busy && !ctx.isIdle())) publish(ctx, status);
            else { stopTimer(); publish(ctx, "unknown"); }
        }, 60_000);
        timer.unref();
    }
    pi.on("agent_start", (_, ctx) => {
        busy = true; outcome = undefined;
        if (!waiting) publish(ctx, "running");
        heartbeat(ctx);
    });
    pi.on("ui_prompt_start", (event, ctx) => {
        waiting = true;
        publish(ctx, event.kind === "confirm" ? "waitingApproval" : "waitingInput");
        heartbeat(ctx);
    });
    pi.on("ui_prompt_end", (_, ctx) => {
        waiting = false;
        publish(ctx, busy && !ctx.isIdle() ? "running" : "unknown");
        if (!busy) stopTimer();
    });
    pi.on("agent_before_settle", event => { outcome = event.outcome; });
    pi.on("agent_settled", (event, ctx) => {
        busy = false; stopTimer();
        publish(ctx, event.aborted || outcome === "aborted" ? "interrupted" :
            outcome === "error" ? "error" : outcome === "completed" ? "idle" : "unknown", !event.aborted && outcome === "completed");
    });
    pi.on("session_shutdown", (_, ctx) => {
        stopTimer();
        if (busy || waiting) publish(ctx, "interrupted");
        busy = false; waiting = false; outcome = undefined;
    });
}
