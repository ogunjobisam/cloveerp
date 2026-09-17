import { createFileRoute, Link } from "@tanstack/react-router";
import type { ReactNode } from "react";
import {
  ArrowRight,
  Banknote,
  Boxes,
  Check,
  ChevronDown,
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
            "@type": "AggregateOffer",
            lowPrice: "395",
            priceCurrency: "GBP",
            offerCount: 3,
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
              to="/contact"
              className="inline-flex items-center gap-2 rounded-full bg-accent px-6 py-3 text-sm font-semibold text-surface transition-transform active:scale-[0.98]"
            >
              Book a demo
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
              ["240+", "checks pass before any release ships"],
              ["£395", "a month to start, priced on this page"],
              ["100%", "of actions audited, and your data exports with you"],
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

/* ------------------------------------------------------------------ */

/**
 * The price list, as the platform owner set it on 14 September 2026.
 *
 * One price for the organisation with a core team included, rather than a
 * rate per seat: a requisition approver and a production planner are not the
 * same cost to serve, and "£25 per seat" priced a whole ERP below the tools it
 * replaces. Organisations come by invitation, so every call to action here
 * leads to a conversation (/contact), never to a sign-up the product refuses.
 *
 * Pounds a month, billed annually, excluding VAT. The platform's own price
 * book carries the same figures; this page is what a visitor reads before
 * anybody has quoted them.
 */
type Plan = {
  name: string;
  audience: string;
  price: string;
  from?: boolean;
  modules: string;
  terms: [string, string][];
  featured?: boolean;
};

const PLANS: Plan[] = [
  {
    name: "Starter",
    audience: "One company and one site, moving off spreadsheets and bolt-on stock tools.",
    price: "£395",
    modules:
      "Purchasing, stock, sales and the ledger, with segregation of duties and a full audit trail.",
    terms: [
      ["Full users included", "5, up to 10"],
      ["Each extra full user", "£45"],
      ["Each light user", "£9"],
      ["Companies · sites", "1 · 1"],
    ],
  },
  {
    name: "Standard",
    audience: "Manufacturers and distributors running several sites.",
    price: "£1,095",
    modules:
      "Everything in Starter, plus manufacturing, MRP planning and forecasting, batch and expiry traceability, quality and recall, stock counts, landed cost and returns.",
    terms: [
      ["Full users included", "15, up to 100"],
      ["Each extra full user", "£49"],
      ["Each light user", "£9"],
      ["Companies · sites", "3 · 10"],
    ],
    featured: true,
  },
  {
    name: "Enterprise",
    audience: "Groups with several companies, regulated goods or trading between entities.",
    price: "£2,750",
    from: true,
    modules:
      "Everything in Standard, plus multi-company and intercompany trading, serial numbers, container tracking, project accounting and more sandbox environments.",
    terms: [
      ["Full users included", "40, no limit"],
      ["Each extra full user", "£45"],
      ["Each light user", "£6"],
      ["Companies · sites", "No limit"],
    ],
  },
];

const GETTING_STARTED: [string, string, string][] = [
  [
    "Guided onboarding",
    "£2,500",
    "Set-up interview, your products and partners imported, opening balances and two training sessions.",
  ],
  [
    "Standard implementation",
    "£7,500",
    "Guided onboarding plus warehouse layout, approval limits, document templates and five days of support.",
  ],
  [
    "Moving from another system",
    "Quoted",
    "Sage 200, NetSuite or several companies at once, priced once we have seen your data.",
  ],
];

const SUPPORT: [string, string, string][] = [
  ["Standard", "Included", "Email support in UK business hours."],
  ["Priority", "10% of subscription", "Four-hour response and a named contact, from £150 a month."],
  [
    "Premier",
    "Enterprise",
    "Telephone support, one-hour response to critical issues, quarterly review.",
  ],
];

function PlanCard({ plan }: { plan: Plan }) {
  return (
    <article
      className={
        "flex flex-col rounded-2xl border bg-surface p-6 " +
        (plan.featured ? "border-accent ring-2 ring-accent/25" : "border-line ring-1 ring-black/5")
      }
      aria-labelledby={`plan-${plan.name}`}
    >
      <h3 id={`plan-${plan.name}`} className="font-display text-xl font-semibold text-brand">
        {plan.name}
      </h3>
      <p className="mt-1.5 min-h-[3lh] text-sm leading-relaxed text-ink/65 text-pretty">
        {plan.audience}
      </p>
      <p className="mt-4 flex items-baseline gap-1.5">
        {plan.from ? <span className="text-sm text-ink/60">from</span> : null}
        <span className="font-display text-4xl font-medium tabular-nums text-brand">
          {plan.price}
        </span>
        <span className="text-sm text-ink/60">a month</span>
      </p>
      <p className="mt-1 text-xs text-ink/50">Billed annually, excluding VAT</p>
      <dl className="mt-5 divide-y divide-line border-y border-line text-sm">
        {plan.terms.map(([term, value]) => (
          <div key={term} className="flex items-baseline justify-between gap-4 py-2">
            <dt className="text-ink/65">{term}</dt>
            <dd className="font-medium tabular-nums text-ink">{value}</dd>
          </div>
        ))}
      </dl>
      <p className="mt-5 flex gap-2 text-sm leading-relaxed text-ink/75 text-pretty">
        <Check className="mt-0.5 size-4 shrink-0 text-accent" aria-hidden="true" />
        {plan.modules}
      </p>
    </article>
  );
}

function PriceTable({ caption, rows }: { caption: string; rows: [string, string, string][] }) {
  return (
    <div>
      <h3 className="font-display text-base font-semibold text-brand">{caption}</h3>
      <dl className="mt-3 divide-y divide-line border-y border-line">
        {rows.map(([name, price, body]) => (
          <div key={name} className="grid gap-1 py-3 sm:grid-cols-[1fr_auto] sm:gap-x-6">
            <dt className="text-sm font-medium text-ink">{name}</dt>
            <dd className="text-sm font-medium tabular-nums text-brand sm:text-right">{price}</dd>
            <dd className="text-sm leading-relaxed text-ink/65 text-pretty sm:col-span-2">
              {body}
            </dd>
          </div>
        ))}
      </dl>
    </div>
  );
}

function Pricing() {
  return (
    <section className="py-12" id="pricing" aria-labelledby="pricing-heading">
      <p className="text-[11px] font-semibold uppercase tracking-[0.18em] text-accent">
        Fair, British pricing
      </p>
      <h2
        id="pricing-heading"
        className="mt-3 max-w-[26ch] font-display text-3xl font-medium leading-tight text-brand text-balance md:text-4xl"
      >
        One price for your organisation, with your core team included.
      </h2>
      <p className="mt-4 max-w-[62ch] text-base leading-relaxed text-ink/70 text-pretty">
        Add people as you grow. Light users — people who look at reports, count stock, use the
        scanner or approve a product or supplier record — cost a fraction of a full user. Approving
        an order, a payment or a discount commits money, so that is a full user. No per-transaction
        fees, and your data always exports with you.
      </p>

      <div className="mt-8 grid gap-4 md:grid-cols-3">
        {PLANS.map((plan) => (
          <PlanCard key={plan.name} plan={plan} />
        ))}
      </div>

      <div className="mt-10 grid gap-8 md:grid-cols-2">
        <PriceTable caption="Getting started" rows={GETTING_STARTED} />
        <PriceTable caption="Support" rows={SUPPORT} />
      </div>

      <p className="mt-6 max-w-[80ch] text-xs leading-relaxed text-ink/55 text-pretty">
        All prices in pounds sterling, excluding VAT, with a VAT invoice. Plans are billed annually;
        month-to-month billing adds 15%, and two- and three-year terms save 10% and 15%. An extra
        company is £150 and an extra site £75 a month. Renewal increases are capped at CPI or 5%,
        whichever is lower.
      </p>

      <div className="relative mt-10 overflow-hidden rounded-3xl bg-accent p-8 text-surface md:p-10">
        <div
          className="absolute top-0 right-0 size-48 rounded-full bg-white/5 -mr-20 -mt-20 blur-2xl"
          aria-hidden="true"
        />
        <div className="relative grid items-center gap-8 md:grid-cols-2">
          <div>
            <p className="text-[11px] font-semibold uppercase tracking-[0.18em] text-surface/80">
              Founding customers
            </p>
            <h3 className="mt-3 font-display text-3xl font-medium leading-tight text-balance md:text-4xl">
              35% off your first two years.
            </h3>
            <p className="mt-3 max-w-[46ch] text-sm leading-relaxed text-surface/85 text-pretty">
              We are taking a small number of founding customers. In return for a case study, a
              monthly feedback call and being a reference, your plan is 35% off for 24 months.
            </p>
          </div>
          <div className="flex flex-col gap-3">
            <Link
              to="/contact"
              className="rounded-full bg-surface px-6 py-3.5 text-center text-sm font-semibold text-accent ring-2 ring-surface/20 transition-transform active:scale-[0.98]"
            >
              Book a demo
            </Link>
            <p className="text-center text-sm leading-relaxed text-surface/85 text-pretty">
              Not ready to commit? Run a 30-day pilot on your own data for £500, credited against
              your first year.
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}

type Question = { q: string; a: ReactNode };

/**
 * What people ask before they buy, answered where they ask it.
 *
 * Every answer is something the product does today: the prices are the ones
 * on the page above, the checks are the ones the build runs, and the support
 * session an answer describes is the one an organisation can see for itself.
 * An answer that outran the product would be found out in the first demo.
 */
const QUESTIONS: Question[] = [
  {
    q: "What does it cost?",
    a: (
      <>
        Starter is £395 a month, Standard £1,095 and Enterprise from £2,750, billed annually and
        excluding VAT. Each includes a core team — 5, 15 and 40 full users — and extra people are
        priced above. Month-to-month adds 15%. Founding customers pay 35% less for two years. The
        prices are here because you should not have to ask a salesperson what something costs.
      </>
    ),
  },
  {
    q: "How long does it take to set up?",
    a: (
      <>
        It is an interview, not a project. You answer questions about how your business works — what
        you make or sell, how you count stock, who approves what — and Clove ERP configures the
        chart of accounts, document types, numbering and controls to match. You can explore a
        demonstration company with a month of trading behind it before you commit a single figure of
        your own.
      </>
    ),
  },
  {
    q: "Who is it for?",
    a: (
      <>
        British product businesses: manufacturers, distributors and food producers running one to
        three companies and several sites, where between five and fifty people need the system.
        Batch traceability, quality release, planning and MRP are in the Standard plan, not an
        upgrade. If you need dozens of legal entities in dozens of countries, you want a bigger
        system than this one.
      </>
    ),
  },
  {
    q: "Can we get our data out?",
    a: (
      <>
        Yes, whenever you like. Reports and registers export to open formats from the screens
        themselves, and the data belongs to you. If you ask for your organisation to be deleted, it
        is suspended first, and the deletion removes every row belonging to it.
      </>
    ),
  },
  {
    q: "Who can see our data?",
    a: (
      <>
        Every organisation is separated by the database itself, not by a filter in the screens, and
        that separation is proved on every release. Nobody at Clove ERP can look inside your
        organisation without opening a support session, which names a reason, expires by itself and
        appears on your own continuity screen while it is open.
      </>
    ),
  },
  {
    q: "How do you know a release is sound?",
    a: (
      <>
        Every release builds the whole database from nothing and runs more than 240 checks against
        it: that no organisation can read another's rows, that every action is audited, that every
        permission the screens name exists, and that each refusal tells you what to do next. A check
        that is not run fails the build.
      </>
    ),
  },
  {
    q: "What if we outgrow the plan?",
    a: (
      <>
        Move up a plan and keep your data where it is: the plan sets what is switched on and how
        many people are included, not where anything lives. If you outgrow Clove ERP itself, your
        data still exports with you, which is the point of saying so twice.
      </>
    ),
  },
  {
    q: "How do we start?",
    a: (
      <>
        Book a demo and we will walk through your own processes in a demonstration company. If you
        would rather try it properly, run a 30-day pilot on your own data for £500, credited against
        your first year.
      </>
    ),
  },
];

function Faq() {
  return (
    <section className="py-12" id="questions" aria-labelledby="faq-heading">
      <p className="text-[11px] font-semibold uppercase tracking-[0.18em] text-accent">
        Before you ask
      </p>
      <h2
        id="faq-heading"
        className="mt-3 max-w-[26ch] font-display text-3xl font-medium leading-tight text-brand text-balance md:text-4xl"
      >
        The questions we are asked most.
      </h2>
      <div className="mt-8 grid gap-3 md:grid-cols-2">
        {QUESTIONS.map((item) => (
          <details
            key={item.q}
            className="group rounded-2xl bg-soft/60 p-5 ring-1 ring-line open:bg-soft"
          >
            <summary className="flex cursor-pointer items-center justify-between gap-4 font-display text-lg font-medium text-brand marker:content-['']">
              {item.q}
              <ChevronDown
                className="size-4 shrink-0 text-ink/50 transition-transform group-open:rotate-180"
                aria-hidden="true"
              />
            </summary>
            <p className="mt-3 text-sm leading-relaxed text-ink/70 text-pretty">{item.a}</p>
          </details>
        ))}
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
        <Faq />
        <Footer />
      </div>
    </div>
  );
}
