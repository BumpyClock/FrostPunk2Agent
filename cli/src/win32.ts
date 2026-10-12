// Minimal user32 bindings: find the Frostpunk 2 window, focus it, send keys.
import { dlopen, FFIType, ptr } from "bun:ffi";

/** dlopen on first use: bun:ffi builds a trampoline per symbol, which every fp2 start paid before (measured). */
export function lazySymbols<T extends object>(load: () => T): T {
  let s: T | undefined;
  return new Proxy({} as T, { get: (_t, k) => (s ??= load())[k as keyof T] });
}

const user32 = lazySymbols(() => dlopen("user32.dll", {
  FindWindowExW: { args: [FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
  GetWindowTextW: { args: [FFIType.ptr, FFIType.ptr, FFIType.i32], returns: FFIType.i32 },
  GetForegroundWindow: { args: [], returns: FFIType.ptr },
  SetForegroundWindow: { args: [FFIType.ptr], returns: FFIType.bool },
  ShowWindow: { args: [FFIType.ptr, FFIType.i32], returns: FFIType.bool },
  IsIconic: { args: [FFIType.ptr], returns: FFIType.bool },
  keybd_event: { args: [FFIType.u8, FFIType.u8, FFIType.u32, FFIType.ptr], returns: FFIType.void },
}).symbols);

const KEYUP = 2;
const VK_MENU = 0x12;
const SW_RESTORE = 9;

const wide = (s: string) => {
  const buf = Buffer.alloc((s.length + 1) * 2);
  buf.write(s, "utf16le");
  return buf;
};

function windowTitle(hwnd: any): string {
  const buf = Buffer.alloc(512);
  const n = user32.GetWindowTextW(hwnd, ptr(buf), 256);
  return buf.toString("utf16le", 0, n * 2);
}

/** First top-level UnrealWindow whose title starts with "Frostpunk 2". */
export function findGameWindow(): any | null {
  const cls = wide("UnrealWindow");
  let hwnd: any = null;
  for (let i = 0; i < 64; i++) {
    hwnd = user32.FindWindowExW(null, hwnd, ptr(cls), null);
    if (!hwnd) return null;
    if (windowTitle(hwnd).startsWith("Frostpunk 2")) return hwnd;
  }
  return null;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export async function focusGame(maximize = false): Promise<any> {
  const hwnd = findGameWindow();
  if (!hwnd) throw new Error("Frostpunk 2 window not found (is the game running?)");
  if (maximize) user32.ShowWindow(hwnd, 3 /* SW_MAXIMIZE */);
  else if (user32.IsIconic(hwnd)) user32.ShowWindow(hwnd, SW_RESTORE);
  // An ALT tap allows a background process to take the foreground. (In-game, held ALT
  // shows the economy overlay, so never tap it while the game already has focus.)
  // SetForegroundWindow can be refused, so verify and retry (a key sent to an unfocused window is lost).
  for (let i = 0; i < 3 && user32.GetForegroundWindow() !== hwnd; i++) {
    user32.keybd_event(VK_MENU, 0, 0, null);
    user32.SetForegroundWindow(hwnd);
    user32.keybd_event(VK_MENU, 0, KEYUP, null);
    await sleep(250);
  }
  return hwnd;
}

/** True when the game window is the foreground window. */
export function gameFocused(): boolean {
  const hwnd = findGameWindow();
  return Boolean(hwnd) && user32.GetForegroundWindow() === hwnd;
}

const VK: Record<string, number> = {
  space: 0x20, escape: 0x1b, esc: 0x1b, enter: 0x0d, tab: 0x09, ctrl: 0x11, shift: 0x10, alt: 0x12,
  f1: 0x70, f2: 0x71, f3: 0x72, f4: 0x73, f5: 0x74, f6: 0x75, f7: 0x76, f8: 0x77, f9: 0x78, f10: 0x79,
};

function vk(key: string): number {
  const k = key.toLowerCase();
  if (k in VK) return VK[k];
  if (k.length === 1) return k.toUpperCase().charCodeAt(0);
  throw new Error(`unknown key '${key}'`);
}

/** Send chords like "space", "1", "ctrl+r", "space@3000" (hold 3 s) to the game; restores previous foreground window unless keepFocus. */
export async function sendKeys(chords: string[], keepFocus = false): Promise<void> {
  const prev = user32.GetForegroundWindow();
  await focusGame();
  for (const chord of chords) {
    const [keysPart, holdMs] = chord.split("@");
    const codes = keysPart.split("+").map(vk);
    for (const c of codes) user32.keybd_event(c, 0, 0, null);
    await sleep(holdMs ? Number(holdMs) : 70);
    for (const c of [...codes].reverse()) user32.keybd_event(c, 0, KEYUP, null);
    await sleep(120);
  }
  if (!keepFocus && prev) user32.SetForegroundWindow(prev);
}

const kernel32 = lazySymbols(() =>
  dlopen("kernel32.dll", {
    GetCurrentProcess: { args: [], returns: FFIType.ptr },
    SetProcessInformation: { args: [FFIType.ptr, FFIType.i32, FFIType.ptr, FFIType.u32], returns: FFIType.bool },
  }).symbols,
);

/**
 * Opt this process out of Windows power throttling (EcoQoS and ignored timer requests), which Windows applies to
 * windowless background processes such as the daemon. Returns false when the call fails.
 */
export function disablePowerThrottling(): boolean {
  // PROCESS_POWER_THROTTLING_STATE { Version = 1, ControlMask = EXECUTION_SPEED | IGNORE_TIMER_RESOLUTION, StateMask = 0 }
  const state = new Uint32Array([1, 0x1 | 0x4, 0]);
  return kernel32.SetProcessInformation(kernel32.GetCurrentProcess(), 4 /* ProcessPowerThrottling */, ptr(state), 12);
}
