import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { writeFileSync, copyFileSync } from "node:fs";
import {
  BookOpenIcon,
  FilmIcon,
  BoltIcon,
  Cog6ToothIcon,
  FolderIcon,
  PhotoIcon,
  MagnifyingGlassIcon,
  PlusIcon,
  ArrowLeftIcon,
  ArrowPathIcon,
  ChatBubbleLeftRightIcon,
  StarIcon,
  PlayIcon,
  ChevronRightIcon,
  ChevronUpIcon,
  ChevronDownIcon,
  Squares2X2Icon,
  ListBulletIcon,
  SwatchIcon,
  ComputerDesktopIcon,
  ShieldCheckIcon,
  WrenchScrewdriverIcon,
  InformationCircleIcon,
  XMarkIcon,
  TrashIcon,
} from "@heroicons/react/24/outline";

import {
  BookOpenIcon as BookOpenSolid,
  FilmIcon as FilmSolid,
  BoltIcon as BoltSolid,
  Cog6ToothIcon as SettingsSolid,
} from "@heroicons/react/24/solid";

const icons = {
  photo: PhotoIcon,
  delete: TrashIcon,
  close: XMarkIcon,
  interface: SwatchIcon,
  render: ComputerDesktopIcon,
  compatibility: ShieldCheckIcon,
  diagnostics: WrenchScrewdriverIcon,
  about: InformationCircleIcon,
  community: ChatBubbleLeftRightIcon,
  star: StarIcon,
  cards: Squares2X2Icon,
  list: ListBulletIcon,
  library_selected: BookOpenSolid,
  video_selected: FilmSolid,
  flash_selected: BoltSolid,
  settings_selected: SettingsSolid,
  library: BookOpenIcon,
  video: FilmIcon,
  flash: BoltIcon,
  settings: Cog6ToothIcon,
  folder: FolderIcon,
  search: MagnifyingGlassIcon,
  plus: PlusIcon,
  refresh: ArrowPathIcon,
  back: ArrowLeftIcon,
  play: PlayIcon,
  chevron_right: ChevronRightIcon,
  chevron_up: ChevronUpIcon,
  chevron_down: ChevronDownIcon,
};
const target = new URL(
  "../../../apps/godot_app/assets/ui/astryx/",
  import.meta.url,
);
// Keep the committed .svg.import settings alongside these 24-unit vectors:
// 4x rasterization supplies high-DPI pixels; mipmaps handle smaller UI sizes.
for (const [name, component] of Object.entries(icons)) {
  const svg = renderToStaticMarkup(createElement(component)).replaceAll(
    "currentColor",
    "white",
  );
  writeFileSync(new URL(`${name}.svg`, target), svg + "\n");
}
copyFileSync(
  new URL("../node_modules/@heroicons/react/LICENSE", import.meta.url),
  new URL("HEROICONS-LICENSE", target),
);
console.log(`Exported ${Object.keys(icons).length} shared Heroicons to Godot.`);
