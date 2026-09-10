import { createFileRoute, Link } from "@tanstack/react-router";
import {
  ArrowRight,
  Banknote,
  Boxes,
  ClipboardCheck,
  Factory,
  FileText,
  Landmark,
  MapPin,
  PackageCheck,
  PoundSterling,
  Route as RouteIcon,
  Scale,
  ShieldCheck,
  TrendingUp,
  Truck,
  Vault,
  type LucideIcon,
} from "lucide-react";

import warehouseImg from "../assets/landing-warehouse.jpg";
import financeImg from "../assets/landing-finance.jpg";
import shotFinance from "../assets/product-finance.png";
import shotWarehouse from "../assets/product-warehouse.png";
import shotForecast from "../assets/product-forecast.png";
import { Logo, Wordmark } from "../components/erp/logo";

export const Route = createFileRoute("/product")({
  head: () => ({
    meta: [
      { title: "Clove ERP — British-built ERP for finance, stock and operations" },
      {
        name: "description",
        content:
          "Clove ERP unifies planning, procurement, production, logistics, sales and finance into one governed platform. VAT-ready, sterling-native, and built in the UK.",
      },
      { property: "og:title", content: "Clove ERP — British-built ERP" },
      {
        property: "og:description",
        content:
          "Planning, procurement, production, logistics, sales and finance in one governed platform. VAT-ready, sterling-native, built in the UK.",
      },
      { property: "og:type", content: "website" },
      { property: "og:url", content: "https://cloveerp.com/product" },
      { property: "og:image", content: "https://cloveerp.com/og-image.png" },
      { name: "twitter:card", content: "summary_large_image" },
      { name: "twitter:image", content: "https://cloveerp.com/og-image.png" },
    ],
    links: [{ rel: "canonical", href: "https://cloveerp.com/product" }],
    scripts: [
      {
        type: "application/ld+json",
        children: JSON.stringify({
          "@context": "https://schema.org",
          "@type": "SoftwareApplication",
          name: "Clove ERP",
          applicationCategory: "BusinessApplication",
          operatingSystem: "Web",
          url: "https://cloveerp.com/product",
          offers: {
            "@type": "Offer",
            price: "25",
            priceCurrency: "GBP",
          },
        }),
      },
    ],
  }),
  component: ProductPage,
});

/* ------------------------------------------------------------------ */

function Nav() {
  return (
    <nav className="flex items-center justify-between py-5" aria-label="Primary">
      <Wordmark size={30} />
      <div className="flex items-center gap-3">
        <a
          href="#features"
          className="hidden text-sm font-medium text-ink/70 transition-colors hover:text-brand sm:block"
        >
          Features
        </a>
        <a
          href="#pricing"
          className="hidden text-sm font-medium text-ink/70 transition-colors hover:text-brand sm:block"
        >
          Pricing
        </a>
        <Link
          to="/signin"
          className="rounded-full bg-brand px-4 py-2 text-sm font-semibold text-surface transition-transform active:scale-[0.98]"
        >
          Sign in
        </Link>
      </div>
    </nav>
  );
}

function Hero() {
  return (
    <section className="pt-8 pb-10 md:pt-14" aria-labelledby="hero-heading">
      <div className="grid items-center gap-10 lg:grid-cols-2">
        <div>
          <p className="flex items-center gap-2 text-[11px] font-semibold uppercase tracking-[0.18em] text-accent">
            <Landmark className="size-3.5" aria-hidden="true" />
            Built in Britain · Sterling-native
          </p>
          <h1
            id="hero-heading"
            className="mt-4 max-w-[18ch] font-display text-4xl font-medium leading-[1.05] text-brand text-balance md:text-5xl lg:text-6xl"
          >
            The whole firm, in one calm ledger.
          </h1>
          <p className="mt-5 max-w-[46ch] text-base leading-relaxed text-ink/70 text-pretty md:text-lg">
            Clove ERP runs planning, procurement, production, warehousing, sales and finance as one
            governed system — every document state-machined, every pound accounted for, every action
            audited.
          </p>
          <div className="mt-7 flex flex-wrap items-center gap-3">
            <Link
              to="/signin"
              className="inline-flex items-center gap-2 rounded-full bg-accent px-6 py-3 text-sm font-semibold text-surface transition-transform active:scale-[0.98]"
            >
              Start exploring
              <ArrowRight className="size-4" aria-hidden="true" />
            </Link>
            <a
              href="#features"
              className="rounded-full px-6 py-3 text-sm font-medium text-ink ring-1 ring-line transition-colors hover:bg-soft"
            >
              See the modules
            </a>
          </div>
          <dl className="mt-9 grid max-w-md grid-cols-3 gap-4">
            {[
              ["9", "modules, one database"],
              ["£", "minor-unit money, no floats"],
              ["100%", "audited actions"],
            ].map(([stat, label]) => (
              <div key={label}>
                <dt className="sr-only">{label}</dt>
                <dd className="font-display text-2xl font-medium text-brand">{stat}</dd>
                <dd className="mt-1 text-xs leading-snug text-ink/60">{label}</dd>
              </div>
            ))}
          </dl>
        </div>
        <figure className="relative">
          <img
            src={warehouseImg}
            alt="Illustration of a British distribution warehouse with the London skyline beyond the windows"
            className="w-full rounded-2xl ring-1 ring-black/5"
            width={1280}
            height={960}
          />
          <figcaption className="absolute bottom-3 left-3 flex items-center gap-1.5 rounded-full bg-surface/90 px-3 py-1.5 text-xs font-medium text-ink shadow-sm ring-1 ring-black/5 backdrop-blur">
            <MapPin className="size-3 text-accent" aria-hidden="true" />
            Goods in, Midlands distribution centre
          </figcaption>
        </figure>
      </div>
    </section>
  );
}

/* ------------------------------------------------------------------ */

type Feature = { icon: LucideIcon; title: string; body: string };

const JOURNEY: Feature[] = [
  {
    icon: TrendingUp,
    title: "Plan",
    body: "Stock forecasts built on real usage and measured supplier lead times, with reorder points that raise the order for you.",
  },
  {
    icon: FileText,
    title: "Source",
    body: "Requisitions approved and converted straight into purchase orders, with three-way match and delivery tolerances on receipt.",
  },
  {
    icon: Factory,
    title: "Make",
    body: "Works orders, bills of materials and backflushing, with quality inspections gating what reaches stock.",
  },
  {
    icon: Boxes,
    title: "Store",
    body: "Aisles, shelves and bins with storage rules, so put away and picking always land in the right place. Counted, valued to the penny.",
  },
  {
    icon: Truck,
    title: "Move",
    body: "Shipments, proof of delivery, landed cost and duty, and full batch traceability for recalls.",
  },
  {
    icon: PackageCheck,
    title: "Sell",
    body: "Quotations, customer orders, pick-and-despatch waves and release rules that respect credit holds.",
  },
  {
    icon: PoundSterling,
    title: "Settle",
    body: "Supplier bills matched to goods received, payment runs, customer invoicing, cash application and VAT-ready postings.",
  },
];

const GOVERNANCE: Feature[] = [
  {
    icon: ShieldCheck,
    title: "Governance by default",
    body: "Master-data changes travel through change requests with previews and approval — no silent edits.",
  },
  {
    icon: Scale,
    title: "Segregation of duties",
    body: "The person who despatches goods cannot invoice them. The database enforces it, not the handbook.",
  },
  {
    icon: Vault,
    title: "Per-tenant encryption",
    body: "Each company's keys live in a vault and can be rotated — or irreversibly destroyed on offboarding.",
  },
  {
    icon: ClipboardCheck,
    title: "Audit everything",
    body: "An append-only trail of every submission, decision and posting, filterable by tenant, user and object.",
  },
];

function FeatureCard({ icon: Icon, title, body }: Feature) {
  return (
    <div className="rounded-2xl border border-line bg-surface p-5 ring-1 ring-black/5">
      <div className="grid size-10 place-items-center rounded-xl bg-accent/10 text-accent">
        <Icon className="size-5" aria-hidden="true" />
      </div>
      <h3 className="mt-4 font-display text-base font-semibold text-brand">{title}</h3>
      <p className="mt-1.5 text-sm leading-relaxed text-ink/65 text-pretty">{body}</p>
    </div>
  );
}

function Features() {
  return (
    <section className="py-12" id="features" aria-labelledby="features-heading">
      <p className="text-[11px] font-semibold uppercase tracking-[0.18em] text-accent">
        The operating journey
      </p>
      <h2
        id="features-heading"
        className="mt-3 max-w-[24ch] font-display text-3xl font-medium leading-tight text-brand text-balance md:text-4xl"
      >
        From forecast to bank statement, without leaving the system.
      </h2>
      <div className="mt-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
        {JOURNEY.map((f) => (
          <FeatureCard key={f.title} {...f} />
        ))}
        <div className="relative overflow-hidden rounded-2xl border border-line ring-1 ring-black/5">
          <img
            src={financeImg}
            alt="Illustration of a British finance desk with ledgers, pound coins and a cup of tea"
            className="h-full w-full object-cover"
            loading="lazy"
            width={1280}
            height={960}
          />
          <p className="absolute bottom-3 left-3 flex items-center gap-1.5 rounded-full bg-surface/90 px-3 py-1.5 text-xs font-medium text-ink shadow-sm ring-1 ring-black/5 backdrop-blur">
            <Banknote className="size-3 text-accent" aria-hidden="true" />
            Month-end, closed by tea time
          </p>
        </div>
      </div>
    </section>
  );
}

function Governance() {
  return (
    <section className="py-12" aria-labelledby="governance-heading">
      <div className="rounded-3xl bg-brand p-6 text-surface md:p-10">
        <p className="text-[11px] font-semibold uppercase tracking-[0.18em] text-surface/70">
          Govern &amp; assure
        </p>
        <h2
          id="governance-heading"
          className="mt-3 max-w-[26ch] font-display text-3xl font-medium leading-tight text-balance"
        >
          Controls your auditor will actually enjoy reading.
        </h2>
        <div className="mt-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          {GOVERNANCE.map(({ icon: Icon, title, body }) => (
            <div key={title} className="rounded-2xl bg-surface/10 p-5 ring-1 ring-surface/15">
              <Icon className="size-5 text-accent-soft" aria-hidden="true" />
              <h3 className="mt-3 font-display text-sm font-semibold">{title}</h3>
              <p className="mt-1.5 text-sm leading-relaxed text-surface/75">{body}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

/* ------------------------------------------------------------------ */

function UkStrip() {
  const items = [
    { icon: PoundSterling, label: "HMRC Making Tax Digital ready" },
    { icon: Landmark, label: "Companies House-style entity structure" },
    { icon: ShieldCheck, label: "UK GDPR & ICO-aligned data handling" },
    { icon: RouteIcon, label: "Multi-site across the UK and beyond" },
  ];
  return (
    <section className="py-10" aria-label="UK compliance">
      <div className="flex flex-wrap items-center justify-center gap-x-10 gap-y-4 rounded-2xl border border-dashed border-line bg-soft/40 px-6 py-6">
        {items.map(({ icon: Icon, label }) => (
          <p key={label} className="flex items-center gap-2 text-sm font-medium text-ink/70">
            <Icon className="size-4 text-accent" aria-hidden="true" />
            {label}
          </p>
        ))}
      </div>
    </section>
  );
}

type Shot = { src: string; alt: string; icon: LucideIcon; caption: string; label: string };

const SHOTS: Shot[] = [
  {
    src: shotFinance,
    alt: "Clove ERP Finance module showing the trial balance, receivables ageing and slow-moving stock provision",
    icon: PoundSterling,
    label: "Finance",
    caption:
      "Trial balance, receivables ageing and provisions — every figure traces to a posted document.",
  },
  {
    src: shotWarehouse,
    alt: "Clove ERP warehouse workbench showing goods in, put away, move and count with a searchable receipt list",
    icon: Boxes,
    label: "Warehouse workbench",
    caption:
      "Pick a step, pick a record: goods in, put away, move and count, with batch and expiry on every line.",
  },
  {
    src: shotForecast,
    alt: "Clove ERP stock forecast listing usage per day, lead time, reorder point and days of cover with an order button per product",
    icon: TrendingUp,
    label: "Stock forecast",
    caption:
      "Usage, measured supplier lead times and reorder points — with a purchase order one click away.",
  },
];

function Gallery() {
  return (
    <section className="py-12" aria-labelledby="gallery-heading">
      <p className="text-[11px] font-semibold uppercase tracking-[0.18em] text-accent">
        Inside the product
      </p>
      <h2
        id="gallery-heading"
        className="mt-3 max-w-[24ch] font-display text-3xl font-medium leading-tight text-brand text-balance md:text-4xl"
      >
        Calm screens for busy days.
      </h2>
      <div className="mt-8 grid gap-4 md:grid-cols-3">
        {SHOTS.map(({ src, alt, icon: Icon, label, caption }) => (
          <figure
            key={label}
            className="overflow-hidden rounded-2xl border border-line bg-surface ring-1 ring-black/5"
          >
            <img src={src} alt={alt} className="w-full" loading="lazy" width={1440} height={900} />
            <figcaption className="p-5">
              <p className="flex items-center gap-2 font-display text-sm font-semibold text-brand">
                <Icon className="size-4 text-accent" aria-hidden="true" />
                {label}
              </p>
              <p className="mt-1.5 text-sm leading-relaxed text-ink/65 text-pretty">{caption}</p>
            </figcaption>
          </figure>
        ))}
      </div>
    </section>
  );
}

function Pricing() {
  return (
    <section className="py-12" id="pricing" aria-labelledby="pricing-heading">
      <div className="relative overflow-hidden rounded-3xl bg-accent p-8 text-surface md:p-10">
        <div
          className="absolute top-0 right-0 size-48 rounded-full bg-white/5 -mr-20 -mt-20 blur-2xl"
          aria-hidden="true"
        />
        <div className="relative grid items-center gap-8 md:grid-cols-2">
          <div>
            <p className="text-[11px] font-semibold uppercase tracking-[0.18em] text-surface/80">
              Fair, British pricing
            </p>
            <h2
              id="pricing-heading"
              className="mt-3 font-display text-3xl font-medium leading-tight md:text-4xl"
            >
              From £25 per seat, per month.
            </h2>
            <p className="mt-3 max-w-[42ch] text-sm leading-relaxed text-surface/85 text-pretty">
              Every module included. Billed in sterling, VAT invoice supplied, no per-transaction
              tolls. Cancel at month-end — your data exports with you.
            </p>
          </div>
          <div className="flex flex-col gap-3">
            <Link
              to="/signin"
              className="rounded-full bg-surface px-6 py-3.5 text-center text-sm font-semibold text-accent ring-2 ring-surface/20 transition-transform active:scale-[0.98]"
            >
              Start exploring with demo data
            </Link>
            <Link
              to="/contact"
              className="rounded-full px-6 py-3.5 text-center text-sm font-medium text-surface ring-1 ring-surface/40 transition-colors hover:bg-surface/10"
            >
              Book a walkthrough
            </Link>
          </div>
        </div>
      </div>
    </section>
  );
}

function Footer() {
  return (
    <footer className="flex flex-col items-center gap-4 py-12 text-center">
      <Logo size={32} />
      <p className="text-[11px] font-medium uppercase tracking-widest text-ink/40">
        Built for precision in the United Kingdom · Clove ERP MMXXVI
      </p>
      <p className="flex flex-wrap items-center justify-center gap-x-4 gap-y-2 text-xs text-ink/50">
        <Link to="/contact" className="underline underline-offset-2">
          Contact us
        </Link>
        <Link to="/signin" className="underline underline-offset-2">
          Sign in
        </Link>
      </p>
    </footer>
  );
}

function ProductPage() {
  return (
    <div className="min-h-screen bg-surface font-sans text-ink antialiased">
      <div className="mx-auto max-w-6xl px-5 md:px-8">
        <Nav />
        <Hero />
        <Features />
        <UkStrip />
        <Governance />
        <Gallery />
        <Pricing />
        <Footer />
      </div>
    </div>
  );
}
