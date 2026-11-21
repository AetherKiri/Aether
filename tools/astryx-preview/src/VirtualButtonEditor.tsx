import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type PointerEvent,
} from "react";
import { Dialog } from "@astryxdesign/core/Dialog";
import { Button } from "@astryxdesign/core/Button";
import { Selector } from "@astryxdesign/core/Selector";
import { TextInput } from "@astryxdesign/core/TextInput";
import { Text } from "@astryxdesign/core/Text";
import { Icon } from "@astryxdesign/core/Icon";
import {
  ArrowLeftIcon,
  ChevronDownIcon,
  ChevronUpIcon,
  ArrowsRightLeftIcon,
  ArrowsPointingOutIcon,
  AdjustmentsHorizontalIcon,
  PlusIcon,
} from "@heroicons/react/24/outline";
import { HStack } from "@astryxdesign/core/Layout";
import {
  actionNames,
  buttonBox,
  clamp,
  glyphs,
  keyOptions,
  firstProfile,
  resolve,
  type Box,
  type Cap,
  type Profile,
  type Profiles,
} from "./virtualButtons";
import leftMouse from "../../../apps/godot_app/assets/ui/virtual_controls/mouse_left.svg";
import rightMouse from "../../../apps/godot_app/assets/ui/virtual_controls/mouse_right.svg";
import tokens from "../../../apps/godot_app/assets/ui/astryx/tokens.json";
import "./virtualButtons.css";

type Props = {
  scope: string;
  backdrop?: string;
  initial: Profiles;
  global?: Profiles;
  dark: boolean;
  opacity: number;
  onSave: (value: Profiles) => void;
  onClose: () => void;
};
type Drag = {
  pointer: number;
  id: string;
  startX: number;
  startY: number;
  box: Box;
  base: number;
  resize: boolean;
};
const options = keyOptions.map((value) => ({
  value,
  label: actionNames[value] ?? value,
}));

function useLandscapePreview() {
  useEffect(() => {
    if (window.parent === window) return;
    const message = (open: boolean) =>
      window.parent.postMessage(
        { type: "aether-layout-landscape", open },
        location.origin,
      );
    message(true);
    return () => message(false);
  }, []);
}

function useBoardSize(board: HTMLDivElement | null) {
  const [size, setSize] = useState({ w: 844, h: 390 });
  useLayoutEffect(() => {
    if (!board) return;
    const measure = () =>
      setSize({ w: board.clientWidth, h: board.clientHeight });
    const observer = new ResizeObserver(measure);
    measure();
    observer.observe(board);
    return () => observer.disconnect();
  }, [board]);
  return size;
}

function GamepadKeys({
  profile,
  w,
  h,
  opacity,
  selected,
  start,
  select,
  inputMode = "mouse",
}: {
  profile: Profile;
  w: number;
  h: number;
  opacity: number;
  selected?: string;
  start?: (e: PointerEvent, cap: Cap) => void;
  select?: (id: string) => void;
  inputMode?: string;
}) {
  return profile.buttons
    .filter(
      (cap) =>
        inputMode !== "mouse_only" &&
        (inputMode !== "touch" ||
          !["mouse_left", "mouse_right"].includes(cap.action)),
    )
    .map((cap) => {
      const b = buttonBox(cap, w, h),
        isPad = cap.action === "pad";
      return (
        <button
          type="button"
          key={cap.id}
          className={"pad-cap" + (isPad ? " pad-disc" : "")}
          aria-label={actionNames[cap.action] ?? cap.action}
          aria-pressed={
            selected === undefined ? undefined : cap.id === selected
          }
          style={
            {
              left: b.x,
              top: b.y,
              width: b.d,
              height: b.d,
              fontSize: Math.round(
                (cap.scale ?? 1) *
                  (isPad
                    ? 24
                    : (glyphs[cap.action] ?? cap.action).length > 2
                      ? 14
                      : 17),
              ),
              "--cap-opacity": opacity,
            } as CSSProperties
          }
          onPointerDown={start && ((e) => start(e, cap))}
          onClick={select && (() => select(cap.id))}
        >
          {isPad ? (
            (profile.pad_mode === "wasd"
              ? ["W", "A", "S", "D"]
              : ["↑", "←", "↓", "→"]
            ).map((l, i) => (
              <span key={i} data-dir={i}>
                {l}
              </span>
            ))
          ) : cap.action === "mouse_left" || cap.action === "mouse_right" ? (
            <img
              alt=""
              draggable={false}
              className="pad-mouse"
              src={cap.action === "mouse_left" ? leftMouse : rightMouse}
            />
          ) : (
            (glyphs[cap.action] ?? cap.action)
          )}
        </button>
      );
    });
}

export function VirtualButtonEditor({
  scope,
  backdrop,
  initial,
  global,
  dark,
  opacity,
  onClose,
  onSave,
}: Props) {
  useLandscapePreview();
  const [book, setBook] = useState(() => structuredClone(initial));
  const [selected, select] = useState("");
  const [manage, setManage] = useState(false);
  const [collapsed, setCollapsed] = useState(false);
  const [board, setBoard] = useState<HTMLDivElement | null>(null);
  const drag = useRef<Drag | null>(null);
  const size = useBoardSize(board);
  const { w, h } = size;
  useLayoutEffect(() => {
    drag.current = null;
  }, [w, h]);
  const current = resolve(book, global);
  const active = current.buttons.find((b) => b.id === selected);
  const owned = book.profiles.some((p) => p.id === book.active);
  const choices = [
    ...(global ? [{ value: "inherit", label: "跟随全局" }] : []),
    ...(global?.profiles ?? []).map((p) => ({
      value: p.id,
      label: "全局 · " + p.name,
    })),
    ...book.profiles.map((p) => ({ value: p.id, label: p.name })),
  ];
  function copyProfile(source: Profile, items: Profile[]): Profile {
    const available = [...(global?.profiles ?? []), ...items];
    let n = available.length + 1;
    while (available.some((p) => p.name === "方案" + n)) n++;
    return {
      ...structuredClone(source),
      id: (global ? "g-" : "p-") + crypto.randomUUID(),
      name: "方案" + n,
    };
  }
  // Editing an inherited layout creates a copy for the current game.
  function edit(change: (p: Profile) => Profile, forceCopy = false) {
    setBook((prev) => {
      const source = resolve(prev, global);
      const index = prev.profiles.findIndex((p) => p.id === prev.active);
      if (index < 0 || forceCopy) {
        if (prev.profiles.length >= 32) return prev;
        const p = change(copyProfile(source, prev.profiles));
        return { ...prev, active: p.id, profiles: [...prev.profiles, p] };
      }
      return {
        ...prev,
        profiles: prev.profiles.map((p, i) => (i === index ? change(p) : p)),
      };
    });
  }
  const editable = owned || book.profiles.length < 32;
  function updateCap(id: string, patch: Partial<Cap>) {
    edit((p) => ({
      ...p,
      buttons: p.buttons.map((b) => (b.id === id ? { ...b, ...patch } : b)),
    }));
  }
  function start(e: PointerEvent, cap: Cap, resize = false) {
    if (!e.isPrimary || e.button !== 0 || !board) return;
    e.preventDefault();
    e.stopPropagation();
    select(cap.id);
    setManage(false);
    board.setPointerCapture(e.pointerId);
    drag.current = {
      pointer: e.pointerId,
      id: cap.id,
      startX: e.clientX,
      startY: e.clientY,
      box: buttonBox(cap, w, h),
      base: buttonBox({ ...cap, scale: 1 }, w, h).d,
      resize,
    };
  }
  function move(e: PointerEvent) {
    const track = drag.current;
    if (!track || track.pointer !== e.pointerId || !editable) return;
    const rotated = matchMedia("(orientation: portrait)").matches;
    const dx = rotated ? e.clientY - track.startY : e.clientX - track.startX;
    const dy = rotated ? track.startX - e.clientX : e.clientY - track.startY;
    if (Math.hypot(dx, dy) < 3) return;
    const { box, base } = track;
    const scale = clamp((box.d + 0.5 * (dx + dy)) / base, 0.65, 2.4);
    const d = track.resize ? Math.min(base * scale, w, h) : box.d;
    const cx = box.x + (track.resize ? (d - box.d) / 2 : dx),
      cy = box.y + (track.resize ? (d - box.d) / 2 : dy);
    updateCap(track.id, {
      x: clamp(cx, d / 2, w - d / 2) / w,
      y: clamp(cy, d / 2, h - d / 2) / h,
      ...(track.resize ? { scale } : {}),
    });
  }
  function release(e: PointerEvent) {
    if (drag.current?.pointer === e.pointerId) drag.current = null;
  }
  const palette = tokens[dark ? "dark" : "light"];
  const style = Object.fromEntries(
    Object.entries(palette).map(([k, v]) => ["--pad-" + k, v]),
  ) as CSSProperties;
  const selectedBox = active && buttonBox(active, w, h);
  let gripX = 0,
    gripY = 0;
  if (selectedBox) {
    const { x, y, d } = selectedBox;
    gripX = clamp(x + d / 2 + 8, 16, size.w - 16);
    gripY = clamp(y + d / 2 + 8, 16, size.h - 16);
    if (Math.abs(gripX - x) <= 18 && Math.abs(gripY - y) <= 18)
      gripY = Math.max(16, y - d / 2 - 8);
  }
  return (
    <Dialog
      isOpen
      variant="fullscreen"
      padding={0}
      purpose="form"
      aria-label="虚拟按钮"
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <div className="pad-editor" style={style}>
        {backdrop && (
          <img
            className="pad-backdrop"
            src={backdrop}
            alt=""
            draggable={false}
          />
        )}
        <div
          ref={setBoard}
          className="pad-board"
          aria-label="布局画布"
          onPointerDown={() => {
            select("");
            setManage(false);
          }}
          onPointerMove={move}
          onPointerUp={release}
          onPointerCancel={release}
          onLostPointerCapture={release}
        >
          <GamepadKeys
            profile={current}
            w={w}
            h={h}
            opacity={opacity}
            selected={selected}
            start={start}
            select={select}
          />
          {active && selectedBox && (
            <button
              type="button"
              className="pad-handle pad-grip"
              aria-label="缩放选中的按钮"
              style={{ left: gripX, top: gripY }}
              onPointerDown={(e) => start(e, active, true)}
            >
              <Icon icon={ArrowsPointingOutIcon} size="sm" />
            </button>
          )}
          {active?.action === "pad" && selectedBox && (
            <button
              type="button"
              className="pad-handle pad-mode"
              aria-label="切换方向模式"
              title={
                current.pad_mode === "wasd"
                  ? "WASD → ↑ ↓ ← →"
                  : "↑ ↓ ← → → WASD"
              }
              style={{
                left: gripX,
                top: clamp(selectedBox.y - selectedBox.d / 2 - 8, 16, h - 16),
              }}
              onPointerDown={(e) => e.stopPropagation()}
              onClick={() =>
                edit((p) => ({
                  ...p,
                  pad_mode: p.pad_mode === "wasd" ? "arrows" : "wasd",
                }))
              }
            >
              <Icon icon={ArrowsRightLeftIcon} size="sm" />
            </button>
          )}
        </div>
        <section
          className={"pad-float" + (collapsed ? " pad-folded" : "")}
          aria-label="编辑工具"
        >
          {collapsed ? (
            <Button
              label="展开工具栏"
              isIconOnly
              variant="ghost"
              icon={<Icon icon={ChevronDownIcon} />}
              onClick={() => setCollapsed(false)}
            />
          ) : (
            <>
              <div className="pad-bar">
                <Button
                  label="取消"
                  isIconOnly
                  variant="ghost"
                  icon={<Icon icon={ArrowLeftIcon} />}
                  onClick={onClose}
                />
                <div className="pad-identity">
                  <Text weight="semibold">{current.name}</Text>
                  <Text type="supporting" color="secondary">
                    {scope}
                  </Text>
                </div>
                <Button
                  label={manage ? "收起方案选项" : "方案选项"}
                  isIconOnly
                  variant={manage ? "secondary" : "ghost"}
                  icon={<Icon icon={AdjustmentsHorizontalIcon} />}
                  onClick={() => setManage(!manage)}
                />
                <Button
                  label="新增按钮"
                  variant="secondary"
                  icon={<Icon icon={PlusIcon} size="sm" />}
                  isDisabled={!editable || current.buttons.length >= 64}
                  onClick={() => {
                    const id = "b-" + crypto.randomUUID();
                    edit((p) => ({
                      ...p,
                      buttons: [
                        ...p.buttons,
                        { id, action: "Space", x: 0.5, y: 0.5 },
                      ],
                    }));
                    select(id);
                    setManage(false);
                  }}
                />
                <Button
                  label="完成"
                  variant="primary"
                  isDisabled={book.profiles.some((p) => !p.name.trim())}
                  onClick={() =>
                    onSave({
                      ...book,
                      profiles: book.profiles.map((p) => ({
                        ...p,
                        name: p.name.trim(),
                      })),
                    })
                  }
                />
                <Button
                  label="收起工具栏"
                  isIconOnly
                  variant="ghost"
                  icon={<Icon icon={ChevronUpIcon} />}
                  onClick={() => setCollapsed(true)}
                />
              </div>
              {manage ? (
                <div className="pad-manager">
                  <div className="pad-profiles">
                    <Selector
                      label="布局方案"
                      isLabelHidden
                      options={choices}
                      value={book.active || "inherit"}
                      onChange={(id) => {
                        setBook({
                          ...book,
                          active: id === "inherit" ? "" : id,
                        });
                        select("");
                      }}
                    />
                    <Button
                      label="新建方案"
                      isDisabled={book.profiles.length >= 32}
                      onClick={() => {
                        edit((p) => p, true);
                        setManage(true);
                        select("");
                      }}
                    />
                  </div>
                  <div className="pad-options">
                    {owned && (
                      <TextInput
                        label="方案名称"
                        value={current.name}
                        onChange={(name) =>
                          edit((p) => ({ ...p, name: name.slice(0, 48) }))
                        }
                      />
                    )}
                    <HStack gap={2} wrap="wrap">
                      <Button
                        label="恢复默认布局"
                        isDisabled={!editable}
                        onClick={() => {
                          edit((p) => ({
                            ...firstProfile(),
                            id: p.id,
                            name: p.name,
                          }));
                          select("");
                        }}
                      />
                      {owned && (global || book.profiles.length > 1) && (
                        <Button
                          label="删除方案"
                          variant="ghost"
                          onClick={() => {
                            const profiles = book.profiles.filter(
                              (p) => p.id !== book.active,
                            );
                            setBook({
                              ...book,
                              active: profiles[0]?.id ?? "",
                              profiles,
                            });
                            select("");
                          }}
                        />
                      )}
                    </HStack>
                  </div>
                </div>
              ) : (
                active &&
                active.action !== "pad" && (
                  <div className="pad-tools">
                    <Selector
                      label="触发按键"
                      isLabelHidden
                      value={active.action}
                      options={options}
                      onChange={(action) => updateCap(active.id, { action })}
                    />
                    <Button
                      label="删除按钮"
                      variant="ghost"
                      onClick={() => {
                        edit((p) => ({
                          ...p,
                          buttons: p.buttons.filter((b) => b.id !== selected),
                        }));
                        select("");
                      }}
                    />
                  </div>
                )
              )}
            </>
          )}
        </section>
      </div>
    </Dialog>
  );
}

export function VirtualButtonGamePreview({
  initial,
  global,
  opacity,
  backdrop,
  onClose,
}: Pick<Props, "initial" | "global" | "opacity" | "backdrop" | "onClose">) {
  useLandscapePreview();
  const profiles = [...(global?.profiles ?? []), ...initial.profiles];
  const [index, setIndex] = useState(() =>
    profiles.findIndex((p) => p.id === resolve(initial, global).id),
  );
  const [board, setBoard] = useState<HTMLDivElement | null>(null);
  const { w, h } = useBoardSize(board);
  const [menu, setMenu] = useState(false);
  const [selector, showSelector] = useState(true);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const [inputMode, setInputMode] = useState<"mouse" | "touch" | "mouse_only">(
    "mouse",
  );
  function reveal() {
    clearTimeout(timer.current);
    showSelector(true);
    timer.current = setTimeout(() => showSelector(false), 3000);
  }
  useEffect(() => {
    reveal();
    return () => clearTimeout(timer.current);
  }, []);
  return (
    <Dialog
      isOpen
      variant="fullscreen"
      padding={0}
      purpose="form"
      aria-label="游戏按键预览"
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
    >
      <div className="pad-editor pad-runtime">
        {backdrop && (
          <img
            className="pad-backdrop"
            src={backdrop}
            alt=""
            draggable={false}
          />
        )}
        <div className="pad-board" ref={setBoard}>
          {!menu && (
            <GamepadKeys
              profile={profiles[index]}
              w={w}
              h={h}
              opacity={opacity}
              inputMode={inputMode}
            />
          )}
          {!menu && selector && (
            <div
              className="pad-runtime-profile"
              style={{ opacity }}
              onPointerDown={() => clearTimeout(timer.current)}
              onPointerUp={reveal}
              onPointerCancel={reveal}
              onPointerLeave={reveal}
            >
              <Button
                label={profiles[index].name}
                variant="secondary"
                onClick={() => {
                  setIndex((i) => (i + 1) % profiles.length);
                  reveal();
                }}
              />
            </div>
          )}
          <div className="pad-runtime-menu">
            <Button
              label="游戏菜单"
              variant="secondary"
              isIconOnly
              icon={<Icon icon={AdjustmentsHorizontalIcon} />}
              onClick={() => {
                setMenu(!menu);
                if (menu) reveal();
              }}
            />
            {menu && (
              <div className="pad-runtime-options">
                <Button
                  label="虚拟按键"
                  onClick={() => {
                    setMenu(false);
                    reveal();
                  }}
                />
                <Button
                  label={
                    {
                      mouse: "鼠标模式",
                      touch: "触屏模式",
                      mouse_only: "纯鼠标模式",
                    }[inputMode]
                  }
                  onClick={() =>
                    setInputMode((m) =>
                      m === "mouse"
                        ? "touch"
                        : m === "touch"
                          ? "mouse_only"
                          : "mouse",
                    )
                  }
                />
                <Button label="返回游戏详情" onClick={onClose} />
              </div>
            )}
          </div>
        </div>
      </div>
    </Dialog>
  );
}
