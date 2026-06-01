import { createInterface } from "node:readline";
import { runComplete } from "./complete.ts";
import { listCompletionModels } from "./models.ts";
import type { CompleteParams } from "./prompt.ts";
import { initRagService, lookup, record, shutdownRag } from "./rag/service.ts";
import type { RagLookupParams, RagRecordParams } from "./rag/types.ts";

type IncomingMessage = {
  id?: number;
  method?: string;
  params?: Record<string, unknown>;
};

type OutgoingMessage =
  | { id: number; event: "chunk"; text: string }
  | { id: number; event: "done" }
  | { id: number; event: "error"; message: string; code?: string }
  | { id: number; event: "pong" }
  | { id: number; event: "models"; models: string[] }
  | {
      id: number;
      event: "rag";
      direct?: { completion: string };
      examples?: Array<{ prefix: string; suffix: string; completion: string }>;
    };

const inflight = new Map<number, AbortController>();

function writeMessage(message: OutgoingMessage): void {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function logDebug(message: string): void {
  process.stderr.write(`[0x0-completion] ${message}\n`);
}

function asCompleteParams(params: Record<string, unknown> | undefined): CompleteParams {
  const scope = params?.scope;
  const examples = params?.examples;
  return {
    model: String(params?.model ?? ""),
    prefix: typeof params?.prefix === "string" ? params.prefix : "",
    suffix: typeof params?.suffix === "string" ? params.suffix : "",
    language: typeof params?.language === "string" ? params.language : undefined,
    filepath: typeof params?.filepath === "string" ? params.filepath : undefined,
    cwd: typeof params?.cwd === "string" ? params.cwd : undefined,
    header: typeof params?.header === "string" ? params.header : undefined,
    imports: typeof params?.imports === "string" ? params.imports : undefined,
    indent: typeof params?.indent === "string" ? params.indent : undefined,
    max_tokens: typeof params?.max_tokens === "number" ? params.max_tokens : undefined,
    temperature: typeof params?.temperature === "number" ? params.temperature : undefined,
    examples: Array.isArray(examples)
      ? examples
          .filter((entry): entry is Record<string, unknown> => typeof entry === "object" && entry !== null)
          .map((entry) => ({
            prefix: typeof entry.prefix === "string" ? entry.prefix : undefined,
            suffix: typeof entry.suffix === "string" ? entry.suffix : undefined,
            completion:
              typeof entry.completion === "string" ? entry.completion : undefined,
          }))
      : undefined,
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

function asRagLookupParams(params: Record<string, unknown> | undefined): RagLookupParams {
  const scope = params?.scope;
  return {
    prefix: typeof params?.prefix === "string" ? params.prefix : "",
    suffix: typeof params?.suffix === "string" ? params.suffix : "",
    language: typeof params?.language === "string" ? params.language : "",
    filepath: typeof params?.filepath === "string" ? params.filepath : undefined,
    direct_hit_threshold:
      typeof params?.direct_hit_threshold === "number" ? params.direct_hit_threshold : undefined,
    example_threshold:
      typeof params?.example_threshold === "number" ? params.example_threshold : undefined,
    max_examples: typeof params?.max_examples === "number" ? params.max_examples : undefined,
    scope:
      scope && typeof scope === "object"
        ? {
            type: typeof (scope as Record<string, unknown>).type === "string"
              ? ((scope as Record<string, unknown>).type as string)
              : undefined,
            text: typeof (scope as Record<string, unknown>).text === "string"
              ? ((scope as Record<string, unknown>).text as string)
              : undefined,
          }
        : undefined,
  };
}

function asRagRecordParams(params: Record<string, unknown> | undefined): RagRecordParams {
  const scope = params?.scope;
  return {
    prefix: typeof params?.prefix === "string" ? params.prefix : "",
    suffix: typeof params?.suffix === "string" ? params.suffix : "",
    language: typeof params?.language === "string" ? params.language : "",
    filepath: typeof params?.filepath === "string" ? params.filepath : undefined,
    completion: typeof params?.completion === "string" ? params.completion : "",
    max_entries: typeof params?.max_entries === "number" ? params.max_entries : undefined,
    max_field_chars: typeof params?.max_field_chars === "number" ? params.max_field_chars : undefined,
    scope:
      scope && typeof scope === "object"
        ? {
            type: typeof (scope as Record<string, unknown>).type === "string"
              ? ((scope as Record<string, unknown>).type as string)
              : undefined,
            text: typeof (scope as Record<string, unknown>).text === "string"
              ? ((scope as Record<string, unknown>).text as string)
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

async function handleRagLookup(id: number, params: Record<string, unknown> | undefined): Promise<void> {
  try {
    const result = await lookup(asRagLookupParams(params));
    writeMessage({
      id,
      event: "rag",
      direct: result.direct,
      examples: result.examples,
    });
    writeMessage({ id, event: "done" });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    writeMessage({ id, event: "error", message, code: "rag_lookup_failed" });
  }
}

function handleRagRecord(id: number, params: Record<string, unknown> | undefined): void {
  writeMessage({ id, event: "done" });
  void record(asRagRecordParams(params)).catch((error) => {
    logDebug(
      `rag_record failed: ${error instanceof Error ? error.message : String(error)}`,
    );
  });
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

async function handleListModels(id: number): Promise<void> {
  try {
    const models = await listCompletionModels();
    writeMessage({ id, event: "models", models });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    writeMessage({ id, event: "error", message, code: "list_models_failed" });
  }
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
  if (method === "list_models") {
    await handleListModels(id);
    return;
  }
  if (method === "complete") {
    await handleComplete(id, message.params);
    return;
  }
  if (method === "rag_lookup") {
    await handleRagLookup(id, message.params);
    return;
  }
  if (method === "rag_record") {
    handleRagRecord(id, message.params);
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

void initRagService();

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
  void shutdownRag().finally(() => {
    process.exit(0);
  });
});
