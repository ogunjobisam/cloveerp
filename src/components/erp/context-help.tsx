import { useQuery } from "@tanstack/react-query";
import { Link, useRouterState } from "@tanstack/react-router";
import { CircleHelp } from "lucide-react";
import { useState } from "react";

import { Sheet, SheetContent, SheetDescription, SheetTitle } from "@/components/ui/sheet";
import { friendlyError } from "@/lib/errors";

import { callErp } from "../../lib/erp";
import { allTiles } from "../../lib/modules";
import { TOUCH } from "./page";

/**
 * Contextual help (specification v1.2 §22.1).
 *
 * One button in the header, on every screen, that opens the product's guidance
 * for the screen the person is on: what it is for, the steps in the order they
 * are taken, the next thing to do, and the doors it drives. The content lives
 * in erp_ref.help_topic and is read through erp_help_topic(), so the guidance
 * an organisation sees is the guidance the build checked — every tile and the
 * home screen have a topic, and the build fails when one is missing.
 *
 * An organisation adds its own note beside the product's through the resource
 * layer (help.local.<screen>), which is why the sheet shows two voices and
 * labels them.
 */

type HelpTopic = {
  screen_path: string;
  nav_key: string;
  title: string;
  module_code: string;
  summary: string;
  steps: string[];
  next_action: string | null;
  actions: string[];
  local_note: string | null;
  local_key: string;
} | null;

/** The topic for a path: the tile whose path is the longest prefix, or home. */
function helpPathFor(pathname: string): string {
  if (pathname === "/" || pathname === "/settings") return pathname;
  const paths = allTiles()
    .map((t) => t.path)
    .filter((p) => pathname === p || pathname.startsWith(`${p}/`))
    .sort((a, b) => b.length - a.length);
  return paths[0] ?? pathname;
}

export function ContextHelp() {
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const [open, setOpen] = useState(false);
  const path = helpPathFor(pathname);

  const topic = useQuery({
    queryKey: ["erp_help_topic", { p_screen_path: path }],
    queryFn: () => callErp<HelpTopic>("erp_help_topic", { p_screen_path: path }),
    enabled: open,
  });

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        aria-label="Help for this screen"
        aria-expanded={open}
        className={`${TOUCH} inline-flex w-11 shrink-0 items-center justify-center rounded-r-md border-l border-input text-muted-foreground hover:bg-muted hover:text-foreground`}
      >
        <CircleHelp className="size-5" />
      </button>

      <Sheet open={open} onOpenChange={setOpen}>
        <SheetContent
          side="right"
          className="flex w-[90vw] max-w-md flex-col gap-4 overflow-y-auto"
        >
          <SheetTitle className="text-base">
            {topic.data?.title ?? "Help for this screen"}
          </SheetTitle>
          <SheetDescription className="text-xs text-muted-foreground">
            The product&apos;s guidance for <span className="font-mono">{path}</span>. The same for
            every organisation; a note of your own sits beneath it.
          </SheetDescription>

          {topic.isPending ? (
            <p role="status" className="text-sm text-muted-foreground">
              Loading…
            </p>
          ) : topic.error ? (
            <div role="alert">
              <p className="text-sm font-medium text-destructive">This did not load.</p>
              <p className="mt-1 text-xs text-muted-foreground">
                {friendlyError(topic.error).title}
              </p>
            </div>
          ) : !topic.data ? (
            <p className="text-sm text-muted-foreground">
              There is no guidance for this screen yet. Every tile on the launchpad has some; this
              path is not one of them.
            </p>
          ) : (
            <div className="flex flex-col gap-4">
              <p className="text-sm">{topic.data.summary}</p>

              {topic.data.steps.length > 0 ? (
                <section>
                  <h3 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                    In order
                  </h3>
                  <ol className="mt-2 flex list-decimal flex-col gap-1.5 pl-5 text-sm">
                    {topic.data.steps.map((s, i) => (
                      <li key={i}>{s}</li>
                    ))}
                  </ol>
                </section>
              ) : null}

              {topic.data.next_action ? (
                <section className="rounded-lg border border-accent/30 bg-accent/5 p-3">
                  <h3 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                    Next
                  </h3>
                  <p className="mt-1 text-sm">{topic.data.next_action}</p>
                </section>
              ) : null}

              {topic.data.local_note ? (
                <section className="rounded-lg border border-border bg-muted/40 p-3">
                  <h3 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                    From your organisation
                  </h3>
                  <p className="mt-1 text-sm">{topic.data.local_note}</p>
                </section>
              ) : (
                <p className="text-xs text-muted-foreground">
                  Your organisation has not added a note for this screen. An administrator writes
                  one as the terminology override{" "}
                  <span className="font-mono">{topic.data.local_key}</span>.
                </p>
              )}

              {topic.data.actions.length > 0 ? (
                <section>
                  <h3 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                    What this screen drives
                  </h3>
                  <ul className="mt-2 flex flex-wrap gap-1.5">
                    {topic.data.actions.map((a) => (
                      <li
                        key={a}
                        title={a}
                        className="rounded-full border border-border bg-muted/60 px-2.5 py-1 text-xs text-muted-foreground"
                      >
                        {routineLabel(a)}
                      </li>
                    ))}
                  </ul>
                </section>
              ) : null}

              <p className="text-xs text-muted-foreground">
                Your first-run guidance is on{" "}
                <Link to="/" className="underline" onClick={() => setOpen(false)}>
                  Home
                </Link>
                ; training scenarios and every topic are under{" "}
                <Link
                  to="/administration/adoption"
                  className="underline"
                  onClick={() => setOpen(false)}
                >
                  Guidance and adoption
                </Link>
                .
              </p>
            </div>
          )}
        </SheetContent>
      </Sheet>
    </>
  );
}
