import { createInterface } from "node:readline";
import { runComplete } from "./complete.ts";
import type { CompleteParams } from "./prompt.ts";

type IncomingMessage = {
  id?: number;
  method?: string;
  params?: Record<string, unknown>;
};

type OutgoingMessage =
  | { id: number; event: "chunk"; text: string }
  | { id: number; event: "done" }
  | { id: number; event: "error"; message: string; code?: string }
  | { id: number; event: "pong" };

const inflight = new Map<number, AbortController>();

function writeMessage(message: OutgoingMessage): void {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function logDebug(message: string): void {
  process.stderr.write(`[0x0-completion] ${message}\n`);
}

function asCompleteParams(params: Record<string, unknown> | undefined): CompleteParams {
  const scope = params?.scope;
  return {
    model: String(params?.model ?? ""),
    prefix: typeof params?.prefix === "string" ? params.prefix : "",
    suffix: typeof params?.suffix === "string" ? params.suffix : "",
    language: typeof params?.language === "string" ? params.language : undefined,
    filepath: typeof params?.filepath === "string" ? params.filepath : undefined,
    max_tokens: typeof params?.max_tokens === "number" ? params.max_tokens : undefined,
    temperature: typeof params?.temperature === "number" ? params.temperature : undefined,
    scope:
      scope && typeof scope === "object"
        ? {
            type: typeof (scope as Record<string, unknown>).type === "string"
              ? ((scope as Record<string, unknown>).type as string)
              : undefined,
            text: typeof (scope as Record<string, unknown>).text === "string"
              ? ((scope as Record<string, unknown>).text as string)
              : undefined,
            start_line:
              typeof (scope as Record<string, unknown>).start_line === "number"
                ? ((scope as Record<string, unknown>).start_line as number)
                : undefined,
            end_line:
              typeof (scope as Record<string, unknown>).end_line === "number"
                ? ((scope as Record<string, unknown>).end_line as number)
                : undefined,
          }
        : undefined,
  };
}

async function handleComplete(id: number, params: Record<string, unknown> | undefined): Promise<void> {
  const completeParams = asCompleteParams(params);
  if (!completeParams.model) {
    writeMessage({ id, event: "error", message: "model is required", code: "invalid_request" });
    return;
  }

  const controller = new AbortController();
  inflight.set(id, controller);

  try {
    await runComplete(
      completeParams,
      (text) => {
        if (text !== "") {
          writeMessage({ id, event: "chunk", text });
        }
      },
      controller.signal,
    );
    if (!controller.signal.aborted) {
      writeMessage({ id, event: "done" });
    }
  } catch (error) {
    if (controller.signal.aborted) {
      return;
    }
    const message = error instanceof Error ? error.message : String(error);
    writeMessage({ id, event: "error", message, code: "completion_failed" });
  } finally {
    inflight.delete(id);
  }
}

function handleCancel(id: number, params: Record<string, unknown> | undefined): void {
  const target = params?.target;
  if (typeof target !== "number") {
    writeMessage({ id, event: "error", message: "cancel target is required", code: "invalid_request" });
    return;
  }
  const controller = inflight.get(target);
  if (controller) {
    controller.abort();
    inflight.delete(target);
  }
  writeMessage({ id, event: "done" });
}

async function handleMessage(message: IncomingMessage): Promise<void> {
  const id = message.id;
  if (typeof id !== "number") {
    logDebug("ignored message without id");
    return;
  }

  const method = message.method ?? "";
  if (method === "ping") {
    writeMessage({ id, event: "pong" });
    return;
  }
  if (method === "complete") {
    await handleComplete(id, message.params);
    return;
  }
  if (method === "cancel") {
    handleCancel(id, message.params);
    return;
  }

  writeMessage({ id, event: "error", message: `unknown method: ${method}`, code: "unknown_method" });
}

if (!process.env.AI_GATEWAY_API_KEY) {
  logDebug("warning: AI_GATEWAY_API_KEY is not set");
}

const rl = createInterface({ input: process.stdin });

rl.on("line", (line) => {
  const trimmed = line.trim();
  if (trimmed === "") {
    return;
  }

  let message: IncomingMessage;
  try {
    message = JSON.parse(trimmed) as IncomingMessage;
  } catch (error) {
    logDebug(`failed to decode JSON: ${error instanceof Error ? error.message : String(error)}`);
    return;
  }

  void handleMessage(message).catch((error) => {
    const requestId = message.id;
    if (typeof requestId !== "number") {
      return;
    }
    writeMessage({
      id: requestId,
      event: "error",
      message: error instanceof Error ? error.message : String(error),
      code: "internal_error",
    });
  });
});

rl.on("close", () => {
  for (const controller of inflight.values()) {
    controller.abort();
  }
  inflight.clear();
  process.exit(0);
});
