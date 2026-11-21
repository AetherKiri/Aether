import catalog from "../../../apps/godot_app/config/virtual_button_catalog.json";

export type Cap = {
  id: string;
  action: string;
  x?: number;
  y?: number;
  scale?: number;
};
export type Profile = {
  id: string;
  name: string;
  pad_mode: "wasd" | "arrows";
  buttons: Cap[];
  opacity?: number;
};
export type Profiles = { active: string; profiles: Profile[] };
export const mouse: Profile = {
  id: "mouse",
  name: "Mouse",
  pad_mode: "wasd",
  buttons: catalog.mouse_buttons.map((id) => ({ id, action: id })),
};
export const emptyProfiles = (game: boolean): Profiles => ({
  active: game ? "" : "mouse",
  profiles: [],
});
export function resolve(book: Profiles, global?: Profiles): Profile {
  if (book.active === "mouse") return mouse;
  return (
    book.profiles.find((p) => p.id === book.active) ??
    global?.profiles.find((p) => p.id === book.active) ??
    (global ? resolve(global) : mouse)
  );
}
export const keyOptions = [
  ...Object.keys(catalog.key_codes),
  ..."ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
  ...Array.from({ length: 12 }, (_, i) => "F" + (i + 1)),
  "mouse_left",
  "mouse_right",
  "wheel_up",
  "wheel_down",
];
export const actionNames: Record<string, string> = {
  pad: "方向键",
  mouse_left: "鼠标左键",
  mouse_right: "鼠标右键",
  wheel_up: "向上滚动",
  wheel_down: "向下滚动",
};
export const glyphs: Record<string, string> = {
  wheel_up: "▲",
  wheel_down: "▼",
  Up: "↑",
  Down: "↓",
  Left: "←",
  Right: "→",
};
export const clamp = (n: number, low: number, high: number) =>
  Math.max(low, Math.min(high, n));
export type Box = { x: number; y: number; d: number };

// Centers and diameters in game coordinates. Untouched Mouse controls keep
// their edge anchors; edited centers are fractions of the current safe area.
export function mouseGeometry(w: number, h: number): Record<string, Box> {
  const edge = Math.min(w, h),
    d = clamp(edge * 0.13, 44, 68),
    gap = clamp(d * 0.13, 6, 9),
    m = clamp(d * 0.2, 9, 14);
  const pad = clamp(edge * 0.36, 118, 210),
    a = d * 1.12,
    bottom = h - m - d;
  const digitX = w - 44 - d - gap,
    left = digitX - 2 * (a + gap);
  const scroll = clamp(
    (h - 2 * d - gap) * 0.46,
    m + d + gap,
    Math.max(m + d + gap, h - m - pad - 2 * (d + gap)),
  );
  const boxes: Record<string, Box> = {};
  function place(id: string, x: number, y: number, s: number) {
    boxes[id] = { x: x + s / 2, y: y + s / 2, d: s };
  }
  place("pad", m, h - m - pad, pad);
  place("Esc", m, m, d);
  place("wheel_up", m, scroll, d);
  place("wheel_down", m, scroll + d + gap, d);
  const compact = w < 1.25 * h;
  const right = compact ? w - m - a : left + a + gap,
    near = right - a - gap;
  const ctrlX = m + pad + gap;
  place(
    "Ctrl",
    compact ? m : ctrlX,
    compact ? h - m - pad - gap - d : bottom,
    d,
  );
  place("mouse_left", near, bottom - a - gap, a);
  place("mouse_right", right, bottom - a - gap, a);
  place("Space", near, bottom, a);
  place("Enter", right, bottom, a);
  for (let i = 0; i < 4; i++)
    place(String(i + 1), digitX, m + d * 0.24 + i * (d + gap), d);
  return boxes;
}
export function buttonBox(
  cap: Cap,
  w: number,
  h: number,
  homes = mouseGeometry(w, h),
): Box {
  const base = homes[cap.id] ?? {
    x: w / 2,
    y: h / 2,
    d: clamp(Math.min(w, h) * 0.13, 44, 68),
  };
  const d = Math.min(w, h, base.d * (cap.scale ?? 1));
  return {
    x: clamp(cap.x == null ? base.x : cap.x * w, d / 2, w - d / 2),
    y: clamp(cap.y == null ? base.y : cap.y * h, d / 2, h - d / 2),
    d,
  };
}
