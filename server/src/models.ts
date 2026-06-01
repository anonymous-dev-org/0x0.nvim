import { gateway } from "ai";

const THINKING_MARKERS = ["thinking", "reasoning"];
const THINKING_DENYLIST = new Set(["o3"]);

type GatewayModel = {
  id: string;
  name?: string | null;
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

function isCompletionModel(model: GatewayModel): boolean {
  if (model.modelType && model.modelType !== "language") {
    return false;
  }
  return !isThinkingModel(model.id, model.name);
}

export async function listCompletionModels(): Promise<string[]> {
  const metadata = await gateway.getAvailableModels();
  return metadata.models
    .filter(isCompletionModel)
    .map((model) => model.id)
    .sort((a, b) => a.localeCompare(b));
}
