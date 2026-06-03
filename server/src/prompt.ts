export type ScopeBlock = {
  type?: string;
  text?: string;
  start_line?: number;
  end_line?: number;
};

export type CompletionExample = {
  prefix?: string;
  suffix?: string;
  completion?: string;
  kind?: "relevant" | "recent" | string;
  accepted_count?: number;
  last_accepted_at?: number;
  score?: number;
};

export type CompleteParams = {
  model: string;
  prefix?: string;
  suffix?: string;
  language?: string;
  filepath?: string;
  cwd?: string;
  header?: string;
  imports?: string;
  indent?: string;
  scope?: ScopeBlock;
  examples?: CompletionExample[];
  max_tokens?: number;
  temperature?: number;
};

function scopeBlock(scope: ScopeBlock | undefined): string | null {
  if (!scope || typeof scope.text !== "string" || scope.text === "") {
    return null;
  }
  return [
    `Enclosing scope (${scope.type ?? "block"}, lines ${scope.start_line ?? ""}-${scope.end_line ?? ""}):`,
    scope.text,
  ].join("\n");
}

function examplesBlock(examples: CompletionExample[] | undefined): string | null {
  if (!Array.isArray(examples) || examples.length === 0) {
    return null;
  }

  const lines = [
    "Accepted completion memories (copy the style only when it fits the cursor context):",
  ];
  for (let i = 0; i < examples.length; i += 1) {
    const example = examples[i];
    if (!example || typeof example !== "object") {
      continue;
    }
    const prefix = typeof example.prefix === "string" ? example.prefix : "";
    const suffix = typeof example.suffix === "string" ? example.suffix : "";
    const completion =
      typeof example.completion === "string" ? example.completion : "";
    if (prefix === "" && suffix === "" && completion === "") {
      continue;
    }
    const kind = typeof example.kind === "string" ? example.kind : "accepted";
    const acceptedCount =
      typeof example.accepted_count === "number" && example.accepted_count > 1
        ? `, accepted ${example.accepted_count}x`
        : "";
    lines.push("", `Memory ${i + 1} (${kind}${acceptedCount}):`);
    if (prefix !== "") {
      lines.push(`Before cursor: ${prefix}`);
    }
    lines.push(`Inserted: ${completion}`);
    if (suffix !== "") {
      lines.push(`After cursor: ${suffix}`);
    }
  }

  return lines.length > 1 ? lines.join("\n") : null;
}

function cursorContext(request: CompleteParams): string {
  const prefix = request.prefix ?? "";
  const suffix = request.suffix ?? "";
  const lang = request.language ?? "code";
  const filepath = request.filepath ?? "unknown";

  return [
    `Cursor context (${lang}, ${filepath}):`,
    "```",
    `${prefix}<|cursor|>${suffix}`,
    "```",
  ].join("\n");
}

export function buildPrompt(request: CompleteParams): string {
  const lang = request.language ?? "code";
  const lines = [
    `Complete ${lang} code at <|cursor|>.`,
    `File: ${request.filepath ?? "unknown"}`,
    `Project root: ${request.cwd ?? "."}`,
    "",
    "Rules:",
    "- Output only raw text to insert at <|cursor|>",
    "- Keep it short: finish the immediate local completion",
    "- No reasoning, analysis, plans, status text, assistant preambles, or explanations",
    "- No tools, search, markdown fences, XML tags, or repeated prefix",
    "- If no useful completion is obvious, output nothing",
    "",
  ];

  if (typeof request.imports === "string" && request.imports !== "") {
    lines.push("Imports in this file:", request.imports, "");
  } else if (typeof request.header === "string" && request.header !== "") {
    lines.push("File header:", request.header, "");
  }

  const scope = scopeBlock(request.scope);
  if (scope) {
    lines.push(scope, "");
  }

  const examples = examplesBlock(request.examples);
  if (examples) {
    lines.push(examples, "");
  }

  lines.push(cursorContext(request), "");

  if (typeof request.indent === "string" && request.indent !== "") {
    lines.push(`Current line indentation: ${JSON.stringify(request.indent)}`, "");
  }

  lines.push("Text to insert:");
  return lines.join("\n");
}

export function systemPrompt(): string {
  return [
    "You are an inline code completion engine, not a chat assistant.",
    "Think internally only if needed, but never output reasoning, analysis, plans, status text, tags, markdown, or explanations.",
    "Output only the raw text to insert at the cursor marker.",
  ].join(" ");
}
