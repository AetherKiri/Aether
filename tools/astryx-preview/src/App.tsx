// Settings and detail compositions adapted from Meta Astryx's MIT templates.
// Every interactive control below is imported from the original local library.
import {
  useEffect,
  useLayoutEffect,
  useState,
  useRef,
  type CSSProperties,
  type ReactNode,
} from "react";
import appIcon from "../../../apps/godot_app/assets/icon.png";
import { Theme } from "@astryxdesign/core/theme";
import { neutralTheme } from "@astryxdesign/theme-neutral/built";
import { AppShell } from "@astryxdesign/core/AppShell";
import {
  SideNav,
  SideNavHeading,
  SideNavItem,
} from "@astryxdesign/core/SideNav";
import {
  Layout,
  LayoutHeader,
  LayoutPanel,
  LayoutContent,
  LayoutFooter,
  HStack,
  VStack,
  StackItem,
} from "@astryxdesign/core/Layout";
import { Grid } from "@astryxdesign/core/Grid";
import { Heading, Text } from "@astryxdesign/core/Text";
import { Button } from "@astryxdesign/core/Button";
import { Link } from "@astryxdesign/core/Link";
import { Toolbar } from "@astryxdesign/core/Toolbar";
import { IconButton } from "@astryxdesign/core/IconButton";
import { Icon } from "@astryxdesign/core/Icon";
import { List, ListItem } from "@astryxdesign/core/List";
import { TabList, Tab } from "@astryxdesign/core/TabList";
import {
  SegmentedControl,
  SegmentedControlItem,
} from "@astryxdesign/core/SegmentedControl";
import { TextInput } from "@astryxdesign/core/TextInput";
import { Selector } from "@astryxdesign/core/Selector";
import { Switch } from "@astryxdesign/core/Switch";
import { Slider } from "@astryxdesign/core/Slider";
import { Divider } from "@astryxdesign/core/Divider";
import { ClickableCard } from "@astryxdesign/core/ClickableCard";
import { Card } from "@astryxdesign/core/Card";
import { SelectableCard } from "@astryxdesign/core/SelectableCard";
import { AspectRatio } from "@astryxdesign/core/AspectRatio";
import { Collapsible, CollapsibleGroup } from "@astryxdesign/core/Collapsible";
import { Dialog, DialogHeader } from "@astryxdesign/core/Dialog";
import { ToastViewport, useToast } from "@astryxdesign/core/Toast";
import { Breadcrumbs, BreadcrumbItem } from "@astryxdesign/core/Breadcrumbs";
import { useMediaQuery } from "@astryxdesign/core/hooks";
import {
  BookOpenIcon,
  FilmIcon,
  BoltIcon,
  Cog6ToothIcon,
  FolderIcon,
  PhotoIcon,
  ChevronRightIcon,
  ArrowLeftIcon,
  MagnifyingGlassIcon,
  PlusIcon,
  PlayIcon,
  PauseIcon,
  Squares2X2Icon,
  ListBulletIcon,
  SwatchIcon,
  ComputerDesktopIcon,
  ShieldCheckIcon,
  WrenchScrewdriverIcon,
  InformationCircleIcon,
  TrashIcon,
} from "@heroicons/react/24/outline";

import {
  BookOpenIcon as BookOpenSolid,
  FilmIcon as FilmSolid,
  BoltIcon as BoltSolid,
  Cog6ToothIcon as SettingsSolid,
} from "@heroicons/react/24/solid";
const selectedNavigationIcons = {
  library: BookOpenSolid,
  videos: FilmSolid,
  flash: BoltSolid,
  settings: SettingsSolid,
};

type Route = "library" | "videos" | "flash" | "settings" | "detail";
type Mode = "light" | "dark";
type Preferences = {
  theme: Mode;
  language: string;
  keyboard: boolean;
  opacity: number;
  backend: string;
  upscale: string;
  resolution: string;
  enhancement: string;
  preset: string;
  customChain: string[];
  prerelease: boolean;
  fps: boolean;
  limit: string;
  plugins: string;
  mock: boolean;
  diagnostic: string;
  overlay: string;
  logs: boolean;
};
const initial: Preferences = {
  theme: "light",
  language: "简体中文",
  keyboard: true,
  opacity: 100,
  backend: "Godot Native",
  upscale: "Bicubic",
  resolution: "1080p",
  enhancement: "关闭",
  preset: "柔和清晰（推荐，中低负载）",
  customChain: ["Anime4K Upscale S", "Bicubic", "Anime4K Restore Soft S"],
  prerelease: false,
  fps: false,
  limit: "60",
  plugins: "核心插件",
  mock: false,
  diagnostic: "基线",
  overlay: "关闭",
  logs: true,
};
const navigation: [Route, string, typeof BookOpenIcon][] = [
  ["library", "游戏库", BookOpenIcon],
  ["videos", "视频", FilmIcon],
  ["flash", "Flash", BoltIcon],
  ["settings", "设置", Cog6ToothIcon],
];
const groups = ["界面", "画面", "兼容性", "诊断", "关于"];
// The same stable values written by the Godot game settings presenter.
const renderChoices = {
  upscale_algorithm: [
    ["smooth", "Smooth"],
    ["linear", "Linear"],
    ["nearest", "Nearest"],
    ["bicubic", "Bicubic"],
    ["lanczos", "Lanczos"],
    ["metalfx_spatial", "MetalFX Spatial"],
  ],
  output_resolution: [
    ["original", "原始分辨率"],
    ["1080p", "1080p"],
    ["2k", "2K (2560×1440)"],
    ["4k", "4K (3840×2160)"],
  ],
  frame_enhancement_kind: [
    ["off", "关闭"],
    ["preset", "预设"],
    ["custom", "自定义"],
  ],
  frame_enhancement_mode: [
    ["chain_4k_max", "4K 极致（极高负载）"],
    ["chain_lossless", "无损画质（极高负载）"],
    ["chain_ultra", "超清平衡（高负载）"],
    ["chain_detail", "高精细（中高负载）"],
    ["chain_balanced", "均衡增强（中等负载）"],
    ["chain_soft", "柔和清晰（推荐，中低负载）"],
    ["chain_light", "轻量增强（低负载）"],
    ["chain_basic", "基础增强（最低负载）"],
  ],
};
type GameText = { encoding: string; fontName: string; fontFamily: string };
const defaultGameText: GameText = {
  encoding: "",
  fontName: "",
  fontFamily: "",
};
const textEngines = [
  "ONScripter Yuri",
  "YU-RIS",
  "SystemC",
  "RFVP",
  "BGI",
  "ADVHD",
  "Escu:de",
  "SoftPal",
  "CatSystem2",
  "EntisGLS",
];
function textEncodings(runtime: string) {
  return runtime === "EntisGLS"
    ? [""]
    : ["ONScripter Yuri", "RFVP"].includes(runtime)
      ? ["", "CP932", "GBK", "UTF-8"]
      : ["", "CP932", "GBK", "GB18030", "BIG5", "UTF-8"];
}
type GameRendering = Record<keyof typeof renderChoices, string> & {
  customChain: string[];
};
const inheritedRendering: GameRendering = {
  upscale_algorithm: "",
  output_resolution: "",
  frame_enhancement_kind: "",
  frame_enhancement_mode: "chain_soft",
  customChain: initial.customChain,
};
const enhancementAlgorithms = [
  "Anime4K Upscale S",
  "Anime4K Upscale L",
  "Anime4K Upscale VL",
  "Anime4K Restore S",
  "Anime4K Restore Soft S",
  "Anime4K Restore Soft M",
  "Anime4K Restore L",
  "Anime4K Restore VL",
  "FSR1 EASU",
  "FSR1 RCAS",
  "Bicubic",
  "Lanczos",
  "FXAA",
  "RAVU-Lite R2",
  "CuNNy 2x4C",
  "NNEDI3 nns16",
];
const groupIcons = [
  SwatchIcon,
  ComputerDesktopIcon,
  ShieldCheckIcon,
  WrenchScrewdriverIcon,
  InformationCircleIcon,
];
const settingsRowPadding: CSSProperties = { paddingBlock: "var(--spacing-4)" };
const detailSectionPadding: CSSProperties = {
  paddingBlockStart: "var(--spacing-3)",
};
type Game = {
  name: string;
  runtime: string;
  playDurationSeconds: number;
  lastPlayed: number;
  covers: string[];
};
const sampleNow = Math.floor(Date.now() / 1000);
const games: Game[] = [
  {
    name: "Aether Demo",
    runtime: "KiriKiri",
    playDurationSeconds: 8100,
    lastPlayed: sampleNow - 7200,
    covers: ["/demo-cover.svg", "/demo-scene.svg"],
  },
  {
    name: "海边的来信",
    runtime: "ONScripter Yuri",
    playDurationSeconds: 2520,
    lastPlayed: sampleNow - 86400,
    covers: ["/demo-landscape.svg", "/demo-scene.svg"],
  },
  {
    name: "星空下的约定",
    runtime: "YU-RIS",
    playDurationSeconds: 0,
    lastPlayed: 0,
    covers: ["/demo-night.svg", "/demo-scene.svg"],
  },
  {
    name: "下一段故事",
    runtime: "EntisGLS",
    playDurationSeconds: 0,
    lastPlayed: 0,
    covers: ["/demo-cover.svg"],
  },
];
function gameHistory(game: Game) {
  const minutes = Math.floor(Math.max(0, game.playDurationSeconds) / 60);
  const hours = Math.floor(minutes / 60);
  const duration = hours
    ? `${hours}h${minutes % 60 ? ` ${minutes % 60}m` : ""}`
    : `${minutes}m`;
  const last = game.lastPlayed > 0 ? new Date(game.lastPlayed * 1000) : null;
  const pad = (value: number) => String(value).padStart(2, "0");
  const date = last
    ? `${last.getFullYear() === new Date().getFullYear() ? "" : `${last.getFullYear()}/`}${pad(last.getMonth() + 1)}/${pad(last.getDate())} ${pad(last.getHours())}:${pad(last.getMinutes())}`
    : "";
  return (
    <VStack gap={0.5}>
      <Text type="supporting" color="secondary">
        已玩 {duration}
      </Text>
      <Text type="supporting" color="secondary">
        {last ? `最近启动 ${date}` : "尚未启动"}
      </Text>
    </VStack>
  );
}
type MediaEntry = {
  id: string;
  name: string;
  kind: "folder" | "video" | "flash";
  description: string;
  children?: MediaEntry[];
};
const videoFiles: MediaEntry[] = [
  {
    id: "animation",
    name: "动画收藏",
    kind: "folder",
    description: "2 个视频 · 1 个文件夹",
    children: [
      {
        id: "ep1",
        name: "第一话 · 故事的开始.mp4",
        kind: "video",
        description: "24:10 · 1080p",
      },
      {
        id: "ep2",
        name: "第二话 · 海边的约定.mkv",
        kind: "video",
        description: "23:48 · 1080p",
      },
      {
        id: "extras",
        name: "特别篇",
        kind: "folder",
        description: "1 个视频",
        children: [
          {
            id: "extra",
            name: "特别篇 · 夏日回忆.mp4",
            kind: "video",
            description: "12:36 · 1080p",
          },
        ],
      },
    ],
  },
  {
    id: "travel",
    name: "旅行记录",
    kind: "folder",
    description: "2 个视频",
    children: [
      {
        id: "sea",
        name: "海边的午后.mov",
        kind: "video",
        description: "03:42 · 4K",
      },
      {
        id: "train",
        name: "沿途风景.mp4",
        kind: "video",
        description: "06:18 · 1080p",
      },
    ],
  },
  {
    id: "opening",
    name: "Opening Movie.mp4",
    kind: "video",
    description: "01:32 · 1080p",
  },
  {
    id: "preview",
    name: "游戏预告片.mkv",
    kind: "video",
    description: "02:18 · 1080p",
  },
  {
    id: "empty",
    name: "待整理",
    kind: "folder",
    description: "空文件夹",
    children: [],
  },
];
const flashFiles: MediaEntry[] = [
  {
    id: "flash-folder",
    name: "Flash 收藏",
    kind: "folder",
    description: "1 个文件",
    children: [
      {
        id: "flash-1",
        name: "小小冒险.swf",
        kind: "flash",
        description: "Flash 动画",
      },
    ],
  },
  {
    id: "flash-2",
    name: "像素时钟.swf",
    kind: "flash",
    description: "Flash 动画",
  },
];

function findFolderPath(
  entries: MediaEntry[],
  id: string,
): MediaEntry[] | undefined {
  for (const entry of entries) {
    if (entry.kind !== "folder") continue;
    if (entry.id === id) return [entry];
    const nested = findFolderPath(entry.children ?? [], id);
    if (nested) return [entry, ...nested];
  }
}

function SettingSection({
  title,
  description,
  children,
}: {
  title: string;
  description: string;
  children: ReactNode;
}) {
  return (
    <VStack gap={0}>
      <VStack gap={1} style={{ paddingBlock: "var(--spacing-4)" }}>
        <Heading level={3}>{title}</Heading>
        {description && (
          <Text type="supporting" color="secondary">
            {description}
          </Text>
        )}
      </VStack>
      {children}
    </VStack>
  );
}

function SaveFeedback({ feedback }: { feedback: { body: string } | null }) {
  const showToast = useToast();
  useEffect(() => {
    if (feedback) {
      return showToast({ ...feedback, uniqueID: "settings-saved" });
    }
  }, [feedback, showToast]);
  return null;
}

export function App() {
  const phone = useMediaQuery("(max-width: 699px)");
  const [bottomNav, setBottomNav] = useState<HTMLDivElement | null>(null);
  const [bottomNavHeight, setBottomNavHeight] = useState(0);
  useLayoutEffect(() => {
    if (!bottomNav) {
      setBottomNavHeight(0);
      return;
    }
    const measure = () =>
      setBottomNavHeight(bottomNav.getBoundingClientRect().height);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(bottomNav);
    return () => observer.disconnect();
  }, [bottomNav]);
  const [saved, setSaved] = useState<Preferences>(() => {
    try {
      return {
        ...initial,
        ...JSON.parse(localStorage.getItem("aether-astryx-react") || "{}"),
      };
    } catch {
      return initial;
    }
  });
  const [draft, setDraft] = useState(saved);
  const [route, setRoute] = useState<Route>("settings");
  const [group, setGroup] = useState("界面");
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState("all");
  const [navCollapsed, setNavCollapsed] = useState(true);
  // Match the template's 768px content breakpoint after the global app rail.
  const settingsNarrow = useMediaQuery(
    navCollapsed ? "(max-width: 816px)" : "(max-width: 1028px)",
  );
  const [settingsDetail, setSettingsDetail] = useState(!settingsNarrow);
  const [editingSetting, setEditingSetting] = useState("");
  useEffect(() => {
    if (route === "settings" && !settingsNarrow) setSettingsDetail(true);
  }, [route, settingsNarrow]);
  const [libraryDisplay, setLibraryDisplay] = useState<"cards" | "list">(() => {
    try {
      return localStorage.getItem("aether-astryx-library-display") === "list"
        ? "list"
        : "cards";
    } catch {
      return "cards";
    }
  });
  const [selected, setSelected] = useState(games[0]);
  const [gameRendering, setGameRendering] = useState<
    Record<string, GameRendering>
  >({});
  const [gameText, setGameText] = useState<Record<string, GameText>>({});
  const fontPicker = useRef<HTMLInputElement>(null);
  const fontSerial = useRef(0);
  const previewFonts = useRef<FontFace[]>([]);
  useEffect(
    () => () => {
      previewFonts.current.forEach((font) => document.fonts.delete(font));
    },
    [],
  );
  const [thumb, setThumb] = useState(0);
  const [coverRatios, setCoverRatios] = useState<Record<string, number>>({});
  const [coverOverrides, setCoverOverrides] = useState<
    Record<string, string | null>
  >({});
  const [coverFiles, setCoverFiles] = useState<Record<string, string>>({});
  const [coverPicker, setCoverPicker] = useState(false);
  const [coverSources, setCoverSources] = useState(false);
  const [coverQuery, setCoverQuery] = useState("");
  const [coverStatus, setCoverStatus] = useState("");
  const [coverSearching, setCoverSearching] = useState(false);
  const [coverResults, setCoverResults] = useState<
    Array<{ id: string; title: string; url: string; thumbnail: string }>
  >([]);
  const coverSearchRequest = useRef<AbortController | null>(null);
  const coverFileInput = useRef<HTMLInputElement>(null);
  const coverFileGame = useRef("");
  const coverObjectURLs = useRef<string[]>([]);
  const previewPlatform = new URLSearchParams(location.search).get("platform");
  const canBrowsePhotos = previewPlatform
    ? ["ios", "android"].includes(previewPlatform)
    : /Android|iPhone|iPad|iPod/.test(navigator.userAgent) ||
      (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  useEffect(() => {
    if (!coverPicker) coverSearchRequest.current?.abort();
    return () => coverSearchRequest.current?.abort();
  }, [coverPicker]);
  useEffect(
    () => () => coverObjectURLs.current.forEach(URL.revokeObjectURL),
    [],
  );
  const [folders, setFolders] = useState<MediaEntry[]>([]);
  const [removedMedia, setRemovedMedia] = useState<string[]>([]);
  const [pendingMediaRemoval, setPendingMediaRemoval] =
    useState<MediaEntry | null>(null);
  const [pending, setPending] = useState<Route | null>(null);
  const [notice, setNotice] = useState("");
  const [saveFeedback, setSaveFeedback] = useState<{ body: string } | null>(
    null,
  );
  const [video, setVideo] = useState<MediaEntry | null>(null);
  const [playing, setPlaying] = useState(false);
  const [position, setPosition] = useState(0);
  // Fixture names remain stable identities for cover/history associations.
  const [gameNames, setGameNames] = useState<Record<string, string>>({});
  const [removedGames, setRemovedGames] = useState<string[]>([]);
  const [detailEdit, setDetailEdit] = useState<{
    game: string;
    key:
      | "name"
      | "encoding"
      | "font_file"
      | "upscale_algorithm"
      | "output_resolution"
      | "frame_enhancement_kind";
    name: string;
    rendering: GameRendering;
    text: GameText;
    id: number;
  } | null>(null);
  const [removingGame, setRemovingGame] = useState(false);
  const dirty = JSON.stringify(saved) !== JSON.stringify(draft);
  function changeLibraryDisplay(value: string) {
    if (value !== "cards" && value !== "list") return;
    setLibraryDisplay(value);
    try {
      localStorage.setItem("aether-astryx-library-display", value);
    } catch {
      setNotice("展示方式暂时无法保存，当前页面仍可切换。");
    }
  }
  function openGame(game: Game) {
    setSelected(game);
    setThumb(0);
    go("detail");
  }
  function titleFor(game: Game) {
    return gameNames[game.name] ?? game.name;
  }
  function coversFor(game: Game) {
    const override = coverOverrides[game.name];
    return override === null ? [] : override ? [override] : game.covers;
  }
  function chooseCover() {
    setCoverSources(true);
  }
  function browseCoverFile() {
    coverFileGame.current = selected.name;
    setCoverSources(false);
    coverFileInput.current?.click();
  }
  function importCoverFile(file?: File) {
    if (!file) return;
    const game = coverFileGame.current;
    if (!file.type.startsWith("image/") || file.size > 32 * 1024 * 1024) {
      setNotice("请选择有效的图片文件（最大 32 MiB）。");
      return;
    }
    const url = URL.createObjectURL(file);
    const image = new Image();
    image.onload = () => {
      coverObjectURLs.current.push(url);
      setCoverOverrides((values) => ({ ...values, [game]: url }));
      setCoverFiles((values) => ({ ...values, [game]: file.name }));
      setThumb(0);
    };
    image.onerror = () => {
      URL.revokeObjectURL(url);
      setNotice("无法读取这张图片。");
    };
    image.src = url;
  }
  function openCoverSearch() {
    setCoverSources(false);
    setCoverQuery(titleFor(selected));
    setCoverResults([]);
    setCoverStatus("");
    setCoverSearching(false);
    setCoverPicker(true);
  }
  async function searchCovers() {
    if (!coverQuery.trim() || coverSearching) return;
    coverSearchRequest.current?.abort();
    const request = new AbortController();
    coverSearchRequest.current = request;
    setCoverSearching(true);
    setCoverResults([]);
    setCoverStatus("正在搜索…");
    try {
      const response = await fetch("https://api.vndb.org/kana/vn", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        signal: request.signal,
        body: JSON.stringify({
          filters: ["search", "=", coverQuery.trim()],
          fields: "title,alttitle,image.url,image.thumbnail",
          sort: "searchrank",
          results: 20,
        }),
      });
      if (!response.ok) throw new Error("Search failed");
      const payload: {
        results?: Array<{
          id: string;
          title?: string;
          alttitle?: string | null;
          image?: { url?: string; thumbnail?: string } | null;
        }>;
      } = await response.json();
      const rows = (
        Array.isArray(payload.results) ? payload.results : []
      ).flatMap((row) => {
        const url = row.image?.url;
        if (!url || !/^https:\/\/[ts]\.vndb\.org\//.test(url)) return [];
        return [
          {
            id: row.id,
            title: row.alttitle || row.title || row.id,
            url,
            thumbnail: row.image?.thumbnail || url,
          },
        ];
      });
      if (request.signal.aborted) return;
      setCoverResults(rows);
      setCoverStatus(
        rows.length
          ? "选择结果以设置封面。"
          : "没有找到带封面的结果，请尝试其他名称。",
      );
    } catch {
      if (!request.signal.aborted)
        setCoverStatus("搜索失败，请检查网络后重试。");
    } finally {
      if (!request.signal.aborted) setCoverSearching(false);
    }
  }
  async function selectVndbCover(result: { id: string; url: string }) {
    if (coverSearching) return;
    const game = selected.name;
    coverSearchRequest.current?.abort();
    const request = new AbortController();
    coverSearchRequest.current = request;
    setCoverSearching(true);
    setCoverStatus("正在下载封面…");
    try {
      // VNDB permits image display, but not cross-origin fetch of image bytes.
      // The native app writes the file; the browser reference preloads it.
      await new Promise<void>((resolve, reject) => {
        const image = new Image();
        const abort = () => {
          image.onload = image.onerror = null;
          image.src = "";
          reject(new DOMException("Cancelled", "AbortError"));
        };
        image.onload = () => {
          request.signal.removeEventListener("abort", abort);
          resolve();
        };
        image.onerror = () => {
          request.signal.removeEventListener("abort", abort);
          reject(new Error("Download failed"));
        };
        request.signal.addEventListener("abort", abort, { once: true });
        image.src = result.url;
      });
      if (request.signal.aborted) return;
      setCoverOverrides((values) => ({ ...values, [game]: result.url }));
      setCoverFiles((values) => ({ ...values, [game]: `aether-cover-${result.id}.png` }));
      setThumb(0);
      setCoverPicker(false);
    } catch {
      if (!request.signal.aborted) setCoverStatus("封面下载失败，请重试。");
    } finally {
      if (!request.signal.aborted) setCoverSearching(false);
    }
  }
  function clearCover() {
    setCoverOverrides((current) => ({ ...current, [selected.name]: null }));
    setCoverFiles((current) => ({ ...current, [selected.name]: "" }));
    setThumb(0);
  }
  function coverPlaceholder(thumbnail = false) {
    return (
      <Card
        variant="muted"
        padding={0}
        width={thumbnail ? 54 : "100%"}
        height={thumbnail ? 72 : "100%"}
      >
        <VStack
          gap={2}
          hAlign="center"
          vAlign="center"
          style={{ height: "100%" }}
        >
          <Icon icon={BookOpenIcon} />
          {!thumbnail && <Text color="secondary">未设置封面</Text>}
        </VStack>
      </Card>
    );
  }
  function change<K extends keyof Preferences>(key: K, value: Preferences[K]) {
    setDraft((v) => ({ ...v, [key]: value }));
  }
  function save() {
    setSaved(draft);
    localStorage.setItem("aether-astryx-react", JSON.stringify(draft));
    setEditingSetting("");
    setSaveFeedback({
      body:
        draft.language === "English"
          ? "Changes saved"
          : draft.language === "日本語"
            ? "変更を保存しました"
            : "更改已保存",
    });
  }
  function go(next: Route) {
    setDetailEdit(null);
    if (next === "settings" && route !== next) {
      setSettingsDetail(false);
      setEditingSetting("");
    }
    setRoute(next);
    setQuery("");
    if (next !== route) setFolders([]);
  }
  function navigate(next: Route) {
    if (route === "settings" && dirty) setPending(next);
    else go(next);
  }
  function settingRow(
    key: string,
    label: string,
    value: string,
    editor: ReactNode,
    divider = true,
  ) {
    const expanded = editingSetting === key;
    return (
      <VStack gap={0}>
        <VStack gap={4} style={settingsRowPadding}>
          <HStack hAlign="between" vAlign="start" gap={4}>
            <VStack gap={0}>
              <Text weight="semibold">{label}</Text>
              {!expanded && (
                <Text type="supporting" color="secondary">
                  {value}
                </Text>
              )}
            </VStack>
            <Link
              href="#"
              aria-expanded={expanded}
              aria-label={`${expanded ? "收起" : "编辑"}${label}`}
              onClick={(event) => {
                event.preventDefault();
                setEditingSetting(expanded ? "" : key);
              }}
            >
              {expanded ? "收起" : "编辑"}
            </Link>
          </HStack>
          {expanded && editor}
        </VStack>
        {divider && <Divider />}
      </VStack>
    );
  }
  function selectField(
    label: string,
    key: keyof Preferences,
    options: string[],
  ) {
    return settingRow(
      key,
      label,
      String(draft[key]),
      <Selector
        label={label}
        isLabelHidden
        size="lg"
        options={options}
        value={String(draft[key])}
        onChange={(v) => change(key, v)}
      />,
    );
  }
  function toggleField(
    label: string,
    key: "keyboard" | "fps" | "mock" | "logs" | "prerelease",
    description?: string,
  ) {
    return (
      <VStack gap={0}>
        <div style={settingsRowPadding}>
          <Switch
            label={label}
            description={description}
            labelPosition="start"
            labelSpacing="spread"
            value={draft[key]}
            onChange={(value) => change(key, value)}
          />
        </div>
        <Divider />
      </VStack>
    );
  }
  function aboutRow(label: string, description: string, control: ReactNode) {
    return (
      <VStack gap={0}>
        <HStack gap={4} vAlign="center" style={settingsRowPadding}>
          <StackItem size="fill">
            <VStack gap={1}>
              <Text weight="semibold">{label}</Text>
              <Text type="supporting" color="secondary">
                {description}
              </Text>
            </VStack>
          </StackItem>
          <StackItem size="static">{control}</StackItem>
        </HStack>
        <Divider />
      </VStack>
    );
  }
  function aboutAction(
    label: string,
    description: string,
    action: string,
    message: string,
  ) {
    return aboutRow(
      label,
      description,
      <Link
        href="#"
        onClick={(event) => {
          event.preventDefault();
          setNotice(message);
        }}
      >
        {action}
      </Link>,
    );
  }
  function customChain(
    chain = draft.customChain,
    update = (value: string[]) => change("customChain", value),
    divider = true,
  ) {
    return (
      <VStack gap={0}>
        <VStack gap={4} style={settingsRowPadding}>
          <Text type="supporting" color="secondary">
            算法按列表从上到下执行；2×
            重建、目标尺寸缩放和同尺寸修复会保留各自语义。
          </Text>
          <VStack gap={4}>
            {chain.map((algorithm, index) => {
              const picker = (
                <Selector
                  label={`步骤 ${index + 1}`}
                  isLabelHidden
                  size="lg"
                  options={enhancementAlgorithms}
                  value={algorithm}
                  onChange={(value) =>
                    update(
                      chain.map((step, at) => (at === index ? value : step)),
                    )
                  }
                />
              );
              return (
                <VStack key={index} gap={2}>
                  <HStack gap={3} vAlign="center">
                    <StackItem size={phone ? "fill" : "static"}>
                      <Text type="supporting" weight="semibold">
                        步骤 {index + 1}
                      </Text>
                    </StackItem>
                    {!phone && <StackItem size="fill">{picker}</StackItem>}
                    <Link
                      href="#"
                      aria-label={`移除步骤 ${index + 1}`}
                      onClick={(event) => {
                        event.preventDefault();
                        update(chain.filter((_, at) => at !== index));
                      }}
                    >
                      移除
                    </Link>
                  </HStack>
                  {phone && picker}
                </VStack>
              );
            })}
          </VStack>
          {chain.length === 0 && (
            <Text type="supporting" color="secondary">
              当前没有算法；添加后会按照列表顺序处理画面。
            </Text>
          )}
          <HStack hAlign="end">
            <Button
              label="添加步骤"
              size="lg"
              isDisabled={chain.length >= 32}
              onClick={() => update([...chain, enhancementAlgorithms[0]])}
            />
          </HStack>
        </VStack>
        {divider && <Divider />}
      </VStack>
    );
  }
  function beginDetailEdit(key: NonNullable<typeof detailEdit>["key"]) {
    const config = gameRendering[selected.name] ?? inheritedRendering;
    setDetailEdit({
      game: selected.name,
      id: ++fontSerial.current,
      text: { ...(gameText[selected.name] ?? defaultGameText) },
      key,
      name: titleFor(selected),
      rendering: { ...config, customChain: [...config.customChain] },
    });
  }
  function updateDetailRendering(patch: Partial<GameRendering>) {
    setDetailEdit((edit) =>
      edit && edit.game === selected.name
        ? { ...edit, rendering: { ...edit.rendering, ...patch } }
        : edit,
    );
  }
  function saveDetailEdit() {
    if (!detailEdit || detailEdit.game !== selected.name) return;
    if (detailEdit.key === "name") {
      const name = detailEdit.name.trim();
      if (!name) return;
      setGameNames((names) => ({ ...names, [selected.name]: name }));
    } else if (
      detailEdit.key === "encoding" ||
      detailEdit.key === "font_file"
    ) {
      const edited = detailEdit;
      setGameText((values) => ({
        ...values,
        [selected.name]: {
          ...(values[selected.name] ?? defaultGameText),
          ...(edited.key === "encoding"
            ? { encoding: edited.text.encoding }
            : {
                fontName: edited.text.fontName,
                fontFamily: edited.text.fontFamily,
              }),
        },
      }));
    } else {
      const key = detailEdit.key;
      const config = detailEdit.rendering;
      const patch =
        key === "frame_enhancement_kind"
          ? {
              frame_enhancement_kind: config.frame_enhancement_kind,
              frame_enhancement_mode: config.frame_enhancement_mode,
              customChain: [...config.customChain],
            }
          : { [key]: config[key] };
      setGameRendering((values) => ({
        ...values,
        [selected.name]: {
          ...(values[selected.name] ?? inheritedRendering),
          ...patch,
        },
      }));
    }
    setDetailEdit(null);
  }
  function detailField(
    key: NonNullable<typeof detailEdit>["key"],
    label: string,
    value: string,
    editor: ReactNode,
    divider = true,
  ) {
    const expanded =
      detailEdit?.game === selected.name && detailEdit.key === key;
    return (
      <VStack gap={0}>
        <VStack gap={4} style={settingsRowPadding}>
          <HStack gap={4} hAlign="between" vAlign="start">
            <VStack gap={0}>
              <Text weight="semibold">{label}</Text>
              {!expanded && (
                <Text type="supporting" color="secondary">
                  {value}
                </Text>
              )}
            </VStack>
            {!expanded && (
              <Link
                href="#"
                aria-label={`编辑${label}`}
                onClick={(event) => {
                  event.preventDefault();
                  beginDetailEdit(key);
                }}
              >
                编辑
              </Link>
            )}
          </HStack>
          {expanded && (
            <>
              {editor}
              <HStack gap={2}>
                <Button
                  label="保存"
                  variant="primary"
                  size="lg"
                  isDisabled={key === "name" && !detailEdit.name.trim()}
                  onClick={saveDetailEdit}
                />
                <Button
                  label="取消"
                  variant="ghost"
                  size="lg"
                  onClick={() => setDetailEdit(null)}
                />
              </HStack>
            </>
          )}
        </VStack>
        {divider && <Divider />}
      </VStack>
    );
  }
  async function importGameFont(file?: File) {
    const current = detailEdit;
    if (!file || current?.key !== "font_file") return;
    if (
      !/\.(ttf|otf)$/i.test(file.name) ||
      file.size === 0 ||
      file.size > 32 * 1024 * 1024
    ) {
      setNotice("请选择有效的 TTF 或 OTF 字体（最大 32 MiB）。");
      return;
    }
    try {
      const family = `AetherPreviewFont${++fontSerial.current}`;
      const font = await new FontFace(family, await file.arrayBuffer()).load();
      document.fonts.add(font);
      previewFonts.current.push(font);
      setDetailEdit((edit) =>
        edit?.id === current.id && edit.key === "font_file"
          ? {
              ...edit,
              text: { ...edit.text, fontName: file.name, fontFamily: family },
            }
          : edit,
      );
    } catch {
      setNotice("无法读取这个字体文件。");
    }
  }
  function gameTextSettings() {
    if (!textEngines.includes(selected.runtime)) return null;
    const saved = gameText[selected.name] ?? defaultGameText;
    const draft = detailEdit?.game === selected.name ? detailEdit.text : saved;
    return (
      <VStack gap={0}>
        {selected.runtime === "EntisGLS" ? (
          <VStack gap={1} style={settingsRowPadding}>
            <Text weight="semibold">文本编码</Text>
            <Text type="supporting" color="secondary">
              引擎原生（无需转换）
            </Text>
            <Divider />
          </VStack>
        ) : (
          detailField(
            "encoding",
            "文本编码",
            saved.encoding || "自动（游戏默认）",
            <Selector
              label="文本编码"
              isLabelHidden
              size="lg"
              value={draft.encoding}
              options={textEncodings(selected.runtime).map((value) => ({
                value,
                label:
                  value === "CP932"
                    ? "CP932 / Shift-JIS"
                    : value || "自动（游戏默认）",
              }))}
              onChange={(encoding) =>
                setDetailEdit((edit) =>
                  edit ? { ...edit, text: { ...edit.text, encoding } } : edit,
                )
              }
            />,
          )
        )}
        {detailField(
          "font_file",
          "游戏字体",
          saved.fontName || "默认字体",
          <VStack gap={4}>
            <Text color="secondary">{draft.fontName || "默认字体"}</Text>
            <input
              ref={fontPicker}
              type="file"
              accept=".ttf,.otf"
              hidden
              onChange={(event) => {
                void importGameFont(event.currentTarget.files?.[0]);
                event.currentTarget.value = "";
              }}
            />
            <HStack gap={2}>
              <Button
                label="选择字体文件"
                size="lg"
                onClick={() => fontPicker.current?.click()}
              />
              <Button
                label="恢复默认"
                variant="ghost"
                size="lg"
                isDisabled={!draft.fontName}
                onClick={() =>
                  setDetailEdit((edit) =>
                    edit
                      ? {
                          ...edit,
                          text: { ...edit.text, fontName: "", fontFamily: "" },
                        }
                      : edit,
                  )
                }
              />
            </HStack>
            <span
              style={{
                fontFamily: draft.fontFamily || "inherit",
                fontSize: 18,
                lineHeight: 1.5,
              }}
            >
              你好，世界。物語の続きを。
              <br />
              The story continues. 0123456789
            </span>
            <Text type="supporting" color="secondary">
              下次启动游戏时生效。
            </Text>
          </VStack>,
          false,
        )}
      </VStack>
    );
  }
  function gameRenderSettings() {
    const savedConfig = gameRendering[selected.name] ?? inheritedRendering;
    const config =
      detailEdit?.game === selected.name ? detailEdit.rendering : savedConfig;
    const options = (key: keyof typeof renderChoices, inherit = true) => [
      ...(inherit ? [{ value: "", label: "跟随系统" }] : []),
      ...renderChoices[key].map(([value, label]) => ({ value, label })),
    ];
    const caption = (key: keyof typeof renderChoices) =>
      options(key).find((option) => option.value === savedConfig[key])?.label ??
      "跟随系统";
    const selector = (
      label: string,
      key: keyof typeof renderChoices,
      inherit = true,
    ) => (
      <Selector
        label={label}
        isLabelHidden
        size="lg"
        options={options(key, inherit)}
        value={config[key]}
        onChange={(value) => updateDetailRendering({ [key]: value })}
      />
    );
    const enhancementSummary =
      caption("frame_enhancement_kind") +
      (savedConfig.frame_enhancement_kind === "preset"
        ? ` · ${caption("frame_enhancement_mode")}`
        : savedConfig.frame_enhancement_kind === "custom"
          ? ` · ${savedConfig.customChain.length} 个步骤`
          : "");
    return (
      <VStack gap={0} style={detailSectionPadding}>
        <Text type="supporting" color="secondary">
          仅对这个游戏生效；跟随系统时使用全局设置。
        </Text>
        {detailField(
          "upscale_algorithm",
          "缩放算法",
          caption("upscale_algorithm"),
          selector("缩放算法", "upscale_algorithm"),
        )}
        {detailField(
          "output_resolution",
          "输出分辨率",
          caption("output_resolution"),
          selector("输出分辨率", "output_resolution"),
        )}
        {detailField(
          "frame_enhancement_kind",
          "画面增强",
          enhancementSummary,
          <VStack gap={4}>
            {selector("画面增强", "frame_enhancement_kind")}
            {config.frame_enhancement_kind === "preset" && (
              <VStack gap={2}>
                <Text weight="semibold">增强效果</Text>
                {selector("增强效果", "frame_enhancement_mode", false)}
              </VStack>
            )}
            {config.frame_enhancement_kind === "custom" &&
              customChain(
                config.customChain,
                (customChain) => updateDetailRendering({ customChain }),
                false,
              )}
          </VStack>,
          false,
        )}
      </VStack>
    );
  }
  function settings() {
    const menu = (
      <VStack
        gap={4}
        style={{
          paddingBlock: "var(--spacing-4)",
          paddingInline: "var(--spacing-3)",
        }}
      >
        <Heading level={2} style={{ marginInline: "var(--spacing-4)" }}>
          设置
        </Heading>
        {[groups.slice(0, -1), groups.slice(-1)].map((items, index) => (
          <VStack key={index} gap={4}>
            {index > 0 && <Divider />}
            <List density="spacious" style={{ gap: "var(--spacing-2)" }}>
              {items.map((g) => (
                <ListItem
                  key={g}
                  label={g}
                  startContent={<Icon icon={groupIcons[groups.indexOf(g)]} />}
                  endContent={
                    settingsNarrow ? (
                      <Icon
                        icon={ChevronRightIcon}
                        size="sm"
                        color="secondary"
                      />
                    ) : undefined
                  }
                  isSelected={!settingsNarrow && group === g}
                  onClick={() => {
                    setGroup(g);
                    setSettingsDetail(true);
                    setEditingSetting("");
                  }}
                />
              ))}
            </List>
          </VStack>
        ))}
      </VStack>
    );
    const footer = dirty ? (
      <LayoutFooter hasDivider padding={4}>
        <HStack gap={3} vAlign="center">
          <StackItem size="fill">
            <Text type="supporting" color="secondary">
              有未保存的更改
            </Text>
          </StackItem>
          <Button
            label="取消"
            onClick={() => {
              setDraft(saved);
              setEditingSetting("");
            }}
          />
          <Button label="保存更改" variant="primary" onClick={save} />
        </HStack>
      </LayoutFooter>
    ) : undefined;
    if (settingsNarrow && !settingsDetail) {
      return (
        <Layout
          height="fill"
          content={<LayoutContent padding={2}>{menu}</LayoutContent>}
          footer={footer}
        />
      );
    }
    return (
      <Layout
        height="fill"
        start={
          !settingsNarrow && (
            <LayoutPanel width={256} hasDivider padding={0}>
              {menu}
            </LayoutPanel>
          )
        }
        content={
          <Layout
            height="fill"
            footer={footer}
            content={
              <LayoutContent padding={4}>
                <VStack gap={4}>
                  {settingsNarrow ? (
                    <Toolbar
                      label={`返回设置 — ${group}`}
                      gap={2}
                      startContent={
                        <>
                          <Button
                            label="返回设置"
                            variant="ghost"
                            size="sm"
                            isIconOnly
                            icon={<Icon icon={ArrowLeftIcon} size="sm" />}
                            onClick={() => setSettingsDetail(false)}
                          />
                          <Heading level={2}>{group}</Heading>
                        </>
                      }
                    />
                  ) : (
                    <Heading level={2}>{group}</Heading>
                  )}
                  {group === "界面" && (
                    <>
                      <SettingSection
                        title="外观"
                        description="选择适合你的界面，让每一段故事都有舒适的开始。"
                      >
                        {settingRow(
                          "theme",
                          "主题",
                          draft.theme === "light" ? "Light" : "Dark",
                          <SegmentedControl
                            label="主题"
                            value={draft.theme}
                            onChange={(v) => change("theme", v as Mode)}
                          >
                            <SegmentedControlItem value="light" label="Light" />
                            <SegmentedControlItem value="dark" label="Dark" />
                          </SegmentedControl>,
                        )}
                        {selectField("界面语言", "language", [
                          "简体中文",
                          "繁體中文",
                          "English",
                          "日本語",
                          "한국어",
                        ])}
                        <HStack
                          gap={4}
                          hAlign="between"
                          vAlign="center"
                          style={settingsRowPadding}
                        >
                          <VStack gap={0}>
                            <Text weight="semibold">界面版本</Text>
                            <Text type="supporting" color="secondary">
                              Astryx
                            </Text>
                          </VStack>
                          <Link
                            href="#"
                            onClick={(event) => {
                              event.preventDefault();
                              setNotice(
                                "Godot 中会切回原有界面，并保留主题与资料库。",
                              );
                            }}
                          >
                            切换到经典界面
                          </Link>
                        </HStack>
                        <Divider />
                      </SettingSection>
                      <SettingSection
                        title="游戏控制"
                        description="按你的习惯调整游戏内的触控操作。"
                      >
                        {toggleField(
                          "虚拟控制菜单",
                          "keyboard",
                          "在游戏中显示快捷菜单与键盘入口。",
                        )}
                        {settingRow(
                          "opacity",
                          "虚拟键盘不透明度",
                          `${draft.opacity}%`,
                          <Slider
                            label="虚拟键盘不透明度"
                            value={draft.opacity}
                            min={20}
                            max={100}
                            step={5}
                            formatValue={(v: number) => `${v}%`}
                            onChange={(v: number) => change("opacity", v)}
                          />,
                        )}
                      </SettingSection>
                    </>
                  )}
                  {group === "画面" && (
                    <>
                      <SettingSection
                        title="画面与渲染"
                        description="调整渲染方式、图像缩放和输出分辨率。"
                      >
                        {selectField("渲染后端", "backend", [
                          "Godot Native",
                          "GPU Bridge",
                          "Debug CPU",
                        ])}
                        {selectField(
                          "缩放算法",
                          "upscale",
                          renderChoices.upscale_algorithm.map(
                            ([, label]) => label,
                          ),
                        )}
                        {selectField(
                          "输出分辨率",
                          "resolution",
                          renderChoices.output_resolution.map(
                            ([, label]) => label,
                          ),
                        )}
                        {selectField(
                          "画面增强",
                          "enhancement",
                          renderChoices.frame_enhancement_kind.map(
                            ([, label]) => label,
                          ),
                        )}
                        {draft.enhancement === "预设" &&
                          selectField(
                            "增强效果",
                            "preset",
                            renderChoices.frame_enhancement_mode.map(
                              ([, label]) => label,
                            ),
                          )}
                        {draft.enhancement === "自定义" && customChain()}
                      </SettingSection>
                      <SettingSection
                        title="帧率"
                        description="在流畅度和功耗之间找到适合你的设置。"
                      >
                        {toggleField("限制帧率", "fps")}
                        {draft.fps &&
                          selectField("帧率上限", "limit", [
                            "30",
                            "60",
                            "90",
                            "120",
                            "144",
                            "240",
                          ])}
                      </SettingSection>
                    </>
                  )}
                  {group === "兼容性" && (
                    <SettingSection
                      title="运行时兼容性"
                      description="为不同游戏选择合适的运行选项。"
                    >
                      {selectField("插件加载", "plugins", [
                        "核心插件",
                        "全部插件",
                      ])}
                      {toggleField(
                        "兼容性模拟",
                        "mock",
                        "为部分旧插件提供兼容实现。",
                      )}
                    </SettingSection>
                  )}
                  {group === "诊断" && (
                    <SettingSection
                      title="诊断与日志"
                      description="在遇到问题时保留必要的信息。"
                    >
                      {selectField("诊断方案", "diagnostic", [
                        "关闭",
                        "基线",
                        "输入",
                        "渲染",
                        "存储",
                        "脚本",
                        "音频",
                        "视频",
                        "插件",
                        "系统",
                        "完整",
                      ])}
                      {selectField("性能信息", "overlay", [
                        "关闭",
                        "摘要",
                        "详细",
                      ])}
                      {toggleField(
                        "错误日志",
                        "logs",
                        "保留错误详情，帮助定位问题。",
                      )}
                    </SettingSection>
                  )}
                  {group === "关于" && (
                    <>
                      <SettingSection
                        title="Aether"
                        description="让故事，再次抵达你。"
                      >
                        {aboutRow(
                          "版本",
                          "当前安装的应用版本",
                          <Text color="secondary">1.1.1</Text>,
                        )}
                        {aboutAction(
                          "隐私与免责协议",
                          "查看当前版本的隐私政策、使用规则、风险提示与免责声明",
                          "阅读协议",
                          "此处预览协议入口，应用中会打开完整协议。",
                        )}
                        {aboutAction(
                          "Apple App Store 额外声明",
                          "查看 GPLv3、App Store 分发附加许可、源码义务及适用范围",
                          "阅读声明",
                          "此处预览声明入口，应用中会打开完整声明。",
                        )}
                        {aboutAction(
                          "检查更新",
                          "检测最新版本与功能改进",
                          "检查",
                          "这是本地交互原型，应用中会检查可用更新。",
                        )}
                        {toggleField(
                          "接收测试版更新",
                          "prerelease",
                          "开启后将检测包括 Alpha / Beta 在内的预发布测试版本",
                        )}
                      </SettingSection>
                      <SettingSection title="社区与支持" description="">
                        {aboutAction(
                          "加入 QQ 交流群",
                          "反馈问题、获取更新、与其他玩家交流",
                          "前往",
                          "此处预览社区入口，应用中会打开 QQ 交流群。",
                        )}
                      </SettingSection>
                    </>
                  )}
                </VStack>
              </LayoutContent>
            }
          />
        }
      />
    );
  }

  function library() {
    const shown = games.filter(
      (g) =>
        !removedGames.includes(g.name) &&
        titleFor(g).toLowerCase().includes(query.toLowerCase()) &&
        (filter !== "recent" || g.lastPlayed > 0),
    );
    if (filter === "recent") shown.sort((a, b) => b.lastPlayed - a.lastPlayed);
    return (
      <Layout
        height="fill"
        header={
          <LayoutHeader hasDivider>
            <HStack gap={3} vAlign="center">
              <StackItem size="fill">
                <Heading level={1}>游戏库</Heading>
              </StackItem>
              <SegmentedControl
                label="展示方式"
                value={libraryDisplay}
                onChange={changeLibraryDisplay}
                size="lg"
                style={{ height: 44, padding: 0 }}
              >
                <SegmentedControlItem
                  value="cards"
                  label="卡片"
                  isLabelHidden={phone}
                  style={{ height: 44 }}
                  icon={<Icon icon={Squares2X2Icon} />}
                />
                <SegmentedControlItem
                  value="list"
                  label="列表"
                  isLabelHidden={phone}
                  style={{ height: 44 }}
                  icon={<Icon icon={ListBulletIcon} />}
                />
              </SegmentedControl>
              <Button
                label="导入"
                variant="primary"
                size="lg"
                style={{ height: 44 }}
                icon={<Icon icon={PlusIcon} />}
                onClick={() =>
                  setNotice("Godot 中会打开系统文件选择器，导入本地游戏。")
                }
              />
            </HStack>
          </LayoutHeader>
        }
        content={
          <LayoutContent padding={phone ? 5 : 6}>
            <VStack gap={6}>
              <TextInput
                label="搜索游戏"
                isLabelHidden
                placeholder="搜索游戏…"
                startIcon={MagnifyingGlassIcon}
                value={query}
                onChange={setQuery}
              />
              <HStack gap={4} vAlign="center">
                <StackItem size="fill">
                  <TabList value={filter} onChange={setFilter}>
                    <Tab value="all" label="全部游戏" />
                    <Tab value="recent" label="最近游玩" />
                  </TabList>
                </StackItem>
                <Text type="supporting" color="secondary">
                  {shown.length} 部游戏
                </Text>
              </HStack>
              {filter === "recent" && shown.length === 0 && !query ? (
                <Text color="secondary">开始一个游戏后，会在这里找到它。</Text>
              ) : shown.length === 0 ? (
                <Text color="secondary">没有找到相关游戏。</Text>
              ) : libraryDisplay === "list" ? (
                <List density="balanced">
                  {shown.map((g) => (
                    <ListItem
                      key={g.name}
                      label={
                        <Text weight="semibold" maxLines={2}>
                          {titleFor(g)}
                        </Text>
                      }
                      description={gameHistory(g)}
                      startContent={
                        coversFor(g).length > 0 ? (
                          <img
                            className="library-thumbnail"
                            src={coversFor(g)[0]}
                            alt=""
                          />
                        ) : (
                          coverPlaceholder(true)
                        )
                      }
                      endContent={<Icon icon={ChevronRightIcon} size="sm" />}
                      onClick={() => openGame(g)}
                    />
                  ))}
                </List>
              ) : (
                <Grid columns={phone ? 2 : 3} gap={phone ? 4 : 6}>
                  {shown.map((g) => (
                    <ClickableCard
                      key={g.name}
                      label={titleFor(g)}
                      variant="transparent"
                      padding={0}
                      onClick={() => openGame(g)}
                    >
                      <VStack gap={3}>
                        <AspectRatio ratio={phone ? 3 / 4 : 4 / 3}>
                          {coversFor(g).length > 0 ? (
                            <img
                              className="poster"
                              src={coversFor(g)[0]}
                              alt={titleFor(g)}
                            />
                          ) : (
                            coverPlaceholder()
                          )}
                        </AspectRatio>
                        <VStack gap={1}>
                          <Heading level={3}>{titleFor(g)}</Heading>
                          {gameHistory(g)}
                        </VStack>
                      </VStack>
                    </ClickableCard>
                  ))}
                </Grid>
              )}
            </VStack>
          </LayoutContent>
        }
      />
    );
  }

  function detail() {
    const covers = coversFor(selected);
    const coverSource = covers[thumb] ?? covers[0];
    const coverRatio = coverRatios[coverSource] ?? 4 / 5;
    return (
      <Layout
        height="fill"
        className="detail-page"
        style={
          {
            "--detail-backdrop": coverSource
              ? `url(${JSON.stringify(coverSource)})`
              : "none",
            "--detail-backdrop-opacity": draft.theme === "dark" ? 0.55 : 0.35,
            "--detail-backdrop-brightness": draft.theme === "dark" ? 0.55 : 1,
          } as CSSProperties
        }
        header={
          <LayoutHeader hasDivider>
            <Button
              label="游戏库"
              aria-label="返回游戏库"
              variant="ghost"
              size="lg"
              icon={<Icon icon={ArrowLeftIcon} />}
              onClick={() => go("library")}
            />
          </LayoutHeader>
        }
        content={
          <LayoutContent padding={6}>
            <Grid columns={{ minWidth: 320, repeat: "fit" }} gap={5}>
              <VStack
                gap={3}
                className="detail-gallery"
                style={{ "--detail-cover-ratio": coverRatio } as CSSProperties}
              >
                <AspectRatio ratio={coverRatio} fit="contain">
                  {coverSource ? (
                    <img
                      className="detail-poster"
                      src={coverSource}
                      alt={titleFor(selected)}
                      onLoad={({ currentTarget }) => {
                        const ratio =
                          currentTarget.naturalWidth /
                          currentTarget.naturalHeight;
                        if (Number.isFinite(ratio) && ratio > 0) {
                          setCoverRatios((ratios) => ({
                            ...ratios,
                            [coverSource]: ratio,
                          }));
                        }
                      }}
                    />
                  ) : (
                    coverPlaceholder()
                  )}
                </AspectRatio>
                {covers.length > 1 && (
                  <Grid columns={3} gap={2}>
                    {covers.map((image, i) => (
                      <AspectRatio key={image} ratio={1}>
                        <SelectableCard
                          label={`游戏图片 ${i + 1}`}
                          isSelected={thumb === i}
                          onChange={() => setThumb(i)}
                          variant="transparent"
                          padding={0}
                          width="100%"
                          height="100%"
                        >
                          <img
                            className="poster"
                            src={image}
                            alt={`游戏图片 ${i + 1}`}
                          />
                        </SelectableCard>
                      </AspectRatio>
                    ))}
                  </Grid>
                )}
              </VStack>
              <VStack gap={5} className="detail-info">
                <VStack gap={2}>
                  <Text type="display-2" as="h1">
                    {titleFor(selected)}
                  </Text>
                </VStack>
                <Text type="large">
                  让故事，再次抵达你。在这里继续你的旅程，或为下一次相遇准备好一切。
                </Text>
                <VStack gap={2}>
                  <Text type="label">运行时</Text>
                  <Text>{selected.runtime}</Text>
                </VStack>
                <VStack gap={2}>
                  <Text type="label">游玩记录</Text>
                  {gameHistory(selected)}
                </VStack>
                <VStack gap={2}>
                  <Button
                    label="开始游戏"
                    variant="primary"
                    size="lg"
                    icon={<Icon icon={PlayIcon} />}
                    onClick={() =>
                      setNotice("Godot 中会通过游戏原有运行时启动。")
                    }
                  />
                </VStack>
                <CollapsibleGroup
                  type="multiple"
                  defaultValue={["information"]}
                  onChange={(values) => {
                    const open = Array.isArray(values) ? values : [values];
                    if (
                      detailEdit &&
                      !open.includes(
                        ["name", "encoding", "font_file"].includes(
                          detailEdit.key,
                        )
                          ? "information"
                          : "rendering",
                      )
                    )
                      setDetailEdit(null);
                  }}
                >
                  <Divider />
                  <Collapsible
                    value="information"
                    trigger={<Heading level={3}>游戏信息</Heading>}
                  >
                    <VStack gap={3} style={detailSectionPadding}>
                      {detailField(
                        "name",
                        "游戏名字",
                        titleFor(selected),
                        <TextInput
                          label="游戏名字"
                          isLabelHidden
                          size="lg"
                          hasAutoFocus
                          value={detailEdit?.name ?? titleFor(selected)}
                          onChange={(name) =>
                            setDetailEdit((edit) =>
                              edit ? { ...edit, name } : edit,
                            )
                          }
                          onEnter={saveDetailEdit}
                        />,
                        false,
                      )}
                      {gameTextSettings()}
                      <HStack gap={4} vAlign="center">
                        <StackItem size="fill">
                          <VStack gap={1}>
                            <Text weight="semibold">启动文件</Text>
                            <Text color="secondary">
                              {selected.runtime === "ONScripter Yuri"
                                ? "0.txt"
                                : selected.runtime === "YU-RIS"
                                  ? "system/yst00001.ybn"
                                  : selected.runtime === "EntisGLS"
                                    ? "adventure.csx"
                                    : "data.xp3"}
                            </Text>
                          </VStack>
                        </StackItem>
                        <StackItem size="static">
                          <Link
                            href="#"
                            aria-label="设置启动文件"
                            onClick={(event) => {
                              event.preventDefault();
                              setNotice("Godot 中会打开启动文件选择器。");
                            }}
                          >
                            设置
                          </Link>
                        </StackItem>
                      </HStack>
                      <Text color="secondary">本地游戏 / {selected.name}</Text>
                      <Button
                        label="删除游戏"
                        variant="destructive"
                        width="100%"
                        size="lg"
                        onClick={() => setRemovingGame(true)}
                      />
                    </VStack>
                  </Collapsible>
                  <Divider />
                  <Collapsible
                    value="rendering"
                    trigger={<Heading level={3}>画面与渲染</Heading>}
                  >
                    {gameRenderSettings()}
                  </Collapsible>
                  <Divider />
                  <Collapsible
                    value="cover"
                    trigger={<Heading level={3}>封面</Heading>}
                  >
                    <VStack gap={3} style={detailSectionPadding}>
                      <Text type="supporting" color="secondary" maxLines={1}>
                        {covers.length ? coverFiles[selected.name] || covers[0] : "未设置封面"}
                      </Text>
                      <Button
                        label="设置封面"
                        variant="primary"
                        width="100%"
                        size="lg"
                        onClick={chooseCover}
                      />
                      {covers.length > 0 && (
                        <Button
                          label="清除封面"
                          variant="destructive"
                          width="100%"
                          size="lg"
                          onClick={clearCover}
                        />
                      )}
                    </VStack>
                  </Collapsible>
                  <Divider />
                </CollapsibleGroup>
              </VStack>
            </Grid>
          </LayoutContent>
        }
      />
    );
  }

  function media() {
    const title = route === "flash" ? "Flash" : "视频";
    const base = route === "flash" ? flashFiles : videoFiles;
    const current = folders.at(-1)?.children ?? base;
    function flatten(entries: MediaEntry[]): MediaEntry[] {
      return entries
        .filter((e) => !removedMedia.includes(e.id))
        .flatMap((e) => [e, ...flatten(e.children || [])]);
    }
    const shown = (query ? flatten(current) : current).filter(
      (e) =>
        !removedMedia.includes(e.id) &&
        e.name.toLowerCase().includes(query.toLowerCase()),
    );
    function openEntry(entry: MediaEntry) {
      if (entry.kind === "folder") {
        setFolders(findFolderPath(base, entry.id) ?? [...folders, entry]);
        setQuery("");
      } else {
        setVideo(entry);
        setPlaying(false);
        setPosition(0);
      }
    }
    function entryDescription(entry: MediaEntry) {
      if (entry.kind !== "folder") return entry.description;
      const visible = (entry.children ?? []).filter(
        (child) => !removedMedia.includes(child.id),
      );
      if (visible.length === 0) return "空文件夹";
      const folderCount = visible.filter(
        (child) => child.kind === "folder",
      ).length;
      return `${folderCount} 个文件夹 · ${visible.length - folderCount} 个文件`;
    }
    return (
      <Layout
        height="fill"
        header={
          <LayoutHeader hasDivider>
            <HStack gap={3} vAlign="center">
              <StackItem size="fill">
                <Heading level={1}>{title}</Heading>
              </StackItem>
              <Button
                label="导入"
                variant="primary"
                icon={<Icon icon={PlusIcon} />}
                onClick={() => setNotice("Godot 中可以选择文件或文件夹。")}
              />
            </HStack>
          </LayoutHeader>
        }
        content={
          <LayoutContent padding={phone ? 5 : 6}>
            <VStack gap={5}>
              <TextInput
                label="搜索文件"
                isLabelHidden
                placeholder="搜索文件…"
                startIcon={MagnifyingGlassIcon}
                value={query}
                onChange={setQuery}
              />
              {folders.length > 0 && (
                <Breadcrumbs label="文件夹路径">
                  <BreadcrumbItem
                    onClick={() => {
                      setFolders([]);
                      setQuery("");
                    }}
                  >
                    {title}
                  </BreadcrumbItem>
                  {folders.map((f, i) => (
                    <BreadcrumbItem
                      key={f.id}
                      isCurrent={i === folders.length - 1}
                      onClick={() => {
                        setFolders(folders.slice(0, i + 1));
                        setQuery("");
                      }}
                    >
                      {f.name}
                    </BreadcrumbItem>
                  ))}
                </Breadcrumbs>
              )}
              <Text type="supporting" color="secondary">
                {shown.filter((e) => e.kind === "folder").length} 个文件夹 ·{" "}
                {shown.filter((e) => e.kind !== "folder").length} 个文件
              </Text>
              <List density="balanced">
                {shown.map((entry) => (
                  <ListItem
                    key={entry.id}
                    label={entry.name}
                    description={entryDescription(entry)}
                    startContent={
                      <Icon
                        icon={
                          entry.kind === "folder"
                            ? FolderIcon
                            : entry.kind === "flash"
                              ? BoltIcon
                              : FilmIcon
                        }
                        size="lg"
                      />
                    }
                    endContent={
                      <HStack gap={1} vAlign="center">
                        <IconButton
                          label={`${entry.kind === "folder" ? "打开文件夹" : "播放"} ${entry.name}`}
                          icon={
                            <Icon
                              icon={
                                entry.kind === "folder"
                                  ? ChevronRightIcon
                                  : PlayIcon
                              }
                            />
                          }
                          variant="ghost"
                          size="lg"
                          width={44}
                          style={{ height: 44 }}
                          onClick={() => openEntry(entry)}
                        />
                        {(entry.kind !== "folder" || folders.length === 0) && (
                          <IconButton
                            label={`删除 ${entry.name}`}
                            icon={<Icon icon={TrashIcon} />}
                            variant="ghost"
                            size="lg"
                            width={44}
                            style={{ height: 44 }}
                            onClick={() => setPendingMediaRemoval(entry)}
                          />
                        )}
                      </HStack>
                    }
                    onClick={() => openEntry(entry)}
                  />
                ))}
              </List>
              {shown.length === 0 && (
                <VStack gap={2}>
                  <Heading level={3}>
                    {query ? "没有找到相关文件" : "文件夹是空的"}
                  </Heading>
                  <Text color="secondary">
                    {query
                      ? "试试其他关键词。"
                      : "返回上级，继续浏览你的收藏。"}
                  </Text>
                </VStack>
              )}
            </VStack>
          </LayoutContent>
        }
      />
    );
  }

  return (
    <Theme theme={neutralTheme} mode={draft.theme}>
      <ToastViewport
        position="bottomEnd"
        maxVisible={1}
        inset={{ bottom: bottomNavHeight }}
      >
        <SaveFeedback feedback={saveFeedback} />
        <AppShell
          variant={phone ? "surface" : "elevated"}
          mobileNav={false}
          sideNav={
            !phone && (
              <SideNav
                aria-label="主导航"
                header={
                  <SideNavHeading
                    heading="Aether"
                    icon={
                      <IconButton
                        label={navCollapsed ? "展开侧栏" : "收起侧栏"}
                        aria-expanded={!navCollapsed}
                        variant="ghost"
                        width={32}
                        style={{ height: 32, outlineColor: "currentColor" }}
                        icon={
                          <img src={appIcon} alt="" width={32} height={32} />
                        }
                        onClick={() => setNavCollapsed((value) => !value)}
                      />
                    }
                  />
                }
                collapsible={{
                  isCollapsed: navCollapsed,
                  onCollapsedChange: setNavCollapsed,
                  hasButton: false,
                }}
              >
                {navigation.map(([id, label, icon]) => (
                  <SideNavItem
                    key={id}
                    label={label}
                    icon={icon}
                    isSelected={
                      route === id || (id === "library" && route === "detail")
                    }
                    onClick={() => navigate(id)}
                  />
                ))}
              </SideNav>
            )
          }
        >
          <Layout
            height="fill"
            padding={0}
            content={
              route === "settings"
                ? settings()
                : route === "detail"
                  ? detail()
                  : route === "library"
                    ? library()
                    : media()
            }
            footer={
              phone && (
                <LayoutFooter
                  ref={setBottomNav}
                  hasDivider
                  padding={2}
                  className="device-bottom"
                >
                  <nav aria-label="主导航">
                    <HStack gap={0} vAlign="center">
                      {navigation.map(([id, label, icon]) => {
                        const selected =
                          route === id ||
                          (id === "library" && route === "detail");
                        return (
                          <StackItem key={id} size="fill">
                            <HStack hAlign="center">
                              <IconButton
                                label={label}
                                variant="ghost"
                                size="lg"
                                width={44}
                                style={{ height: 44 }}
                                aria-current={selected ? "page" : undefined}
                                icon={
                                  <Icon
                                    icon={
                                      selected
                                        ? selectedNavigationIcons[
                                            id as keyof typeof selectedNavigationIcons
                                          ]
                                        : icon
                                    }
                                    size="lg"
                                  />
                                }
                                onClick={() => navigate(id)}
                              />
                            </HStack>
                          </StackItem>
                        );
                      })}
                    </HStack>
                  </nav>
                </LayoutFooter>
              )
            }
          />
          <Dialog
            isOpen={pending !== null}
            onOpenChange={(open) => !open && setPending(null)}
            width={460}
            purpose="form"
          >
            <Layout
              height="auto"
              header={
                <DialogHeader
                  title="保存更改？"
                  onOpenChange={() => setPending(null)}
                />
              }
              content={
                <LayoutContent>
                  <Text>
                    你的设置尚未保存。离开前可以保存，也可以放弃这次修改。
                  </Text>
                </LayoutContent>
              }
              footer={
                <LayoutFooter>
                  <HStack gap={2} hAlign="end" wrap="wrap">
                    <Button
                      label="继续编辑"
                      variant="ghost"
                      onClick={() => setPending(null)}
                    />
                    <Button
                      label="放弃更改"
                      onClick={() => {
                        setDraft(saved);
                        go(pending!);
                        setPending(null);
                      }}
                    />
                    <Button
                      label="保存并离开"
                      variant="primary"
                      onClick={() => {
                        save();
                        go(pending!);
                        setPending(null);
                      }}
                    />
                  </HStack>
                </LayoutFooter>
              }
            />
          </Dialog>
          <Dialog
            isOpen={pendingMediaRemoval !== null}
            onOpenChange={(open) => !open && setPendingMediaRemoval(null)}
            width={440}
          >
            <Layout
              height="auto"
              header={
                <DialogHeader
                  title="从列表移除"
                  onOpenChange={() => setPendingMediaRemoval(null)}
                />
              }
              content={
                <LayoutContent>
                  <Text>
                    将「{pendingMediaRemoval?.name}」从列表移除，原文件会保留。
                  </Text>
                </LayoutContent>
              }
              footer={
                <LayoutFooter>
                  <HStack gap={3} hAlign="end">
                    <Button
                      label="取消"
                      variant="secondary"
                      onClick={() => setPendingMediaRemoval(null)}
                    />
                    <Button
                      label="移除"
                      variant="destructive"
                      onClick={() => {
                        if (pendingMediaRemoval)
                          setRemovedMedia((ids) => [
                            ...ids,
                            pendingMediaRemoval.id,
                          ]);
                        setPendingMediaRemoval(null);
                      }}
                    />
                  </HStack>
                </LayoutFooter>
              }
            />
          </Dialog>
          <Dialog
            isOpen={!!notice}
            onOpenChange={(open) => !open && setNotice("")}
            width={440}
          >
            <Layout
              height="auto"
              header={
                <DialogHeader
                  title="交互预览"
                  onOpenChange={() => setNotice("")}
                />
              }
              content={
                <LayoutContent>
                  <Text>{notice}</Text>
                </LayoutContent>
              }
              footer={
                <LayoutFooter>
                  <HStack hAlign="end">
                    <Button
                      label="知道了"
                      variant="primary"
                      onClick={() => setNotice("")}
                    />
                  </HStack>
                </LayoutFooter>
              }
            />
          </Dialog>
          <input
            ref={coverFileInput}
            type="file"
            accept="image/*"
            hidden
            onChange={(event) => {
              importCoverFile(event.target.files?.[0]);
              event.target.value = "";
            }}
          />
          <Dialog
            isOpen={coverSources}
            onOpenChange={setCoverSources}
            width={460}
          >
            <Layout
              height="auto"
              header={
                <DialogHeader
                  title="选择封面来源"
                  onOpenChange={setCoverSources}
                />
              }
              content={
                <LayoutContent>
                  <VStack gap={3}>
                    <Button
                      label="本地搜索"
                      endContent={<ChevronRightIcon width={20} />}
                      size="lg"
                      width="100%"
                      style={{ minHeight: 56, justifyContent: "space-between" }}
                      onClick={browseCoverFile}
                    >
                      <span style={{ display: "inline-flex", alignItems: "center", gap: 12 }}>
                        <Icon icon={FolderIcon} />本地搜索
                      </span>
                    </Button>
                    <Button
                      label="VNDB 搜索"
                      endContent={<ChevronRightIcon width={20} />}
                      size="lg"
                      width="100%"
                      style={{ minHeight: 56, justifyContent: "space-between" }}
                      onClick={openCoverSearch}
                    >
                      <span style={{ display: "inline-flex", alignItems: "center", gap: 12 }}>
                        <Icon icon={MagnifyingGlassIcon} />VNDB 搜索
                      </span>
                    </Button>
                    {canBrowsePhotos && (
                      <Button
                        label="相册搜索"
                        endContent={<ChevronRightIcon width={20} />}
                        size="lg"
                        width="100%"
                        style={{ minHeight: 56, justifyContent: "space-between" }}
                        onClick={browseCoverFile}
                      >
                        <span style={{ display: "inline-flex", alignItems: "center", gap: 12 }}>
                          <Icon icon={PhotoIcon} />相册搜索
                        </span>
                      </Button>
                    )}
                  </VStack>
                </LayoutContent>
              }
            />
          </Dialog>
          <Dialog
            isOpen={coverPicker}
            onOpenChange={setCoverPicker}
            width={600}
          >
            <Layout
              height="auto"
              header={
                <DialogHeader
                  title="VNDB 搜索"
                  onOpenChange={setCoverPicker}
                  startContent={
                    <IconButton
                      label="返回封面来源"
                      icon={<Icon icon={ArrowLeftIcon} />}
                      variant="ghost"
                      size="lg"
                      width={44}
                      style={{ height: 44 }}
                      onClick={() => {
                        setCoverPicker(false);
                        setCoverSources(true);
                      }}
                    />
                  }
                />
              }
              content={
                <LayoutContent>
                  <VStack gap={4}>
                    <HStack gap={3} vAlign="center">
                      <StackItem size="fill">
                        <TextInput
                          label="游戏名称"
                          isLabelHidden
                          placeholder="输入游戏名称"
                          size="lg"
                          value={coverQuery}
                          onChange={setCoverQuery}
                          onEnter={searchCovers}
                        />
                      </StackItem>
                      <Button
                        label="搜索"
                        variant="primary"
                        size="lg"
                        isDisabled={coverSearching || !coverQuery.trim()}
                        onClick={searchCovers}
                      />
                    </HStack>
                    {coverStatus && <Text color="secondary">{coverStatus}</Text>}
                    <VStack
                      gap={3}
                      style={{
                        minHeight: "min(45vh, 360px)",
                        maxHeight: "min(55vh, 460px)",
                        overflowY: "auto",
                      }}
                    >
                      {coverResults.map((result) => (
                        <ClickableCard
                          key={result.id}
                          padding={3}
                          label={`使用 ${result.title} 的封面`}
                          isDisabled={coverSearching}
                          onClick={() => selectVndbCover(result)}
                        >
                          <HStack gap={3} vAlign="center">
                            <img
                              src={result.thumbnail}
                              alt=""
                              style={{
                                width: 60,
                                height: 84,
                                objectFit: "contain",
                              }}
                            />
                            <StackItem size="fill">
                              <Text weight="semibold" maxLines={3}>
                                {result.title}
                              </Text>
                            </StackItem>
                            <ChevronRightIcon width={20} />
                          </HStack>
                        </ClickableCard>
                      ))}
                    </VStack>
                  </VStack>
                </LayoutContent>
              }
            />
          </Dialog>
          <Dialog
            isOpen={removingGame}
            onOpenChange={setRemovingGame}
            width={420}
          >
            <Layout
              height="auto"
              header={
                <DialogHeader title="删除游戏" onOpenChange={setRemovingGame} />
              }
              content={
                <LayoutContent>
                  <Text>
                    确定删除“{titleFor(selected)}”吗？预览中仅移除示例条目。
                  </Text>
                </LayoutContent>
              }
              footer={
                <LayoutFooter>
                  <HStack gap={3} hAlign="end">
                    <Button
                      label="取消"
                      size="lg"
                      onClick={() => setRemovingGame(false)}
                    />
                    <Button
                      label="删除"
                      variant="destructive"
                      size="lg"
                      onClick={() => {
                        setRemovedGames((current) => [
                          ...current,
                          selected.name,
                        ]);
                        setRemovingGame(false);
                        go("library");
                      }}
                    />
                  </HStack>
                </LayoutFooter>
              }
            />
          </Dialog>
          <Dialog
            isOpen={video !== null}
            onOpenChange={(open) => !open && setVideo(null)}
            width={720}
          >
            <Layout
              height="auto"
              header={
                <DialogHeader
                  title={video?.name || "视频"}
                  onOpenChange={() => setVideo(null)}
                />
              }
              content={
                <LayoutContent>
                  <VStack gap={4}>
                    <AspectRatio ratio={16 / 9}>
                      <div className="player-preview">
                        <Text style={{ color: "white" }}>
                          {playing ? "播放控件预览" : "已暂停"}
                        </Text>
                      </div>
                    </AspectRatio>
                    <Slider
                      label="播放进度"
                      value={position}
                      min={0}
                      max={100}
                      onChange={setPosition}
                    />
                    <HStack gap={3} vAlign="center">
                      <Button
                        label={playing ? "暂停" : "播放"}
                        icon={<Icon icon={playing ? PauseIcon : PlayIcon} />}
                        onClick={() => setPlaying(!playing)}
                      />
                      <Text color="secondary">{video?.description}</Text>
                    </HStack>
                  </VStack>
                </LayoutContent>
              }
            />
          </Dialog>
        </AppShell>
      </ToastViewport>
    </Theme>
  );
}
