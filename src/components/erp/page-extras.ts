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
