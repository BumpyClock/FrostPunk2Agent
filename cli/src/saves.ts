// Save files on disk: listing, rotating agent save slots, and the bad-save list that `recover` maintains.
import { closeSync, existsSync, mkdirSync, openSync, readdirSync, readFileSync, readSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { repoRoot } from "./bridge";

export const SAVE_DIR = join(process.env.LOCALAPPDATA ?? "", "11bitstudios", "Frostpunk2", "Steam", "Saved", "SaveGames");

// .sav header: int32 magic, then an FString (int32 length incl. NUL, bytes) holding the display name.
export function saveDisplayName(path: string): string | undefined {
  try {
    const fd = openSync(path, "r");
    const buf = Buffer.alloc(512);
    readSync(fd, buf, 0, 512, 0);
    closeSync(fd);
    const len = buf.readInt32LE(4);
    if (len <= 1 || len > 500) return undefined;
    return buf.toString("utf8", 8, 8 + len - 1);
  } catch {
    return undefined;
  }
}

export type SaveEntry = { file: string; display?: string; modified: string; bytes: number };

/** Save files, newest first. `display` is the name the game's `load` takes. */
export function listSaves(): SaveEntry[] {
  if (!existsSync(SAVE_DIR)) return [];
  return readdirSync(SAVE_DIR)
    .filter((f) => f.endsWith(".sav"))
    .map((f) => {
      const st = statSync(join(SAVE_DIR, f));
      return { file: f.slice(0, -4), display: saveDisplayName(join(SAVE_DIR, f)), modified: st.mtime.toISOString(), bytes: st.size };
    })
    .sort((a, b) => b.modified.localeCompare(a.modified));
}

export const saveName = (s: SaveEntry) => s.display ?? s.file;

/**
 * Rotating save slots `<prefix>-a`, `-b`, `-c`: returns the first missing slot, else the oldest. A single
 * rolling slot once became unloadable (the game crashed in Wwise while loading it, twice) and left no
 * fallback; three slots keep two older saves.
 */
export const ROLLING_SLOTS = ["a", "b", "c"];
export function nextRollingSlot(prefix: string): string {
  const modified = new Map<string, string>();
  try {
    for (const s of listSaves()) if (!modified.has(saveName(s))) modified.set(saveName(s), s.modified);
  } catch {}
  let oldest: string | undefined;
  for (const slot of ROLLING_SLOTS) {
    const name = `${prefix}-${slot}`;
    const m = modified.get(name);
    if (m === undefined) return name;
    if (oldest === undefined || m < modified.get(oldest)!) oldest = name;
  }
  return oldest!;
}

// Saves that crashed the game while loading. Keyed by display name; an entry only applies while the file
// still has the recorded modification time, so a rolling slot that is later overwritten is usable again.
type BadSave = { modified: string; reason: string; at: string };
const badSavesPath = () => join(repoRoot(), ".runtime", "bad-saves.json");

export function loadBadSaves(): Record<string, BadSave> {
  try {
    return JSON.parse(readFileSync(badSavesPath(), "utf8"));
  } catch {
    return {};
  }
}

export function markBadSave(name: string, reason: string) {
  const entry = listSaves().find((s) => saveName(s) === name);
  const bad = loadBadSaves();
  bad[name] = { modified: entry?.modified ?? "", reason, at: new Date().toISOString() };
  mkdirSync(join(repoRoot(), ".runtime"), { recursive: true });
  writeFileSync(badSavesPath(), JSON.stringify(bad, null, 2));
}

export function isBadSave(s: SaveEntry, bad = loadBadSaves()): boolean {
  const b = bad[saveName(s)];
  return Boolean(b && b.modified === s.modified);
}

/**
 * Recovery order: rolling slots (`agent-rolling*`), then other `agent-*` saves, then `AutoSave*`; newest first
 * within each group. Skips saves marked bad and names in `skip`.
 */
export function recoveryCandidates(skip: Set<string> = new Set()): string[] {
  const bad = loadBadSaves();
  const saves = listSaves().filter((s) => !isBadSave(s, bad) && !skip.has(saveName(s)));
  const groups = [/^agent-rolling/i, /^agent-/i, /^AutoSave/i];
  const out: string[] = [];
  for (const g of groups) {
    for (const s of saves) {
      const n = saveName(s);
      if (g.test(n) && !out.includes(n)) out.push(n);
    }
  }
  return out;
}
