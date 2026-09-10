import { createContext, useCallback, useContext, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import { useEffect } from "react";

import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";

/**
 * Work in progress, and the question that protects it.
 *
 * A screen that is holding something half-typed says so by calling
 * `useUnsavedGuard(true)`. Anything that would leave that screen asks
 * `confirmLeave()` first, and only moves when the person says the typing may
 * go. Nothing is saved on their behalf and nothing is thrown away quietly:
 * the two honest answers are stay here, or discard and go.
 *
 * The count, not a boolean, because two forms can be open at once and the
 * second one closing must not clear the first one's claim.
 */
type UnsavedApi = {
  register: (id: string) => void;
  release: (id: string) => void;
  /** True when there is nothing to lose, or when the person agrees to lose it. */
  confirmLeave: () => Promise<boolean>;
  dirty: boolean;
};

const NOOP: UnsavedApi = {
  register: () => {},
  release: () => {},
  confirmLeave: () => Promise.resolve(true),
  dirty: false,
};

const UnsavedContext = createContext<UnsavedApi>(NOOP);

export function UnsavedChangesProvider({ children }: { children: ReactNode }) {
  const ids = useRef<Set<string>>(new Set());
  const [dirty, setDirty] = useState(false);
  const [asking, setAsking] = useState(false);
  const decide = useRef<((leave: boolean) => void) | null>(null);

  const register = useCallback((id: string) => {
    ids.current.add(id);
    setDirty(ids.current.size > 0);
  }, []);

  const release = useCallback((id: string) => {
    ids.current.delete(id);
    setDirty(ids.current.size > 0);
  }, []);

  const confirmLeave = useCallback(() => {
    if (ids.current.size === 0) return Promise.resolve(true);
    setAsking(true);
    return new Promise<boolean>((resolve) => {
      decide.current = resolve;
    });
  }, []);

  const settle = (leave: boolean) => {
    setAsking(false);
    decide.current?.(leave);
    decide.current = null;
  };

  // Closing the tab is a departure too, and the browser owns that question.
  useEffect(() => {
    if (!dirty) return;
    const onLeave = (e: BeforeUnloadEvent) => {
      e.preventDefault();
      e.returnValue = "";
    };
    window.addEventListener("beforeunload", onLeave);
    return () => window.removeEventListener("beforeunload", onLeave);
  }, [dirty]);

  const api = useMemo<UnsavedApi>(
    () => ({ register, release, confirmLeave, dirty }),
    [register, release, confirmLeave, dirty],
  );

  return (
    <UnsavedContext.Provider value={api}>
      {children}
      <AlertDialog open={asking} onOpenChange={(o) => (o ? null : settle(false))}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Discard the changes?</AlertDialogTitle>
            <AlertDialogDescription>
              This screen is holding something you have not saved. Leaving now throws it away;
              nothing is saved on your behalf.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel onClick={() => settle(false)}>No, stay here</AlertDialogCancel>
            <AlertDialogAction onClick={() => settle(true)}>Yes, discard</AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </UnsavedContext.Provider>
  );
}

/** Ask before leaving, if anything is in progress. Always safe to call. */
export function useConfirmLeave(): () => Promise<boolean> {
  return useContext(UnsavedContext).confirmLeave;
}

/** True while any screen is holding unsaved work. */
export function useHasUnsaved(): boolean {
  return useContext(UnsavedContext).dirty;
}

/**
 * Declare that this component is holding work in progress. Pass the live
 * answer; the claim is dropped the moment it is false, or on unmount.
 */
export function useUnsavedGuard(dirty: boolean): void {
  const { register, release } = useContext(UnsavedContext);
  const id = useRef<string>(Math.random().toString(36).slice(2));

  useEffect(() => {
    const key = id.current;
    if (dirty) register(key);
    else release(key);
    return () => release(key);
  }, [dirty, register, release]);
}
