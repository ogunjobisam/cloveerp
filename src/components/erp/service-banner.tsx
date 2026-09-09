import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { Siren, Wrench, X } from "lucide-react";
import { useEffect, useState } from "react";

import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { TOUCH } from "./page";

/**
 * The in-app channel. Specification v1.6 §16.5: one incident update is one
 * row, and every channel carries it unchanged. This reads the same
 * erp_service_notices() the continuity screen reads, once a minute, and shows
 * the incidents that are live for this organisation and the maintenance that
 * is in progress or due within a day. Nothing here is composed by the client:
 * the body is the update as posted, the components are the vocabulary, and
 * an organisation the incident did not reach never sees it, because the door
 * never returns it.
 *
 * A dismissal is per update, in this browser only. The next update — even
 * "no change" — brings the banner back, which is the point of a timer.
 */

type Notices = {
  maintenance: {
    code: string;
    title: string;
    starts_at: string;
    ends_at: string;
    is_emergency: boolean;
    state: string;
  }[];
  incidents: {
    code: string;
    title: string;
    severity_code: string;
    state: string;
    affects_all_tenants: boolean;
    next_update_due_at: string | null;
    origin: string | null;
    components: { code: string; name: string }[];
    updates: { id: string; posted_at: string; body: string; is_no_change: boolean }[];
  }[];
};

const KEY = "clove.service-banner.dismissed";

function readDismissed(): string[] {
  try {
    const raw = window.localStorage.getItem(KEY);
    return raw ? (JSON.parse(raw) as string[]) : [];
  } catch {
    return [];
  }
}

function when(value: string | null) {
  return value ? new Date(value).toLocaleString() : "—";
}

export function ServiceBanner() {
  const { ui } = useT();
  const q = useQuery({
    queryKey: ["erp_service_notices", { banner: true }],
    queryFn: () => callErp<Notices>("erp_service_notices"),
    refetchInterval: 60_000,
    retry: false,
  });
  const [dismissed, setDismissed] = useState<string[]>([]);
  useEffect(() => setDismissed(readDismissed()), []);

  function dismiss(key: string) {
    const next = [...dismissed.filter((k) => k !== key), key].slice(-50);
    setDismissed(next);
    try {
      window.localStorage.setItem(KEY, JSON.stringify(next));
    } catch {
      // A browser that refuses storage just shows the banner again next time.
    }
  }

  const n = q.data;
  if (!n) return null;

  const soon = Date.now() + 24 * 60 * 60 * 1000;

  // `?? []` on both, because this banner renders inside the shell and a throw
  // here does not cost the banner — it costs every screen in the product. The
  // guard above passes anything that is not null, and callErp's cast is a
  // promise about the shape rather than a check of it, so one unexpected
  // response turned the whole desk into "This page didn't load". A missing
  // banner is the right failure; a missing application is not.
  const incidents = (n.incidents ?? [])
    .filter((i) => i.state !== "resolved")
    .map((i) => ({ ...i, key: `${i.code}:${i.updates[0]?.id ?? "declared"}` }))
    .filter((i) => !dismissed.includes(i.key));
  const windows = (n.maintenance ?? [])
    .filter(
      (w) =>
        w.state === "in_progress" ||
        (w.state === "planned" && new Date(w.starts_at).getTime() <= soon),
    )
    .map((w) => ({ ...w, key: `${w.code}:${w.state}` }))
    .filter((w) => !dismissed.includes(w.key));

  if (incidents.length === 0 && windows.length === 0) return null;

  return (
    <div role="status" aria-live="polite" className="border-b border-border bg-card">
      <div className="mx-auto flex max-w-7xl flex-col gap-2 px-4 py-2">
        {incidents.map((i) => (
          <div
            key={i.key}
            className={`flex flex-wrap items-start gap-3 rounded-lg border px-3 py-2 text-sm ${
              i.severity_code === "sev1" || i.severity_code === "sev2"
                ? "border-destructive/40 bg-destructive/5"
                : "border-amber-500/40 bg-amber-500/5"
            }`}
          >
            <Siren className="mt-0.5 size-4 shrink-0 text-destructive" aria-hidden />
            <div className="min-w-0 flex-1">
              <div className="flex flex-wrap items-center gap-2">
                <span className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                  {ui("Service notice")}
                </span>
                <span className="font-medium">{i.title}</span>
                <span className="font-mono text-xs text-muted-foreground">{i.severity_code}</span>
                <span className="text-xs text-muted-foreground">
                  {i.state === "contained" ? ui("Contained") : ui("Live")}
                  {i.affects_all_tenants ? ` · ${ui("Every organisation")}` : ""}
                </span>
              </div>
              {i.components.length > 0 || i.origin ? (
                <div className="mt-0.5 text-xs text-muted-foreground">
                  {i.components.map((c) => c.name).join(" · ")}
                  {i.origin ? ` · ${ui("Origin")}: ${i.origin}` : ""}
                </div>
              ) : null}
              {i.updates[0] ? (
                <p className="mt-1 whitespace-pre-line text-sm">{i.updates[0].body}</p>
              ) : null}
              <div className="mt-1 flex flex-wrap items-center gap-3 text-xs text-muted-foreground">
                {i.next_update_due_at ? (
                  <span>
                    {ui("Next update by")} {when(i.next_update_due_at)}
                  </span>
                ) : null}
                <Link to="/operations/continuity" className="underline underline-offset-2">
                  {ui("Details")}
                </Link>
              </div>
            </div>
            <button
              type="button"
              onClick={() => dismiss(i.key)}
              aria-label={ui("Dismiss")}
              className={`${TOUCH} shrink-0 rounded-md px-2 text-muted-foreground hover:text-foreground`}
            >
              <X className="size-4" aria-hidden />
            </button>
          </div>
        ))}
        {windows.map((w) => (
          <div
            key={w.key}
            className="flex flex-wrap items-start gap-3 rounded-lg border border-border bg-muted/40 px-3 py-2 text-sm"
          >
            <Wrench className="mt-0.5 size-4 shrink-0 text-muted-foreground" aria-hidden />
            <div className="min-w-0 flex-1">
              <div className="flex flex-wrap items-center gap-2">
                <span className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                  {ui("Service notice")}
                </span>
                <span className="font-medium">{w.title}</span>
                <span className="text-xs text-muted-foreground">
                  {w.is_emergency
                    ? ui("Emergency")
                    : w.state === "in_progress"
                      ? ui("In progress")
                      : ui("Planned")}
                </span>
              </div>
              <div className="mt-0.5 text-xs text-muted-foreground">
                {when(w.starts_at)} — {when(w.ends_at)}
              </div>
            </div>
            <button
              type="button"
              onClick={() => dismiss(w.key)}
              aria-label={ui("Dismiss")}
              className={`${TOUCH} shrink-0 rounded-md px-2 text-muted-foreground hover:text-foreground`}
            >
              <X className="size-4" aria-hidden />
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}
