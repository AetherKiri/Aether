import { useEffect, useRef, useState } from "react";
import { Dialog, DialogHeader } from "@astryxdesign/core/Dialog";
import { Button } from "@astryxdesign/core/Button";
import { Divider } from "@astryxdesign/core/Divider";
import { Icon } from "@astryxdesign/core/Icon";
import { HStack, Layout, LayoutContent, LayoutFooter, StackItem, VStack } from "@astryxdesign/core/Layout";
import { List, ListItem } from "@astryxdesign/core/List";
import { ProgressBar } from "@astryxdesign/core/ProgressBar";
import { Selector } from "@astryxdesign/core/Selector";
import { Text } from "@astryxdesign/core/Text";
import { TextInput } from "@astryxdesign/core/TextInput";
import {
  ArchiveBoxIcon,
  ChevronRightIcon,
  ExclamationTriangleIcon,
  FolderIcon,
} from "@heroicons/react/24/outline";
import {
  breadcrumb,
  conflictChoices,
  defaultPlan,
  gamesFolder,
  layoutChoices,
  normalizeFolder,
  previewPlan,
  sampleOutputs,
  samples,
  sharedRoot,
  type ArchiveEntry,
  type Plan,
} from "./archivePlan";

type Phase = "inspecting" | "ready" | "password" | "extracting" | "error" | "done";
const titles: Record<Phase, string> = {
  inspecting: "正在检查压缩包",
  ready: "解压",
  password: "需要密码",
  extracting: "正在解压",
  error: "解压失败",
  done: "解压完成",
};
type DialogState = {
  entry: ArchiveEntry;
  phase: Phase;
  plan: Plan;
  previousFolder: string;
  run?: ReturnType<typeof previewPlan>;
  progress: number;
  message: string;
  open: boolean;
};

function stored(key: string) {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}
function remember(key: string, value: string) {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* In-memory preview still works. */
  }
}
function readFiles(key: string, initial: string[]): string[] {
  try {
    const value: unknown = JSON.parse(stored(key) ?? "null");
    return Array.isArray(value) && value.every((item) => typeof item === "string") ? value : initial;
  } catch {
    return initial;
  }
}

export function useArchivePreview() {
  const [dialog, setDialog] = useState<DialogState | null>(null);
  const [extracted, setExtracted] = useState(() => readFiles("aether-preview-extracted", []));
  const [outputs, setOutputs] = useState(() => readFiles("aether-preview-outputs", sampleOutputs));
  const [lastFolder, setLastFolder] = useState(() => stored("aether-preview-last-folder") ?? "");
  const [hideExtracted, setHide] = useState(() => stored("aether-preview-hide-extracted") !== "false");
  const inspect = (entry: ArchiveEntry) =>
    setDialog({
      entry,
      phase: "inspecting",
      plan: defaultPlan,
      previousFolder: lastFolder,
      progress: -1,
      message: "",
      open: true,
    });
  const close = () => setDialog((s) => s && { ...s, open: false });
  const retry = () =>
    setDialog(
      (s) =>
        s && {
          ...s,
          phase: "inspecting",
          run: undefined,
          progress: -1,
          message: "",
        },
    );
  const updatePlan = (change: Partial<Plan>) =>
    setDialog(
      (s) =>
        s && {
          ...s,
          plan: { ...s.plan, ...change },
        },
    );

  useEffect(() => {
    if (!dialog?.open) return;
    if (dialog.phase === "inspecting") {
      const timer = window.setTimeout(() => {
        setDialog((current) =>
          current === dialog
            ? {
                ...dialog,
                phase: dialog.entry.incomplete ? "error" : "ready",
                message: dialog.entry.incomplete ? "缺少后续分卷。请将所有分卷放在同一文件夹，再重试。" : "",
              }
            : current,
        );
      }, 300);
      return () => window.clearTimeout(timer);
    }
    if (dialog.phase === "extracting") {
      const timer = window.setTimeout(() => {
        const progress = Math.min(100, Math.max(0, dialog.progress) + 10);
        setDialog((current) =>
          current === dialog
            ? {
                ...dialog,
                progress,
                phase: progress === 100 ? "done" : "extracting",
              }
            : current,
        );
      }, 300);
      return () => window.clearTimeout(timer);
    }
    if ((dialog.phase === "done" || dialog.phase === "error") && dialog.run) {
      const { writes } = dialog.run;
      if (writes.length) setOutputs((files) => [...new Set([...files, ...writes])]);
      if (dialog.phase === "done") {
        setExtracted((files) => (files.includes(dialog.entry.name) ? files : [...files, dialog.entry.name]));
      }
    }
  }, [dialog]);
  useEffect(() => {
    remember("aether-preview-extracted", JSON.stringify(extracted));
  }, [extracted]);
  useEffect(() => {
    remember("aether-preview-outputs", JSON.stringify(outputs));
  }, [outputs]);
  useEffect(() => {
    remember("aether-preview-last-folder", lastFolder);
  }, [lastFolder]);

  function extract(password: string) {
    if (!dialog?.open || (dialog.phase !== "ready" && dialog.phase !== "password")) return;
    setLastFolder(dialog.plan.destination);
    if (dialog.entry.encrypted && password !== "aether") {
      setDialog({
        ...dialog,
        phase: "password",
        message: dialog.phase === "password" ? "密码不正确，请重试。" : "",
      });
      return;
    }
    const run = previewPlan(dialog.entry, dialog.plan, outputs);
    if (run.conflicts && dialog.plan.conflict === "fail") {
      setDialog({
        ...dialog,
        run,
        phase: "error",
        message: "已停止解压。目标目录中已有“" + run.firstConflict + "”。",
      });
      return;
    }
    setDialog({ ...dialog, run, phase: "extracting", progress: -1, message: "" });
  }
  return {
    dialog,
    inspect,
    retry,
    close,
    extract,
    updatePlan,
    outputs,
    hideExtracted,
    entries: samples.filter((entry) => !hideExtracted || !extracted.includes(entry.name)),
    setHideExtracted(value: boolean) {
      setHide(value);
      remember("aether-preview-hide-extracted", String(value));
    },
  };
}

type Choice<T extends string> = { value: T; label: string; description?: string };
function PlanChoice<T extends string>({
  label,
  value,
  options,
  onChange,
}: {
  label: string;
  value: T;
  options: Choice<T>[];
  onChange: (value: T) => void;
}) {
  return (
    <HStack vAlign="center" gap={3}>
      <StackItem size="fill">
        <Text>{label}</Text>
      </StackItem>
      <Selector
        label={label}
        isLabelHidden
        size="lg"
        width="57%"
        value={value}
        options={options}
        onChange={(next) => {
          const choice = options.find((option) => option.value === next);
          if (choice) onChange(choice.value);
        }}
      />
    </HStack>
  );
}

const pickFolder = "choose";
function destinationChoices(entry: ArchiveEntry, last: string, selected: string) {
  const choices: Choice<string>[] = [{ value: gamesFolder, label: "游戏目录" }];
  function add(path: string | undefined, label: string) {
    if (path && !choices.some((choice) => choice.value === path)) {
      choices.push({ value: path, label, description: breadcrumb(path) });
    }
  }
  add(entry.origin, "归档所在目录");
  if (entry.origin && entry.origin !== gamesFolder) add("文档", "文档目录");
  add(last, "上次使用的目录");
  add(selected, selected.split("/").filter(Boolean).at(-1) || selected);
  // Prefix actual paths so a custom folder can have the same name as a command.
  return [
    ...choices.map((choice) => ({ ...choice, value: "path:" + choice.value })),
    { value: pickFolder, label: "选择其他文件夹…" },
  ];
}

function FolderPicker({
  current,
  select,
  cancel,
}: {
  current: string;
  select: (path: string) => void;
  cancel: () => void;
}) {
  const [draft, setDraft] = useState("");
  const folder = normalizeFolder(draft);
  return (
    <Layout
      height="fill"
      header={<DialogHeader title="选择目标文件夹" onOpenChange={cancel} />}
      content={
        <LayoutContent>
          <VStack gap={3}>
            <TextInput
              label="文件夹路径"
              value={draft}
              onChange={setDraft}
              placeholder={breadcrumb(current)}
              onEnter={() => {
                if (folder) select(folder);
              }}
              autoComplete="off"
            />
            <List density="compact">
              {["我的文件/游戏收藏", "我的文件/解压测试"].map((path) => (
                <ListItem
                  key={path}
                  label={breadcrumb(path)}
                  startContent={<Icon icon={FolderIcon} />}
                  endContent={<Icon icon={ChevronRightIcon} size="sm" />}
                  onClick={() => select(path)}
                />
              ))}
            </List>
          </VStack>
        </LayoutContent>
      }
      footer={
        <LayoutFooter hasDivider>
          <HStack hAlign="end" gap={2}>
            <Button label="取消" onClick={cancel} />
            <Button
              label="选择文件夹"
              variant="primary"
              isDisabled={!folder}
              onClick={() => select(folder)}
            />
          </HStack>
        </LayoutFooter>
      }
    />
  );
}

export function ArchiveDialog({ archive }: { archive: ReturnType<typeof useArchivePreview> }) {
  const { dialog, close, retry, extract, updatePlan, outputs } = archive;
  const [password, setPassword] = useState("");
  const [choosingFolder, setChoosingFolder] = useState(false);
  const passwordInput = useRef<HTMLInputElement>(null);
  useEffect(() => {
    setPassword("");
  }, [dialog?.phase, dialog?.entry, dialog?.open]);
  useEffect(() => {
    setChoosingFolder(false);
  }, [dialog?.entry, dialog?.open]);
  useEffect(() => {
    if (dialog?.open && dialog.phase === "password" && !choosingFolder) {
      passwordInput.current?.focus();
    }
  }, [dialog?.open, dialog?.phase, choosingFolder]);
  if (!dialog) return null;
  const { entry, phase, plan, message, progress } = dialog;
  const editing = phase === "ready" || phase === "password";
  const busy = phase === "extracting";
  const output = dialog.run ?? previewPlan(entry, plan, outputs);
  const submit = () => {
    if (phase === "password" && !password) return;
    extract(password);
    setPassword("");
  };

  return (
    <Dialog
      isOpen={dialog.open}
      width={480}
      purpose={choosingFolder || busy || phase === "password" ? "form" : "info"}
      onOpenChange={(open) => {
        if (!open) {
          if (choosingFolder) setChoosingFolder(false);
          else close();
        }
      }}
    >
      {choosingFolder ? (
        <FolderPicker
          current={plan.destination}
          cancel={() => setChoosingFolder(false)}
          select={(destination) => {
            updatePlan({ destination });
            setChoosingFolder(false);
          }}
        />
      ) : (
        <Layout
          height="fill"
          header={<DialogHeader title={titles[phase]} onOpenChange={busy ? undefined : close} />}
          content={
            <LayoutContent>
              <VStack gap={3}>
                <HStack gap={3} vAlign="center">
                  <Icon icon={ArchiveBoxIcon} size="lg" />
                  <VStack gap={0.5} style={{ minWidth: 0, overflowWrap: "anywhere" }}>
                    <Text weight="semibold">{entry.name}</Text>
                    <Text type="supporting" color="secondary">
                      {entry.format} · {entry.size}
                    </Text>
                  </VStack>
                </HStack>
                {editing && (
                  <>
                    <Divider />
                    <PlanChoice
                      label="目标位置"
                      value={"path:" + plan.destination}
                      options={destinationChoices(entry, dialog.previousFolder, plan.destination)}
                      onChange={(next) => {
                        if (next === pickFolder) setChoosingFolder(true);
                        else updatePlan({ destination: next.slice("path:".length) });
                      }}
                    />
                    <PlanChoice
                      label="解压布局"
                      value={plan.layout}
                      options={layoutChoices.filter(
                        (option) => option.value !== "stripTopLevel" || sharedRoot(entry),
                      )}
                      onChange={(layout) => updatePlan({ layout })}
                    />
                    <PlanChoice
                      label="遇到同名文件"
                      value={plan.conflict}
                      options={conflictChoices}
                      onChange={(conflict) => updatePlan({ conflict })}
                    />
                    {output.notice && (
                      <HStack gap={2} vAlign="center" aria-live="polite">
                        {plan.conflict === "replace" && (
                          <Icon icon={ExclamationTriangleIcon} size="sm" color="warning" />
                        )}
                        <Text type="supporting" color="secondary">
                          {output.notice}
                        </Text>
                      </HStack>
                    )}
                  </>
                )}
                {phase === "password" && (
                  <TextInput
                    ref={passwordInput}
                    type="password"
                    label="压缩包密码"
                    value={password}
                    onChange={setPassword}
                    onEnter={submit}
                    autoComplete="off"
                    enterKeyHint="go"
                  />
                )}
                {message && (
                  <Text role="alert" color="secondary">
                    {message}
                  </Text>
                )}
                {(phase === "inspecting" || busy) && (
                  <ProgressBar
                    label={titles[phase]}
                    value={Math.max(0, progress)}
                    isLabelHidden
                    hasValueLabel
                    isIndeterminate={progress < 0}
                  />
                )}
              </VStack>
            </LayoutContent>
          }
          footer={
            <LayoutFooter hasDivider>
              <VStack gap={3}>
                {(editing || dialog.run) && (
                  <VStack gap={1} aria-live="polite">
                    <Text type="supporting" color="secondary">
                      {phase === "done" ? "输出位置" : "预计输出"}
                    </Text>
                    <HStack gap={2} vAlign="center">
                      <Icon icon={FolderIcon} size="sm" />
                      <Text maxLines={2} wordBreak="break-word">
                        {breadcrumb(output.output)}
                      </Text>
                    </HStack>
                    {editing && (
                      <Text type="supporting" color="secondary">
                        {output.placement}
                      </Text>
                    )}
                  </VStack>
                )}
                <HStack gap={2} hAlign="end" wrap="wrap">
                  {phase !== "done" && (
                    <Button label={busy ? "取消解压" : "取消"} size="lg" onClick={close} />
                  )}
                  {editing && (
                    <Button
                      label={plan.conflict === "replace" ? "解压并替换" : "解压"}
                      size="lg"
                      variant="primary"
                      isDisabled={phase === "password" && !password}
                      onClick={submit}
                    />
                  )}
                  {phase === "error" && <Button label="重试" size="lg" variant="primary" onClick={retry} />}
                  {phase === "done" && <Button label="完成" size="lg" variant="primary" onClick={close} />}
                </HStack>
              </VStack>
            </LayoutFooter>
          }
        />
      )}
    </Dialog>
  );
}
