import { createContext } from "react";

/**
 * Told when a dialog inside it opens (true) and closes (false), so whatever
 * offered the dialog can keep offering it meanwhile (./dialogs.tsx's
 * FormDialog tells it; the Fleet's rows listen). A dialog is rendered by the
 * button that opens it, and a list that refetches while it is open (on a
 * timer, or when the window regains focus) can stop offering that button
 * because of what the dialog itself just did: the dialog, and what it was
 * showing, would go with it.
 *
 * In a file of its own because a component file that also exports a context
 * loses fast refresh.
 */
export const DialogOpenContext = createContext<((open: boolean) => void) | null>(null);
