import { createFileRoute, Link } from "@tanstack/react-router";
import { useMemo, useState } from "react";

import { Gate } from "../components/erp/gate";
import { PageHeader } from "../components/erp/page";
import { DataPanel, Pill } from "../components/erp/panel";

/**
 * Help: frequently asked questions and the user guides.
 *
 * The guides are the product's help topics — the same rows the per-screen
 * help sheet reads, gathered in one place and grouped by module so a person
 * can read a module's guidance end to end instead of screen by screen. The
 * questions are the ones a new organisation actually asks, answered with
 * where to go rather than with prose to memorise.
 */

export const Route = createFileRoute("/help")({
  head: () => ({
    meta: [
      { title: "Help and user guides — Clove ERP" },
      {
        name: "description",
        content:
          "Frequently asked questions and the full user guides for every screen, grouped by module.",
      },
      { property: "og:title", content: "Help and user guides — Clove ERP" },
      {
        property: "og:description",
        content:
          "Frequently asked questions and the full user guides for every screen, grouped by module.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Help />
    </Gate>
  ),
});

const FAQS: { q: string; a: React.ReactNode }[] = [
  {
    q: "Where do I start?",
    a: (
      <>
        Open{" "}
        <Link to="/" className="underline">
          Home
        </Link>
        . Your first steps are listed there in the order to take them, and the ? button on any
        screen explains that screen. To explore without touching anything real, seed a demo
        organisation from Home and practise there.
      </>
    ),
  },
  {
    q: "How do I add a colleague?",
    a: (
      <>
        An administrator invites them from{" "}
        <Link to="/administration/permissions" className="underline">
          People and permissions
        </Link>
        . The invitation is a single-use token shown once — send it to them straight away; it cannot
        be recovered later.
      </>
    ),
  },
  {
    q: "Why can I see a screen but not use it?",
    a: (
      <>
        Seeing and doing are separate grants. The screen is on your launchpad because you may look;
        the action refuses because the permission it needs has not been granted to you. The refusal
        names the permission — an administrator grants it under{" "}
        <Link to="/administration/permissions" className="underline">
          People and permissions
        </Link>
        .
      </>
    ),
  },
  {
    q: "Can I try something without it counting?",
    a: (
      <>
        Yes. Training scenarios run in a demo organisation where nothing is real: seed one from{" "}
        <Link to="/" className="underline">
          Home
        </Link>
        , then open{" "}
        <Link to="/administration/adoption" className="underline">
          Guidance and adoption
        </Link>{" "}
        and start a scenario. A live organisation refuses scenarios on purpose.
      </>
    ),
  },
  {
    q: "Something went wrong — what does the error mean?",
    a: (
      <>
        Errors are written in plain language with what to do next. If one is not, the detail an
        administrator needs is in{" "}
        <Link to="/administration/audit" className="underline">
          Audit
        </Link>
        , which records who did what, when, and what the system said back.
      </>
    ),
  },
  {
    q: "How do I change what the product calls things?",
    a: (
      <>
        Renaming is a glossary change, not a code change. An administrator overrides the words under{" "}
        <Link to="/administration/terminology" className="underline">
          Terminology and branding
        </Link>
        , and every screen follows.
      </>
    ),
  },
];

/** Shaped by erp_help_topics(): the product's guidance, one row per screen. */
type Topic = {
  screen_path: string;
  nav_key: string;
  title: string;
  module_code: string;
  summary: string;
  steps: string[];
  next_action: string | null;
  actions: string[];
};

function Faq({ q, a }: { q: string; a: React.ReactNode }) {
  return (
    <details className="group rounded-lg border border-border bg-background px-4 py-3">
      <summary className="cursor-pointer list-none text-sm font-medium marker:hidden group-open:text-accent">
        {q}
      </summary>
      <p className="mt-2 text-sm text-muted-foreground">{a}</p>
    </details>
  );
}

function GuideTopic({ topic }: { topic: Topic }) {
  return (
    <details className="rounded-lg border border-border bg-background px-4 py-3">
      <summary className="flex cursor-pointer list-none flex-wrap items-center gap-2 marker:hidden">
        <span className="text-sm font-medium">{topic.title}</span>
        <span className="font-mono text-[11px] text-muted-foreground">{topic.screen_path}</span>
      </summary>
      <div className="mt-2 flex flex-col gap-3">
        <p className="text-sm text-muted-foreground">{topic.summary}</p>
        {topic.steps.length > 0 ? (
          <ol className="flex list-decimal flex-col gap-1 pl-5 text-sm">
            {topic.steps.map((s, i) => (
              <li key={i}>{s}</li>
            ))}
          </ol>
        ) : null}
        {topic.next_action ? (
          <p className="rounded-md border border-accent/30 bg-accent/5 px-3 py-2 text-xs">
            <span className="font-semibold">Next: </span>
            {topic.next_action}
          </p>
        ) : null}
      </div>
    </details>
  );
}

function Help() {
  const [query, setQuery] = useState("");

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Help and user guides">
        The questions a new organisation asks, and the product&apos;s guidance for every screen in
        one place. For the screen you are on right now, the ? button in the header is shorter.
      </PageHeader>

      <section className="min-w-0 rounded-xl border border-border bg-card">
        <header className="border-b border-border px-4 py-4 sm:px-5">
          <h2 className="text-sm font-semibold">Frequently asked questions</h2>
        </header>
        <div className="flex flex-col gap-2 px-4 py-4 sm:px-5">
          {FAQS.map((f) => (
            <Faq key={f.q} q={f.q} a={f.a} />
          ))}
        </div>
      </section>

      <div className="min-w-0">
        <label className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">
          Find a guide
          <input
            type="search"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="e.g. invoice, wave, recall…"
            className="mt-1 w-full max-w-sm rounded-md border border-input bg-background px-3 py-2 text-sm placeholder:text-muted-foreground"
          />
        </label>
      </div>

      <DataPanel<Topic>
        title="User guides"
        description="Every screen's guide, grouped by module. This is the same content the ? button shows, read end to end."
        fn="erp_help_topics"
        empty="No guides are published yet."
      >
        {(rows) => (
          <GuideList
            rows={rows.filter((t) => {
              if (!query.trim()) return true;
              const q = query.trim().toLowerCase();
              return (
                t.title.toLowerCase().includes(q) ||
                t.summary.toLowerCase().includes(q) ||
                t.screen_path.toLowerCase().includes(q) ||
                t.module_code.toLowerCase().includes(q)
              );
            })}
          />
        )}
      </DataPanel>
    </div>
  );
}

function GuideList({ rows }: { rows: Topic[] }) {
  const groups = useMemo(() => {
    const by = new Map<string, Topic[]>();
    for (const t of rows) {
      const list = by.get(t.module_code) ?? [];
      list.push(t);
      by.set(t.module_code, list);
    }
    return [...by.entries()].sort(([a], [b]) => a.localeCompare(b));
  }, [rows]);

  if (rows.length === 0) {
    return <p className="text-sm text-muted-foreground">No guide matches that search.</p>;
  }

  return (
    <div className="flex flex-col gap-6">
      {groups.map(([module, topics]) => (
        <section key={module}>
          <h3 className="mb-2 flex items-center gap-2 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
            <Pill tone="muted">{module}</Pill>
            <span>
              {topics.length} {topics.length === 1 ? "guide" : "guides"}
            </span>
          </h3>
          <div className="flex flex-col gap-2">
            {topics.map((t) => (
              <GuideTopic key={t.screen_path} topic={t} />
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}
