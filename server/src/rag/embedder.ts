export type Embedder = {
  ready: boolean;
  embed(text: string): Promise<number[] | null>;
  warmup(): Promise<void>;
};

let pipelinePromise: Promise<Embedder | null> | null = null;

export function resetEmbedderForTests(): void {
  pipelinePromise = null;
}

export function getEmbedder(model: string, cacheDir?: string): Promise<Embedder | null> {
  if (!pipelinePromise) {
    pipelinePromise = createEmbedder(model, cacheDir);
  }
  return pipelinePromise;
}

async function createEmbedder(model: string, cacheDir?: string): Promise<Embedder | null> {
  try {
    const { pipeline, env } = await import("@xenova/transformers");
    if (cacheDir) {
      env.cacheDir = cacheDir;
    }

    const extractor = await pipeline("feature-extraction", model, {
      quantized: true,
    });

    let ready = false;

    const embedder: Embedder = {
      get ready() {
        return ready;
      },
      async warmup() {
        await embedder.embed("warmup");
        ready = true;
      },
      async embed(text: string): Promise<number[] | null> {
        if (!text.trim()) {
          return null;
        }
        try {
          const output = await extractor(text, {
            pooling: "mean",
            normalize: true,
          });
          const data = output.data as Float32Array | number[];
          return Array.from(data);
        } catch {
          return null;
        }
      },
    };

    return embedder;
  } catch (error) {
    process.stderr.write(
      `[0x0-completion] embedder unavailable: ${error instanceof Error ? error.message : String(error)}\n`,
    );
    return null;
  }
}
