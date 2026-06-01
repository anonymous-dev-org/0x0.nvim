export type ScopeBlock = {
  type?: string;
  text?: string;
  start_line?: number;
  end_line?: number;
};

export type CompleteParams = {
  model: string;
  prefix?: string;
  suffix?: string;
  language?: string;
  filepath?: string;
  scope?: ScopeBlock;
  max_tokens?: number;
  temperature?: number;
};

function scopeBlock(scope: ScopeBlock | undefined): string | null {
  if (!scope || typeof scope.text !== "string" || scope.text === "") {
    return null;
  }
  return [
    `Relevant surrounding code (${scope.type ?? ""}, lines ${scope.start_line ?? ""}-${scope.end_line ?? ""}):`,
    scope.text,
  ].join("\n");
}

export function buildPrompt(request: CompleteParams): string {
  const lines = [
    `Return only the ${request.language ?? "code"} text to insert after this cursor.`,
    "No tools. No search. No explanation. No markdown.",
    "",
  ];

  const scope = scopeBlock(request.scope);
  if (scope) {
    lines.push(scope, "");
  }

  lines.push(
    `Code before cursor: ${request.prefix ?? ""}`,
    "",
    `Code after cursor: ${request.suffix ?? ""}`,
    "",
    "Text to insert:",
  );

  return lines.join("\n");
}

export function systemPrompt(): string {
  return [
    "You are an inline code completion engine.",
    "Output only the text to insert at the cursor.",
    "No markdown fences, no explanations, no repeated prefix.",
  ].join(" ");
}
