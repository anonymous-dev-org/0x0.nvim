import * as esbuild from "esbuild";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const outfile = join(root, "dist", "completion-server.js");

mkdirSync(dirname(outfile), { recursive: true });

await esbuild.build({
  entryPoints: [join(root, "src", "index.ts")],
  bundle: true,
  platform: "node",
  target: "node18",
  format: "esm",
  banner: {
    js: "import { createRequire } from 'module'; const require = createRequire(import.meta.url);",
  },
  outfile,
  sourcemap: false,
  minify: false,
  external: [
    "@orama/orama",
    "@orama/plugin-data-persistence",
    "@xenova/transformers",
  ],
});

console.log(`built ${outfile}`);
