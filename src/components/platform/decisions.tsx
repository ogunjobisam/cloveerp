import { useQuery } from "@tanstack/react-query";
import { useMemo, useState } from "react";
import { Gavel } from "lucide-react";

import { Pill } from "../erp/panel";
import { TOUCH } from "../erp/page";
import { callErp } from "../../lib/erp";
import { prettifyRoutine } from "../../lib/friendly";
import { Card, Fail } from "./kit";

/**
 * What was decided, and whether the build still holds it.
 *
 * This was two tabs — "Decisions" and "Product decisions" — sitting next to
 * each other with near-identical headings and no way to tell from the rail
 * which one you wanted. They answer the same question at two scales: what the
 * product is (decided once, enforced by name) and where this build knowingly
 * departs from the specification. So they are one view with one filter, and
 * the thing you actually scan for — anything failing its own enforcement, and
 * anything still open — is counted at the top and sorted first.
 *
 * Both registers stay read-only. A decision is taken in a migration with its
 * reasoning beside it in the diff; a form here would let one be typed in with
 * neither.
 */

type PolicyDecision = {
  code: string;
  title: string;
  spec_reference: string | null;
  decision: string;
  rationale: string;
  status: "accepted" | "open" | "superseded";
  evidence: string | null;
  decided_by: string | null;
  decided_at: string;
};

type ProductDecision = {
  code: string;
  seq: number;
  title: string;
  decision: string;
  rationale: string;
  cost: string | null;
  supersedes: string | null;
  spec_reference: string | null;
  registered_at: string;
  checks: { schema_name: string; routine_name: string; note: string | null }[];
  findings: { finding: string; detail: string }[];
};

type Scope = "product" | "policy";

function Count({ tone, label, n }: { tone: "ok" | "warn" | "bad" | "muted"; label: string; n: number }) {
  return (
    <span className="inline-flex items-center gap-1.5 text-xs text-muted-foreground">
      <Pill tone={tone}>{n}</Pill>
      {label}
    </span>
  );
}

export function Decisions() {
  const [scope, setScope] = useState<Scope>("product");
  const [q, setQ] = useState("");
  const [open, setOpen] = useState<string | null>(null);

  const product = useQuery({
    queryKey: ["erp_platform_product_decisions"],
    queryFn: () => callErp<ProductDecision[]>("erp_platform_product_decisions"),
  });
  const policy = useQuery({
    queryKey: ["erp_platform_policy_decisions"],
    queryFn: () => callErp<PolicyDecision[]>("erp_platform_policy_decisions"),
  });

  const needle = q.trim().toLowerCase();
  const matches = (...parts: (string | null)[]) =>
    !needle || parts.filter(Boolean).join(" ").toLowerCase().includes(needle);

  const productRows = useMemo(() => {
    const rows = (product.data ?? []).filter((d) =>
      matches(d.title, d.decision, d.rationale, d.code, d.spec_reference),
    );
    // Anything the build would refuse, first.
    return [...rows].sort((a, b) => b.findings.length - a.findings.length || a.seq - b.seq);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [product.data, needle]);

  const policyRows = useMemo(() => {
    const rank = { open: 0, accepted: 1, superseded: 2 } as const;
    const rows = (policy.data ?? []).filter((d) =>
      matches(d.title, d.decision, d.rationale, d.code, d.spec_reference),
    );
    return [...rows].sort((a, b) => rank[a.status] - rank[b.status]);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [policy.data, needle]);

  const failing = (product.data ?? []).filter((d) => d.findings.length > 0).length;
  const unchecked = (product.data ?? []).filter(
    (d) => d.findings.length === 0 && d.checks.length === 0,
  ).length;
  const enforced = (product.data ?? []).length - failing - unchecked;
  const openPolicy = (policy.data ?? []).filter((d) => d.status === "open").length;

  const err = product.error ?? policy.error ?? null;
  const pending = scope === "product" ? product.isPending : policy.isPending;

  return (
    <Card
      title="Decisions"
      icon={<Gavel className="size-4 text-primary" />}
      description="What the product is, decided once and held by name, and where this build knowingly departs from the specification. Read only: a decision is taken in a migration, with its reasoning and its checks beside it."
      action={
        <input
          aria-label="Search decisions"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="Search decisions"
          className="w-56 rounded-md border border-input bg-background px-2 py-2 text-xs"
        />
      }
    >
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex gap-1 rounded-lg border border-border bg-background p-1">
          {(
            [
              ["product", `What the product is (${(product.data ?? []).length})`],
              ["policy", `Departures and open questions (${(policy.data ?? []).length})`],
            ] as [Scope, string][]
          ).map(([key, label]) => (
            <button
              key={key}
              type="button"
              onClick={() => setScope(key)}
              className={`${TOUCH} rounded-md px-3 text-sm font-medium ${
                scope === key ? "bg-muted" : "hover:bg-muted/60"
              }`}
            >
              {label}
            </button>
          ))}
        </div>
        <div className="flex flex-wrap items-center gap-3">
          {scope === "product" ? (
            <>
              {failing > 0 ? <Count tone="bad" label="not held" n={failing} /> : null}
              <Count tone="ok" label="held by a check" n={enforced} />
              {unchecked > 0 ? <Count tone="muted" label="not checked" n={unchecked} /> : null}
            </>
          ) : (
            <Count tone={openPolicy > 0 ? "warn" : "ok"} label="still open" n={openPolicy} />
          )}
        </div>
      </div>

      <div className="mt-4">
        {err ? (
          <Fail error={err} />
        ) : pending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : scope === "product" ? (
          productRows.length === 0 ? (
            <p className="text-sm text-muted-foreground">
              {needle ? "Nothing matches that." : "Nothing registered yet."}
            </p>
          ) : (
            <ul className="flex flex-col divide-y divide-border/60">
              {productRows.map((d) => (
                <li key={d.code} className="py-4 first:pt-0 last:pb-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-mono text-xs text-muted-foreground">{d.seq}</span>
                    <span className="text-sm font-semibold">{d.title}</span>
                    {d.findings.length > 0 ? (
                      <Pill tone="bad">
                        {d.findings.length === 1 ? "1 finding" : `${d.findings.length} findings`}
                      </Pill>
                    ) : d.checks.length > 0 ? (
                      <Pill tone="ok">Held</Pill>
                    ) : (
                      <Pill tone="muted">Not checked</Pill>
                    )}
                    {d.spec_reference ? (
                      <span className="text-xs text-muted-foreground">{d.spec_reference}</span>
                    ) : null}
                  </div>
                  <p className="mt-2 max-w-prose text-sm">{d.decision}</p>
                  <p className="mt-1 max-w-prose text-sm text-muted-foreground">{d.rationale}</p>

                  {d.findings.length > 0 ? (
                    <ul className="mt-2 flex flex-col gap-1">
                      {d.findings.map((f, i) => (
                        <li key={`${f.finding}-${i}`} className="text-xs text-destructive">
                          <span className="font-medium">{f.finding}:</span> {f.detail}
                        </li>
                      ))}
                    </ul>
                  ) : null}

                  {d.checks.length > 0 || d.cost || d.supersedes ? (
                    <button
                      type="button"
                      onClick={() => setOpen(open === d.code ? null : d.code)}
                      className="mt-2 text-xs underline underline-offset-2"
                    >
                      {open === d.code
                        ? "Hide how it is held"
                        : `How it is held (${d.checks.length} check${d.checks.length === 1 ? "" : "s"})`}
                    </button>
                  ) : null}

                  {open === d.code ? (
                    <div className="mt-2 rounded-lg border border-border bg-muted/40 p-3">
                      {d.cost ? (
                        <p className="text-xs text-muted-foreground">
                          <span className="font-medium">What it costs:</span> {d.cost}
                        </p>
                      ) : null}
                      {d.supersedes ? (
                        <p className="mt-1 text-xs text-muted-foreground">
                          <span className="font-medium">Supersedes:</span> {d.supersedes}
                        </p>
                      ) : null}
                      {d.checks.length > 0 ? (
                        <ul className="mt-2 flex flex-col gap-1">
                          {d.checks.map((c) => (
                            <li
                              key={`${c.schema_name}.${c.routine_name}`}
                              className="text-xs"
                              title={`${c.schema_name}.${c.routine_name}`}
                            >
                              {prettifyRoutine(c.routine_name)}
                              {c.note ? (
                                <span className="text-muted-foreground"> — {c.note}</span>
                              ) : null}
                            </li>
                          ))}
                        </ul>
                      ) : null}
                      <p className="mt-2 font-mono text-[11px] text-muted-foreground">
                        {d.code} · registered {new Date(d.registered_at).toLocaleDateString()}
                      </p>
                    </div>
                  ) : null}
                </li>
              ))}
            </ul>
          )
        ) : policyRows.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {needle ? "Nothing matches that." : "No departures recorded."}
          </p>
        ) : (
          <ul className="flex flex-col divide-y divide-border/60">
            {policyRows.map((d) => (
              <li key={d.code} className="py-4 first:pt-0 last:pb-0">
                <div className="flex flex-wrap items-center gap-2">
                  <Pill tone={d.status === "open" ? "warn" : d.status === "accepted" ? "ok" : "muted"}>
                    {d.status === "open"
                      ? "Open question"
                      : d.status === "accepted"
                        ? "Settled"
                        : "Superseded"}
                  </Pill>
                  <span className="text-sm font-semibold">{d.title}</span>
                  {d.spec_reference ? (
                    <span className="text-xs text-muted-foreground">{d.spec_reference}</span>
                  ) : null}
                </div>
                <p className="mt-2 max-w-prose text-sm">{d.decision}</p>
                <p className="mt-1 max-w-prose text-sm text-muted-foreground">{d.rationale}</p>
                {d.evidence ? (
                  <p className="mt-2 text-xs text-muted-foreground">
                    <span className="font-medium">Visible in:</span> {d.evidence}
                  </p>
                ) : null}
                <p className="mt-2 text-xs text-muted-foreground">
                  {d.decided_by
                    ? `${d.decided_by} · ${new Date(d.decided_at).toLocaleDateString()}`
                    : "Not yet decided"}
                </p>
              </li>
            ))}
          </ul>
        )}
      </div>
    </Card>
  );
}
