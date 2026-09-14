import { friendlyError } from "@/lib/errors";
import { useState, type ReactNode } from "react";
import { Copy } from "lucide-react";

import { Link } from "@tanstack/react-router";

import { TOUCH } from "../erp/page";
import { Pill } from "../erp/panel";
import {
  consoleSearch,
  isDemoCode,
  type SectionKey,
  type ViewKey,
} from "../../lib/platform-console";

/**
 * A link to a place in the console. A real link, so it can be opened in a new
 * tab and bookmarked, and Back returns from it.
 */
export function ConsoleLink({
  section,
  view,
  org,
  className,
  children,
}: {
  section: SectionKey;
  view?: ViewKey | undefined;
  org?: string | undefined;
  className?: string;
  children: ReactNode;
}) {
  return (
    <Link to="/platform" search={consoleSearch(section, view, org)} className={className}>
      {children}
    </Link>
  );
}

export const LINK_BUTTON = `${TOUCH} inline-flex items-center justify-center gap-1.5 rounded-md border border-input px-3 text-sm font-medium hover:bg-muted`;

/**
 * The console's shared furniture.
 *
 * Extracted verbatim from platform.tsx when it was split: four panels used all
 * of it and each would otherwise have grown its own copy.
 */

export const INPUT =
  "mt-1 w-full rounded-md border border-input bg-background px-3 py-2 text-sm placeholder:text-muted-foreground";

export function Card({
  title,
  icon,
  description,
  children,
  action,
}: {
  title: string;
  icon?: ReactNode;
  description?: string;
  children: ReactNode;
  action?: ReactNode;
}) {
  return (
    <section className="surface-card min-w-0 rounded-xl border border-border bg-card p-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="flex items-center gap-2 font-display text-base font-semibold">
            {icon}
            {title}
          </h2>
          {description ? <p className="mt-1 text-sm text-muted-foreground">{description}</p> : null}
        </div>
        {action}
      </div>
      <div className="mt-4 min-w-0">{children}</div>
    </section>
  );
}

export function Fail({ error }: { error: unknown }) {
  const f = friendlyError(error);
  return (
    <div role="alert" className="rounded-lg border border-destructive/30 bg-destructive/5 p-3">
      <p className="text-sm font-medium text-destructive">{f.title}</p>
      {f.body ? <p className="mt-1 text-xs text-muted-foreground">{f.body}</p> : null}
    </div>
  );
}

/** A token is shown once and never again, so it is shown loudly. */

export function TokenNotice({
  email,
  token,
  note,
}: {
  email: string;
  token: string;
  /** What happens next, where that is not obvious from having a token. */
  note?: string;
}) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="rounded-lg border border-primary/40 bg-primary/5 p-3">
      <p className="text-sm font-medium">Invitation for {email}</p>
      <p className="mt-1 text-xs text-muted-foreground">
        This token works once and is shown once. Send it to them now — it cannot be recovered.
      </p>
      {note ? <p className="mt-1 text-xs text-muted-foreground">{note}</p> : null}
      <div className="mt-2 flex items-center gap-2">
        <code className="min-w-0 flex-1 truncate rounded bg-muted px-2 py-1 font-mono text-xs">
          {token}
        </code>
        <button
          type="button"
          onClick={() => {
            void navigator.clipboard?.writeText(token);
            setCopied(true);
          }}
          className={`${TOUCH} inline-flex items-center gap-1 rounded-md border border-input px-3 text-xs font-medium`}
        >
          <Copy className="size-3.5" />
          {copied ? "Copied" : "Copy"}
        </button>
      </div>
    </div>
  );
}

export function statusTone(status: string): "ok" | "warn" | "bad" | "muted" {
  if (status === "active") return "ok";
  if (status === "suspended") return "warn";
  if (status === "deleted") return "bad";
  return "muted";
}

/**
 * An organisation's status in words. `deleted` is what the database calls an
 * organisation marked ended, whose data is still held until it is purged, and
 * "deleted" on screen said something that had not happened.
 */
export function statusLabel(status: string): string {
  if (status === "active") return "Active";
  if (status === "suspended") return "Suspended";
  if (status === "deleted") return "Ended";
  return status.charAt(0).toUpperCase() + status.slice(1).replace(/_/g, " ");
}

/**
 * An organisation as a person recognises it: its name first, its code quietly
 * after, and a Demo pill on a demonstration so nobody mistakes one for a
 * customer.
 */
export function OrganisationName({
  name,
  code,
  status,
  children,
}: {
  name: string;
  code: string;
  status?: string;
  /** The name as a link, when it leads somewhere; the plain name otherwise. */
  children?: ReactNode;
}) {
  return (
    <div className="min-w-0">
      <div className="flex flex-wrap items-center gap-1.5">
        <span className="text-sm font-medium">{children ?? name}</span>
        {isDemoCode(code) ? <Pill tone="muted">Demo</Pill> : null}
        {status ? <Pill tone={statusTone(status)}>{statusLabel(status)}</Pill> : null}
      </div>
      <div className="font-mono text-[11px] text-muted-foreground">{code}</div>
    </div>
  );
}
