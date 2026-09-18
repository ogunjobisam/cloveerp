import { createContext, type ComponentType } from "react";

/**
 * What the shell adds beside the refresh control on every page header.
 *
 * A context rather than an import, on purpose: page.tsx is imported by the
 * action dialogs, which src/lib/modules.tsx calls while it evaluates, and the
 * walkthrough reads that module. Importing the walkthrough from the page frame
 * closed a cycle that broke every route which imported the action bar before
 * the page frame. The shell, which nothing in that chain imports, provides the
 * component instead.
 */
export const PageHeaderExtras = createContext<ComponentType | null>(null);

/**
 * How a screen works, said once, behind the header's help icon.
 *
 * Almost every screen opened with one clear sentence and then added two more
 * that undid it — "Making the system agree with the shelf", then the stock
 * adjustments account in the profit and loss on the date of the count. The
 * first sentence is written for a person; the rest is for somebody who already
 * knows. So a page says the first sentence under its title and hands the rest
 * here, and the help sheet shows it at the top, under "How this works".
 *
 * The sheet lives once in the shell and its button twice (the phone header and
 * the desk header), so whether it is open is held here rather than in either
 * button — two buttons each holding their own sheet opened two sheets.
 */
export type ScreenDetail = {
  /** The path the detail was registered for, so it never outlives its screen. */
  path: string;
  /** The sentences a screen used to put under its title, a paragraph each. */
  paragraphs: string[];
};

export type HelpState = {
  open: boolean;
  setOpen: (open: boolean) => void;
  detail: ScreenDetail | null;
  setDetail: (detail: ScreenDetail | null) => void;
};

export const HelpContext = createContext<HelpState | null>(null);
