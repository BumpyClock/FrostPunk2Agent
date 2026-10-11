// Mouse input in game client coordinates (physical pixels, as in `fp2 screenshot` at scale 1).
import { dlopen, FFIType, ptr } from "bun:ffi";
import { focusGame } from "./win32";

const user32 = dlopen("user32.dll", {
  SetProcessDPIAware: { args: [], returns: FFIType.bool },
  ClientToScreen: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.bool },
  GetClientRect: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.bool },
  SetCursorPos: { args: [FFIType.i32, FFIType.i32], returns: FFIType.bool },
  mouse_event: { args: [FFIType.u32, FFIType.u32, FFIType.u32, FFIType.i32, FFIType.ptr], returns: FFIType.void },
}).symbols;

const LEFTDOWN = 0x02, LEFTUP = 0x04, RIGHTDOWN = 0x08, RIGHTUP = 0x10, WHEEL = 0x0800;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Resolve "x,y" (pixels, or fractions when both <= 1) to screen coordinates. */
async function toScreen(point: number[]): Promise<[number, number]> {
  user32.SetProcessDPIAware();
  const hwnd = await focusGame();
  const rect = Buffer.alloc(16);
  user32.GetClientRect(hwnd, ptr(rect));
  let [x, y] = point;
  if (x <= 1 && y <= 1) { x *= rect.readInt32LE(8); y *= rect.readInt32LE(12); }
  const pt = Buffer.alloc(8);
  pt.writeInt32LE(Math.round(x), 0); pt.writeInt32LE(Math.round(y), 4);
  user32.ClientToScreen(hwnd, ptr(pt));
  return [pt.readInt32LE(0), pt.readInt32LE(4)];
}

const MOVE = 0x0001;

async function moveTo(sx: number, sy: number) {
  user32.SetCursorPos(sx, sy);
  // SetCursorPos alone generates no WM_MOUSEMOVE for the game; nudge so UMG registers hover
  // (otherwise the first click on a widget only focuses it).
  user32.mouse_event(MOVE, 1, 0, 0, null);
  await sleep(30);
  user32.mouse_event(MOVE, -1 >>> 0, 0, 0, null);
  await sleep(90);
}

export async function click(point: number[], opts: { right?: boolean; holdMs?: number; double?: boolean } = {}) {
  const [sx, sy] = await toScreen(point);
  await moveTo(sx, sy);
  const [down, up] = opts.right ? [RIGHTDOWN, RIGHTUP] : [LEFTDOWN, LEFTUP];
  for (let i = 0; i < (opts.double ? 2 : 1); i++) {
    user32.mouse_event(down, 0, 0, 0, null);
    await sleep(opts.holdMs ?? 60);
    user32.mouse_event(up, 0, 0, 0, null);
    await sleep(80);
  }
  return { screen: [sx, sy] };
}

export async function move(point: number[]) {
  const [sx, sy] = await toScreen(point);
  await moveTo(sx, sy);
  return { screen: [sx, sy] };
}

export async function drag(from: number[], to: number[], steps = 20) {
  const [ax, ay] = await toScreen(from);
  const [bx, by] = await toScreen(to);
  await moveTo(ax, ay);
  user32.mouse_event(LEFTDOWN, 0, 0, 0, null);
  for (let i = 1; i <= steps; i++) {
    user32.SetCursorPos(Math.round(ax + ((bx - ax) * i) / steps), Math.round(ay + ((by - ay) * i) / steps));
    await sleep(15);
  }
  await sleep(60);
  user32.mouse_event(LEFTUP, 0, 0, 0, null);
  return { from: [ax, ay], to: [bx, by] };
}

/** Positive ticks scroll up (zoom in on most maps). */
export async function scroll(point: number[], ticks: number) {
  const [sx, sy] = await toScreen(point);
  await moveTo(sx, sy);
  const dir = Math.sign(ticks);
  for (let i = 0; i < Math.abs(ticks); i++) {
    user32.mouse_event(WHEEL, 0, 0, 120 * dir, null);
    await sleep(40);
  }
  return { screen: [sx, sy], ticks };
}
