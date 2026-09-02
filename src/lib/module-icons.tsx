import {
  Accessibility,
  ArrowRightLeft,
  Boxes,
  Building2,
  ClipboardCheck,
  Coins,
  Cog,
  Compass,
  CreditCard,
  FileInput,
  Factory,
  GitPullRequestArrow,
  Home,
  KeyRound,
  Languages,
  LineChart,
  Plug,
  Printer,
  Repeat,
  ScanBarcode,
  ScrollText,
  Settings2,
  ShieldCheck,
  ShoppingCart,
  Timer,
  Truck,
  UserRound,
  UserX,
  Handshake,
  HeartPulse,
  CalendarRange,
  Database,
  type LucideIcon,
} from "lucide-react";

import type { TileDef } from "./modules";

/**
 * One icon per screen, chosen so the launchpad and rail can be scanned by
 * shape before the label is read. Paths are the key because they are the only
 * identifier every navigation surface already carries.
 */
const ICONS: Record<string, LucideIcon> = {
  "/": Home,
  "/settings": Settings2,
  "/profile": UserRound,
  "/planning": CalendarRange,
  "/procurement": ShoppingCart,
  "/production": Factory,
  "/inventory": Boxes,
  "/logistics": Truck,
  "/sales": Handshake,
  "/finance": Coins,
  "/quality": ClipboardCheck,
  "/reporting": LineChart,
  "/master-data": Database,
  "/master-data/imports": FileInput,
  "/governance": GitPullRequestArrow,
  "/operations/jobs": Timer,
  "/operations/integrations": Plug,
  "/operations/assurance": ShieldCheck,
  "/operations/continuity": HeartPulse,
  "/operations/devices": ScanBarcode,
  "/operations/cutover": ArrowRightLeft,
  "/operations/output": Printer,
  "/reporting/reproducibility": Repeat,
  "/administration/erasure": UserX,
  "/administration/adoption": Compass,
  "/administration/accessibility": Accessibility,
  "/administration/commercial": CreditCard,
  "/administration/configuration": Cog,
  "/administration/permissions": KeyRound,
  "/administration/terminology": Languages,
  "/administration/audit": ScrollText,
  "/administration/tenant": Building2,
};

export function iconFor(path: string): LucideIcon {
  return ICONS[path] ?? Boxes;
}

/** One line of orientation per section of the launchpad. */
export const GROUP_BLURBS: Record<TileDef["group"], string> = {
  plan: "Decide what should happen and when.",
  source: "Bring materials and services in.",
  make: "Turn inputs into finished goods, and check them.",
  move: "Hold, count and ship what exists.",
  sell: "Quote, order and deliver to customers.",
  settle: "Value it, invoice it, close the period.",
  records: "The master data everything depends on, how it changes, and the reports over it.",
  organisation: "Who is in the organisation, what they may do, and the plan it is on.",
  configure: "How the modules behave: installed configuration, packs, codes, terminology.",
  operate: "The plumbing: jobs, integrations, printing, devices, continuity, cutover.",
  assure: "The evidence: the audit log, the assertions, personal data, accessibility, adoption.",
};
