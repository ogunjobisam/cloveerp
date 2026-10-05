import { useQuery } from "@tanstack/react-query";
import { useNavigate, useRouterState } from "@tanstack/react-router";
import { ChevronRight } from "lucide-react";

import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { documentIdInPath } from "../../lib/plain-words";
import { trailFor } from "../../lib/rail";
import { useConfirmLeave } from "./unsaved";

/**
 * Where you are, and the way back.
 *
 * The trail is derived from the module registry rather than from the URL's
 * spelling, and files a screen exactly where the rail does (src/lib/rail.ts).
 * Anything below a registered screen keeps its own segment, titled from the
 * path, because a deep screen with no crumb is a dead end.
 *
 * Every crumb asks before it leaves: if the screen is holding something
 * half-typed, the person is asked whether to discard it, and "no" keeps them
 * exactly where they were.
 */

export function Breadcrumbs() {
  const pathname = useRouterState({ select: (s) => s.location.pathname });
  const navigate = useNavigate();
  const confirmLeave = useConfirmLeave();
  const { ui } = useT();

  // The document page's own read, shared through its query key, so the crumb
  // costs nothing the page does not already ask for.
  const documentId = documentIdInPath(pathname);
  const { data: opened } = useQuery({
    queryKey: ["erp_document", { p_document_id: documentId ?? "" }],
    queryFn: () =>
      callErp<{ document: { document_number?: string } | null }>("erp_document", {
        p_document_id: documentId,
      }),
    enabled: documentId !== null,
  });
  const documentNumber = opened?.document?.document_number;
  const names: Record<string, string> = documentId
    ? { [`/documents/${documentId}`]: documentNumber ?? "Document" }
    : {};

  const crumbs = trailFor(pathname, names);
  if (crumbs.length < 2) return null;

  const go = async (to: string) => {
    if (to === pathname) return;
    if (!(await confirmLeave())) return;
    void navigate({ to });
  };

  return (
    <nav aria-label="Breadcrumb" className="mb-4">
      <ol className="flex flex-wrap items-center gap-1 text-xs text-muted-foreground">
        {crumbs.map((crumb, i) => {
          const last = i === crumbs.length - 1;
          const to = crumb.to;
          return (
            <li key={to ?? `group-${crumb.label}`} className="flex items-center gap-1">
              {i > 0 ? <ChevronRight aria-hidden className="size-3.5 shrink-0 opacity-60" /> : null}
              {last ? (
                <span aria-current="page" className="font-medium text-foreground">
                  {ui(crumb.label)}
                </span>
              ) : to === null ? (
                <span className="px-1 py-0.5">{ui(crumb.label)}</span>
              ) : (
                <button
                  type="button"
                  onClick={() => void go(to)}
                  className="rounded-sm px-1 py-0.5 underline-offset-2 hover:text-foreground hover:underline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring"
                >
                  {ui(crumb.label)}
                </button>
              )}
            </li>
          );
        })}
      </ol>
    </nav>
  );
}
