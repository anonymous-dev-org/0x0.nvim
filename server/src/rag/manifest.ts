import { existsSync, readFileSync, writeFileSync } from "node:fs";

export type ManifestEntry = {
  id: string;
  context_hash: string;
  language: string;
  suffix: string;
  completion: string;
  accepted_at: number;
};

export function manifestPath(indexPath: string): string {
  return `${indexPath}.manifest.json`;
}

export function loadManifest(indexPath: string): ManifestEntry[] {
  const path = manifestPath(indexPath);
  if (!existsSync(path)) {
    return [];
  }
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as ManifestEntry[];
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

export function saveManifest(indexPath: string, entries: ManifestEntry[]): void {
  writeFileSync(manifestPath(indexPath), JSON.stringify(entries, null, 0));
}
