// Browser fixtures for AetherUnzip's single-archive extraction plan.
export const gamesFolder = "游戏目录";
const archiveFolder = "下载/游戏归档";

export type ArchiveEntry = {
  name: string;
  format: string;
  size: string;
  files: string[];
  origin?: string;
  encrypted?: boolean;
  incomplete?: boolean;
};

export const samples: ArchiveEntry[] = [
  {
    name: "月光手札.zip",
    format: "ZIP",
    size: "248 MiB",
    origin: archiveFolder,
    files: ["Moonlight/data.xp3", "Moonlight/start.exe"],
  },
  {
    name: "海边的来信.7z",
    format: "7z",
    size: "86 MiB",
    encrypted: true,
    files: ["start.exe", "data/scenario.dat"],
  },
  {
    name: "旅途.part1.rar",
    format: "RAR",
    size: "64 MiB",
    origin: gamesFolder,
    incomplete: true,
    files: [],
  },
];

export type LayoutMode = "smart" | "direct" | "separateFolder" | "stripTopLevel";
export type Conflict = "keepBoth" | "skip" | "fail" | "replace";
export type Plan = { destination: string; layout: LayoutMode; conflict: Conflict };
export const defaultPlan: Plan = { destination: gamesFolder, layout: "smart", conflict: "keepBoth" };
export const layoutChoices: { value: LayoutMode; label: string }[] = [
  { value: "smart", label: "智能解压" },
  { value: "direct", label: "直接解压" },
  { value: "separateFolder", label: "解压到独立文件夹" },
  { value: "stripTopLevel", label: "去除顶层目录" },
];
export const conflictChoices: { value: Conflict; label: string }[] = [
  { value: "keepBoth", label: "保留两者" },
  { value: "skip", label: "跳过" },
  { value: "fail", label: "停止" },
  { value: "replace", label: "替换" },
];
export const sampleOutputs = [gamesFolder + "/Moonlight/data.xp3", gamesFolder + "/start.exe"];

export function sharedRoot(entry: ArchiveEntry) {
  const first = entry.files[0]?.split("/")[0];
  return first && entry.files.every((file) => file.startsWith(first + "/")) ? first : undefined;
}

export function breadcrumb(path: string) {
  return path.replaceAll("/", " / ").trim();
}
export function normalizeFolder(path: string) {
  const trimmed = path.trim();
  const parts = trimmed.split("/").filter(Boolean);
  return (trimmed.startsWith("/") ? "/" : "") + parts.join("/");
}
function join(folder: string, child: string) {
  return folder.endsWith("/") ? folder + child : folder + "/" + child;
}

// Folder names get a suffix under every conflict policy. File suffixes go before the extension.
function availablePath(path: string, existing: Set<string>, isFolder: boolean) {
  const slash = path.lastIndexOf("/");
  const dot = path.lastIndexOf(".");
  const end = !isFolder && dot > slash + 1 ? dot : path.length;
  let candidate = path;
  let n = 2;
  while (existing.has(candidate)) {
    candidate = path.slice(0, end) + " (" + n++ + ")" + path.slice(end);
  }
  return candidate;
}

export function previewPlan(entry: ArchiveEntry, plan: Plan, files: string[]) {
  const occupied = new Set(files);
  for (const file of files) {
    for (let i = file.indexOf("/", 1); i >= 0; i = file.indexOf("/", i + 1)) {
      occupied.add(file.slice(0, i));
    }
  }
  const root = sharedRoot(entry);
  const basename = entry.name.replace(/\.[^.]+$/, "");
  let folderName: string | undefined;
  let strip: string | undefined;
  let placement: string;
  switch (plan.layout) {
    case "smart":
      folderName = root ?? (entry.files.length > 1 ? basename : undefined);
      strip = root;
      placement = root
        ? "保留顶层目录“" + root + "”。"
        : folderName
          ? "将分散的内容收进“" + folderName + "”文件夹。"
          : "单个文件直接放入目标目录。";
      break;
    case "separateFolder":
      folderName = basename;
      placement = "创建与归档同名的文件夹，并保留原有目录结构。";
      break;
    case "stripTopLevel":
      strip = root;
      placement = "去除顶层目录“" + root + "”，将其中的内容直接解压到目标目录。";
      break;
    case "direct":
      placement = "直接解压到目标目录，并保留原有目录结构。";
      break;
  }
  const desired = folderName ? join(plan.destination, folderName) : plan.destination;
  const directory = folderName ? availablePath(desired, occupied, true) : desired;
  const output = plan.layout === "direct" && root ? join(directory, root) : directory;
  if (directory !== desired) placement += " 同名文件夹已存在，将使用带编号的新文件夹。";

  const writes: string[] = [];
  let conflicts = 0;
  let firstConflict = "";
  let firstRenamed = "";
  for (const file of entry.files) {
    const relative = strip ? file.slice(strip.length + 1) : file;
    let path = join(directory, relative);
    if (occupied.has(path)) {
      conflicts++;
      firstConflict ||= relative;
      if (plan.conflict === "fail") break;
      if (plan.conflict === "skip") continue;
      if (plan.conflict === "keepBoth") {
        path = availablePath(path, occupied, false);
        firstRenamed ||= path.slice(path.lastIndexOf("/") + 1);
      }
    }
    occupied.add(path);
    writes.push(path);
  }
  let notice = "";
  if (plan.conflict === "replace") {
    notice = conflicts ? "将覆盖已有的“" + firstConflict + "”。" : "解压时，已有的同名文件将被覆盖。";
  } else if (conflicts) {
    if (plan.conflict === "keepBoth") notice = "保留已有文件，新文件将命名为“" + firstRenamed + "”。";
    if (plan.conflict === "skip") notice = "将跳过已有的“" + firstConflict + "”。";
    if (plan.conflict === "fail") notice = "遇到已有的“" + firstConflict + "”时停止解压。";
  }
  return { output, placement, notice, writes, conflicts, firstConflict };
}
