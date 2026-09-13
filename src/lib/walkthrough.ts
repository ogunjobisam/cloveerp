/**
 * The Settings walkthrough, as the desk reads it.
 *
 * The shapes are what public.erp_setup_walkthrough() and
 * public.erp_setup_progress() return. The helpers are pure so the choice of
 * "the next thing to do" can be tested without a screen.
 */
import { allTiles, areaOf } from "./modules";

/** The tile this path belongs to — the longest tile path that prefixes it. */
export function tileFor(pathname: string): { path: string; settings: boolean } | null {
  const tile = allTiles()
    .filter((t) => pathname === t.path || pathname.startsWith(`${t.path}/`))
    .sort((a, b) => b.path.length - a.path.length)[0];
  if (!tile) return null;
  return { path: tile.path, settings: areaOf(tile.group) === "settings" };
}

/** The Settings tile this path belongs to, or nothing if it is not one. */
export function settingsScreenFor(pathname: string): string | null {
  const tile = tileFor(pathname);
  return tile && tile.settings ? tile.path : null;
}

export type WalkthroughRequirement = {
  code: string;
  title: string;
  screen_path: string;
  complete: boolean;
};

export type WalkthroughStep = {
  code: string;
  seq: number;
  title: string;
  why: string;
  action_label: string;
  action_fn: string | null;
  permission_code: string;
  permitted: boolean;
  observable: boolean;
  satisfied: boolean;
  evidence: string | null;
  done_at: string | null;
  dismissed_at: string | null;
  complete: boolean;
  blocked: boolean;
  requires: WalkthroughRequirement[];
};

export type WalkthroughScreen = {
  screen_path: string;
  seq: number;
  title: string;
  blurb: string;
  previous: { screen_path: string; title: string } | null;
  next: { screen_path: string; title: string } | null;
  screens: number;
};

export type Walkthrough = {
  screen: WalkthroughScreen | null;
  steps: WalkthroughStep[];
};

export type SetupScreenProgress = {
  screen_path: string;
  seq: number;
  title: string;
  blurb: string;
  total: number;
  complete: number;
  next: { code: string; title: string; action_label: string } | null;
};

/** The step to do now: the first one not complete and not waiting on another. */
export function nextStep(steps: WalkthroughStep[]): WalkthroughStep | null {
  const ordered = [...steps].sort((a, b) => a.seq - b.seq);
  return ordered.find((s) => !s.complete && !s.blocked) ?? null;
}

/** How far along a screen is, as a count of complete steps. */
export function completeCount(steps: WalkthroughStep[]): number {
  return steps.filter((s) => s.complete).length;
}

/** The first screen in the order that still has something to do. */
export function nextScreen(progress: SetupScreenProgress[]): SetupScreenProgress | null {
  const ordered = [...progress].sort((a, b) => a.seq - b.seq);
  return ordered.find((p) => p.next !== null) ?? null;
}

/** What the step's state is called, in one word the panel can colour. */
export type StepState = "done" | "aside" | "waiting" | "next" | "todo";

export function stepState(step: WalkthroughStep, next: WalkthroughStep | null): StepState {
  if (step.dismissed_at && !step.satisfied && !step.done_at) return "aside";
  if (step.complete) return "done";
  if (step.blocked) return "waiting";
  if (next && next.code === step.code) return "next";
  return "todo";
}
