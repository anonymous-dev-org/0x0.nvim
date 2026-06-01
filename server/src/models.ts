const GATEWAY_MODELS_URL = "https://ai-gateway.vercel.sh/v1/models";

const THINKING_MARKERS = ["thinking", "reasoning"];
const THINKING_DENYLIST = new Set(["o3"]);

type GatewayModel = {
  id: string;
  name?: string | null;
  type?: string | null;
  modelType?: string | null;
};

function isThinkingModel(id: string, name?: string | null): boolean {
  const lowerId = id.toLowerCase();
  if (THINKING_DENYLIST.has(lowerId) || THINKING_DENYLIST.has(lowerId.split("/").pop() ?? "")) {
    return true;
  }
  for (const marker of THINKING_MARKERS) {
    if (lowerId.includes(marker)) {
      return true;
    }
    if (name && name.toLowerCase().includes(marker)) {
      return true;
    }
  }
  return false;
}

function modelKind(model: GatewayModel): string | null {
  return model.type ?? model.modelType ?? null;
}

function isCompletionModel(model: GatewayModel): boolean {
  const kind = modelKind(model);
  if (kind && kind !== "language") {
    return false;
  }
  return !isThinkingModel(model.id, model.name);
}

export async function listCompletionModels(): Promise<string[]> {
  const apiKey = process.env.AI_GATEWAY_API_KEY;
  if (!apiKey) {
    throw new Error("AI_GATEWAY_API_KEY is not set");
  }

  const response = await fetch(GATEWAY_MODELS_URL, {
    headers: {
      Authorization: `Bearer ${apiKey}`,
    },
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`list models failed (${response.status}): ${body}`);
  }

  const payload = (await response.json()) as { data?: GatewayModel[] };
  const models = payload.data ?? [];

  return models
    .filter(isCompletionModel)
    .map((model) => model.id)
    .sort((a, b) => a.localeCompare(b));
}
