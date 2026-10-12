// Capture the Frostpunk 2 client area to PNG (screen BitBlt; the window must be foreground
// because the game stops rendering when unfocused).
import { dlopen, FFIType, ptr } from "bun:ffi";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { deflateSync } from "node:zlib";
import { focusGame, lazySymbols } from "./win32";

const user32 = lazySymbols(() => dlopen("user32.dll", {
  SetProcessDPIAware: { args: [], returns: FFIType.bool },
  GetClientRect: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.bool },
  ClientToScreen: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.bool },
  GetDC: { args: [FFIType.ptr], returns: FFIType.ptr },
  ReleaseDC: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.i32 },
}).symbols);

const gdi32 = lazySymbols(() => dlopen("gdi32.dll", {
  CreateCompatibleDC: { args: [FFIType.ptr], returns: FFIType.ptr },
  CreateCompatibleBitmap: { args: [FFIType.ptr, FFIType.i32, FFIType.i32], returns: FFIType.ptr },
  SelectObject: { args: [FFIType.ptr, FFIType.ptr], returns: FFIType.ptr },
  BitBlt: { args: [FFIType.ptr, FFIType.i32, FFIType.i32, FFIType.i32, FFIType.i32, FFIType.ptr, FFIType.i32, FFIType.i32, FFIType.u32], returns: FFIType.bool },
  GetDIBits: { args: [FFIType.ptr, FFIType.ptr, FFIType.u32, FFIType.u32, FFIType.ptr, FFIType.ptr, FFIType.u32], returns: FFIType.i32 },
  DeleteObject: { args: [FFIType.ptr], returns: FFIType.bool },
  DeleteDC: { args: [FFIType.ptr], returns: FFIType.bool },
}).symbols);

const SRCCOPY = 0x00cc0020;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

type Raw = { width: number; height: number; bgra: Buffer };

async function grab(): Promise<Raw & { screenX: number; screenY: number }> {
  user32.SetProcessDPIAware();
  const hwnd = await focusGame();
  await sleep(150); // let the game present a frame after regaining focus
  const rect = Buffer.alloc(16);
  user32.GetClientRect(hwnd, ptr(rect));
  const width = rect.readInt32LE(8);
  const height = rect.readInt32LE(12);
  const origin = Buffer.alloc(8);
  user32.ClientToScreen(hwnd, ptr(origin));
  const sx = origin.readInt32LE(0);
  const sy = origin.readInt32LE(4);

  const screen = user32.GetDC(null);
  const mem = gdi32.CreateCompatibleDC(screen);
  const bmp = gdi32.CreateCompatibleBitmap(screen, width, height);
  const old = gdi32.SelectObject(mem, bmp);
  gdi32.BitBlt(mem, 0, 0, width, height, screen, sx, sy, SRCCOPY);
  gdi32.SelectObject(mem, old);

  const info = Buffer.alloc(40); // BITMAPINFOHEADER, top-down 32bpp
  info.writeUInt32LE(40, 0);
  info.writeInt32LE(width, 4);
  info.writeInt32LE(-height, 8);
  info.writeUInt16LE(1, 12);
  info.writeUInt16LE(32, 14);
  const bgra = Buffer.alloc(width * height * 4);
  gdi32.GetDIBits(mem, bmp, 0, height, ptr(bgra), ptr(info), 0);
  gdi32.DeleteObject(bmp);
  gdi32.DeleteDC(mem);
  user32.ReleaseDC(null, screen);
  return { width, height, bgra, screenX: sx, screenY: sy };
}

function crop(src: Raw, x0: number, y0: number, x1: number, y1: number): Raw {
  x0 = Math.max(0, Math.min(src.width, x0)); x1 = Math.max(x0, Math.min(src.width, x1));
  y0 = Math.max(0, Math.min(src.height, y0)); y1 = Math.max(y0, Math.min(src.height, y1));
  const width = x1 - x0, height = y1 - y0;
  const bgra = Buffer.alloc(width * height * 4);
  for (let y = 0; y < height; y++) src.bgra.copy(bgra, y * width * 4, ((y0 + y) * src.width + x0) * 4, ((y0 + y) * src.width + x1) * 4);
  return { width, height, bgra };
}

// Box-filter downscale.
function scale(src: Raw, factor: number): Raw {
  if (factor >= 1) return src;
  const width = Math.max(1, Math.round(src.width * factor));
  const height = Math.max(1, Math.round(src.height * factor));
  const bgra = Buffer.alloc(width * height * 4);
  const fx = src.width / width, fy = src.height / height;
  for (let y = 0; y < height; y++) {
    const sy0 = Math.floor(y * fy), sy1 = Math.max(sy0 + 1, Math.floor((y + 1) * fy));
    for (let x = 0; x < width; x++) {
      const sx0 = Math.floor(x * fx), sx1 = Math.max(sx0 + 1, Math.floor((x + 1) * fx));
      let b = 0, g = 0, r = 0, n = 0;
      for (let yy = sy0; yy < sy1; yy++) for (let xx = sx0; xx < sx1; xx++) {
        const i = (yy * src.width + xx) * 4;
        b += src.bgra[i]; g += src.bgra[i + 1]; r += src.bgra[i + 2]; n++;
      }
      const o = (y * width + x) * 4;
      bgra[o] = b / n; bgra[o + 1] = g / n; bgra[o + 2] = r / n; bgra[o + 3] = 255;
    }
  }
  return { width, height, bgra };
}

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf: Buffer): number {
  let c = 0xffffffff;
  for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Buffer): Buffer {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}

function png(img: Raw): Buffer {
  const rows = Buffer.alloc((img.width * 3 + 1) * img.height);
  for (let y = 0; y < img.height; y++) {
    const o = y * (img.width * 3 + 1);
    rows[o] = 0;
    for (let x = 0; x < img.width; x++) {
      const i = (y * img.width + x) * 4, j = o + 1 + x * 3;
      rows[j] = img.bgra[i + 2]; rows[j + 1] = img.bgra[i + 1]; rows[j + 2] = img.bgra[i];
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(img.width, 0); ihdr.writeUInt32BE(img.height, 4);
  ihdr[8] = 8; ihdr[9] = 2; // 8-bit RGB
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr), chunk("IDAT", deflateSync(rows, { level: 6 })), chunk("IEND", Buffer.alloc(0)),
  ]);
}

function isBlank(img: Raw): boolean {
  // The game shows a flat dark frame while it is not presenting; sample a grid.
  let min = 255, max = 0;
  for (let y = 0; y < img.height; y += Math.max(1, img.height >> 4))
    for (let x = 0; x < img.width; x += Math.max(1, img.width >> 4)) {
      const v = img.bgra[(y * img.width + x) * 4 + 1];
      min = Math.min(min, v); max = Math.max(max, v);
    }
  return max - min < 4;
}

export type ShotOptions = { out: string; region?: number[]; scale?: number; retries?: number };

/** region = [x0,y0,x1,y1] in client pixels, or fractions (all <= 1) of the client size. */
export async function screenshot(opts: ShotOptions) {
  let raw = await grab();
  for (let i = 0; i < (opts.retries ?? 12) && isBlank(raw); i++) {
    await sleep(500);
    raw = await grab();
  }
  const full = { width: raw.width, height: raw.height };
  let img: Raw = raw;
  let region = opts.region;
  if (region) {
    if (region.every((v) => v <= 1)) region = [region[0] * raw.width, region[1] * raw.height, region[2] * raw.width, region[3] * raw.height];
    img = crop(img, ...(region.map(Math.round) as [number, number, number, number]));
  }
  if (opts.scale) img = scale(img, opts.scale);
  mkdirSync(dirname(opts.out), { recursive: true });
  writeFileSync(opts.out, png(img));
  return {
    path: opts.out,
    width: img.width,
    height: img.height,
    client: full,
    clientOriginOnScreen: [raw.screenX, raw.screenY],
    region: region?.map(Math.round) ?? null,
    blank: isBlank(raw),
  };
}
