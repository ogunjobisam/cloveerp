import { createFileRoute, Link } from "@tanstack/react-router";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "ERPWare — Enterprise Resource Planning" },
      {
        name: "description",
        content:
          "ERPWare unifies finance, inventory, and operations into one calm command center. Start your free trial today.",
      },
      { property: "og:title", content: "ERPWare — Enterprise Resource Planning" },
      {
        property: "og:description",
        content:
          "ERPWare unifies finance, inventory, and operations into one calm command center. Start your free trial today.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: Index,
});

function Logo() {
  return (
    <div className="flex items-center gap-2">
      <span className="grid size-8 place-items-center rounded-lg bg-brand font-display text-sm text-surface select-none">
        e
      </span>
      <span className="font-display text-lg text-brand select-none">ERPWare</span>
    </div>
  );
}

function PulseBadge() {
  return (
    <div className="flex items-center gap-1.5">
      <span className="size-1.5 rounded-full bg-accent animate-pulse" aria-hidden="true" />
      <span className="text-xs font-medium text-accent">Live metrics</span>
    </div>
  );
}

function DashboardPreview() {
  return (
    <section className="pb-6" aria-label="Live dashboard preview">
      <div className="rounded-2xl bg-soft/60 p-3 ring-1 ring-black/5">
        <div className="rounded-xl bg-surface p-4 ring-1 ring-black/5">
          <div className="flex items-center justify-between">
            <span className="text-[10px] font-semibold uppercase tracking-wider text-ink/40">
              Pulse
            </span>
            <PulseBadge />
          </div>

          <div className="mt-4 grid grid-cols-2 gap-3">
            <div className="rounded-[10px] bg-soft/40 p-3">
              <p className="text-[11px] font-medium text-ink/50">Monthly Gross</p>
              <p className="mt-1 font-display text-2xl text-brand">$4.2M</p>
            </div>
            <div className="rounded-[10px] bg-soft/40 p-3">
              <p className="text-[11px] font-medium text-ink/50">Active POs</p>
              <p className="mt-1 font-display text-2xl text-brand">1,284</p>
            </div>
          </div>

          <div className="mt-4 rounded-[10px] bg-soft/30 p-3">
            <div className="flex items-center justify-between mb-2">
              <p className="text-[11px] font-medium text-ink/50">Warehouse Utilization</p>
              <span className="text-[11px] font-semibold text-brand">82%</span>
            </div>
            <div className="h-1.5 w-full rounded-full bg-line/50 overflow-hidden">
              <div
                className="h-full rounded-full bg-accent"
                style={{ width: "82%" }}
                aria-hidden="true"
              />
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

function FeatureCard({
  icon,
  title,
  description,
}: {
  icon: React.ReactNode;
  title: string;
  description: string;
}) {
  return (
    <div className="flex gap-3.5">
      <div className="grid size-9 shrink-0 place-items-center rounded-[10px] bg-brand/5 text-brand ring-1 ring-brand/10">
        {icon}
      </div>
      <div>
        <h3 className="font-display text-sm font-semibold text-brand">{title}</h3>
        <p className="mt-1 text-sm leading-relaxed text-ink/60 text-pretty">{description}</p>
      </div>
    </div>
  );
}

function Features() {
  return (
    <section className="pb-8" aria-labelledby="modular-command-heading">
      <div className="rounded-2xl border border-line bg-surface p-5 ring-1 ring-black/5">
        <p className="text-[11px] font-medium uppercase tracking-[0.18em] text-accent">
          Modular Command
        </p>
        <div className="mt-5 space-y-5">
          <FeatureCard
            icon={
              <svg
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 16 16"
                fill="currentColor"
                className="size-4"
                aria-hidden="true"
              >
                <path
                  fillRule="evenodd"
                  d="M8 15A7 7 0 1 0 8 1a7 7 0 0 0 0 14Zm.75-10.25v2.5h2.5a.75.75 0 0 1 0 1.5h-2.5v2.5a.75.75 0 0 1-1.5 0v-2.5h-2.5a.75.75 0 0 1 0-1.5h2.5v-2.5a.75.75 0 0 1 1.5 0Z"
                  clipRule="evenodd"
                />
              </svg>
            }
            title="Ledger Automation"
            description="Reconcile accounts instantly with verified ledger matching across banks."
          />
          <FeatureCard
            icon={
              <svg
                xmlns="http://www.w3.org/2000/svg"
                viewBox="0 0 16 16"
                fill="currentColor"
                className="size-4"
                aria-hidden="true"
              >
                <path d="M3 2a1 1 0 0 0-1 1v1a1 1 0 0 0 1 1h1a1 1 0 0 0 1-1V3a1 1 0 0 0-1-1H3ZM3 6a1 1 0 0 0-1 1v1a1 1 0 0 0 1 1h1a1 1 0 0 0 1-1V7a1 1 0 0 0-1-1H3ZM2 11a1 1 0 0 1 1-1h1a1 1 0 0 1 1 1v1a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1v-1ZM7 2a1 1 0 0 0-1 1v1a1 1 0 0 0 1 1h1a1 1 0 0 0 1-1V3a1 1 0 0 0-1-1H7ZM6 7a1 1 0 0 1 1-1h1a1 1 0 0 1 1 1v1a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1V7ZM7 10a1 1 0 0 0-1 1v1a1 1 0 0 0 1 1h1a1 1 0 0 0 1-1v-1a1 1 0 0 0-1-1H7ZM11 2a1 1 0 0 0-1 1v1a1 1 0 0 0 1 1h1a1 1 0 0 0 1-1V3a1 1 0 0 0-1-1h-1ZM10 7a1 1 0 0 1 1-1h1a1 1 0 0 1 1 1v1a1 1 0 0 1-1 1h-1a1 1 0 0 1-1-1V7ZM11 10a1 1 0 0 0-1 1v1a1 1 0 0 0 1 1h1a1 1 0 0 0 1-1v-1a1 1 0 0 0-1-1h-1Z" />
              </svg>
            }
            title="Global Inventory"
            description="Single-source tracking for multi-node logistics and freight forwarding."
          />
        </div>
      </div>
    </section>
  );
}

function Pricing() {
  return (
    <section className="pb-8" id="pricing" aria-labelledby="pricing-heading">
      <div className="relative overflow-hidden rounded-2xl bg-accent text-surface p-6">
        <div
          className="absolute top-0 right-0 w-32 h-32 rounded-full bg-white/5 -mr-16 -mt-16 blur-2xl"
          aria-hidden="true"
        />
        <p className="text-[11px] font-medium uppercase tracking-[0.18em] text-surface/80">
          Fair Pricing
        </p>
        <h2 id="pricing-heading" className="mt-3 font-display text-2xl font-medium leading-tight">
          From $29 per seat.
        </h2>
        <p className="mt-2 text-sm text-surface/80 text-pretty">
          Transparent billing that scales with your headcount.
        </p>
        <div className="mt-6 flex flex-col gap-2.5">
          <a
            href="#"
            className="rounded-full bg-surface text-accent px-5 py-3 text-sm font-semibold text-center ring-2 ring-accent transition-transform active:scale-[0.98]"
          >
            Start free trial
          </a>
          <a
            href="#"
            className="rounded-full ring-1 ring-surface/40 px-5 py-3 text-sm font-medium text-center text-surface transition-colors hover:bg-surface/10"
          >
            Schedule a demo
          </a>
        </div>
      </div>
    </section>
  );
}

function Footer() {
  return (
    <footer className="pb-12 text-center">
      <div className="flex justify-center gap-4 mb-4" aria-hidden="true">
        <div className="size-1.5 rounded-full bg-line" />
        <div className="size-1.5 rounded-full bg-line" />
        <div className="size-1.5 rounded-full bg-line" />
      </div>
      <p className="text-[10px] font-medium uppercase tracking-widest text-ink/40">
        Built for precision · ERPWare MMXXIV
      </p>
    </footer>
  );
}

function Index() {
  return (
    <div className="min-h-screen bg-surface text-ink font-sans antialiased">
      <div className="mx-auto max-w-[390px] px-5 md:max-w-3xl lg:max-w-5xl">
        {/* Navigation */}
        <nav className="flex items-center justify-between py-5" aria-label="Primary">
          <Logo />
          <a
            href="#pricing"
            className="rounded-full bg-soft px-3.5 py-2 text-sm font-medium text-ink transition-colors hover:bg-line"
          >
            Pricing
          </a>
        </nav>

        {/* Hero */}
        <section className="pt-6 pb-4" aria-labelledby="hero-heading">
          <p className="text-[11px] font-medium uppercase tracking-[0.18em] text-accent">
            Enterprise Resource Planning
          </p>
          <h1
            id="hero-heading"
            className="mt-3 max-w-[20ch] font-display text-4xl font-medium leading-[1.06] text-brand text-balance md:text-5xl lg:text-6xl"
          >
            Every business module, in one calm place.
          </h1>
          <p className="mt-4 max-w-[46ch] text-base text-ink/70 text-pretty md:text-lg">
            Finance, inventory, and operations that lock together quietly. No noise, just the
            numbers you need when you need them.
          </p>
        </section>

        <DashboardPreview />
        <Features />
        <Pricing />
        <Footer />
      </div>
    </div>
  );
}
