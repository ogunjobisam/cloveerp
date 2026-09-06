import { createFileRoute, Link } from "@tanstack/react-router";
import { useRef, useState } from "react";

import { CONTACT_EMAIL } from "../lib/brand";
import { supabasePublishableKey, supabaseUrl } from "../lib/erp";
import { Logo, Wordmark } from "../components/erp/logo";

/**
 * The contact form on cloveerp.com.
 *
 * Marketing copy, so it is plain English rather than ui() — the terminology
 * layer renames the product's words for a tenant, and a visitor who has not
 * signed in has no tenant to rename anything. /product is written the same way.
 *
 * The form posts to the enquiry Edge Function, which stores the enquiry and
 * then emails whoever erp_meta.platform_staff says should hear about it. Those
 * are two outcomes, not one, and this screen says which happened: an enquiry
 * that was recorded but could not be emailed shows the address in the footer
 * rather than a tick, because the one thing this page must never do is tell
 * somebody they have been heard when nobody has been told.
 */

export const Route = createFileRoute("/contact")({
  head: () => ({
    meta: [
      { title: "Contact Clove ERP — talk to us about your operation" },
      {
        name: "description",
        content:
          "Tell us what you run and what is not working. We read every enquiry and reply from the UK, usually within one working day.",
      },
      { property: "og:title", content: "Contact Clove ERP" },
      {
        property: "og:description",
        content:
          "Tell us what you run and what is not working. We read every enquiry and reply from the UK.",
      },
      { property: "og:type", content: "website" },
      { property: "og:url", content: "https://cloveerp.com/contact" },
      { property: "og:image", content: "https://cloveerp.com/og-image.png" },
      { name: "twitter:card", content: "summary_large_image" },
      { name: "twitter:image", content: "https://cloveerp.com/og-image.png" },
    ],
    links: [{ rel: "canonical", href: "https://cloveerp.com/contact" }],
  }),
  component: ContactPage,
});

const FIELD =
  "mt-1.5 min-h-11 w-full rounded-lg border border-ink/15 bg-surface px-3.5 py-2.5 text-sm text-ink " +
  "outline-none transition-colors placeholder:text-ink/35 focus-visible:border-accent " +
  "focus-visible:ring-2 focus-visible:ring-accent/30";

const LABEL = "text-sm font-medium text-ink";

type Outcome =
  | { kind: "idle" }
  | { kind: "sending" }
  /** Stored and emailed. */
  | { kind: "answered" }
  /** Stored, and the email did not go. Said plainly rather than dressed as success. */
  | { kind: "recorded_only" }
  | { kind: "refused"; message: string; field: string | null };

/**
 * What the page shows, given what the function said.
 *
 * Pulled out and exported because it is the only decision on this screen that
 * can be wrong in a way that matters: `notified` false means the enquiry is
 * stored and nobody has been told, and treating that as success is exactly the
 * failure the whole feature is built around. A conditional buried in JSX is one
 * nothing can test.
 */
export function outcomeFor(
  ok: boolean,
  payload: { error?: string; field?: string; notified?: boolean },
): Outcome {
  if (!ok) {
    return {
      kind: "refused",
      field: payload.field ?? null,
      message: payload.error ?? "That could not be sent. Please try again.",
    };
  }
  // Anything other than an explicit true is treated as "nobody was told".
  // A missing field is not permission to claim a delivery.
  return { kind: payload.notified === true ? "answered" : "recorded_only" };
}

function endpoint(): string | null {
  // The same resolution the rest of the application uses: the environment
  // where the host sets it, the build's own project otherwise. Reading the
  // variable directly here is what left this form telling visitors it could
  // not reach us on a build whose host set nothing.
  return supabaseUrl ? `${supabaseUrl.replace(/\/$/, "")}/functions/v1/enquiry` : null;
}

function ContactPage() {
  const [outcome, setOutcome] = useState<Outcome>({ kind: "idle" });
  const formRef = useRef<HTMLFormElement>(null);

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = event.currentTarget;
    const data = new FormData(form);
    const url = endpoint();

    if (!url) {
      setOutcome({
        kind: "refused",
        field: null,
        message: "This form is not configured to reach us. Please use the address below.",
      });
      return;
    }

    setOutcome({ kind: "sending" });

    try {
      const response = await fetch(url, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          // Sent when it exists. The function itself does not verify a JWT —
          // the caller has no session — but the Supabase gateway is happier
          // with a key present, and this one is publishable by definition.
          ...(supabasePublishableKey ? { apikey: supabasePublishableKey } : {}),
        },
        body: JSON.stringify({
          full_name: data.get("full_name"),
          email: data.get("email"),
          organisation: data.get("organisation"),
          message: data.get("message"),
          company_website: data.get("company_website"),
          source_page: "/contact",
        }),
      });

      const payload = (await response.json().catch(() => ({}))) as {
        error?: string;
        field?: string;
        notified?: boolean;
      };

      const next = outcomeFor(response.ok, payload);
      if (next.kind !== "refused") form.reset();
      setOutcome(next);
    } catch {
      setOutcome({
        kind: "refused",
        field: null,
        message: "We could not reach the server. Please try again, or use the address below.",
      });
    }
  }

  return (
    <div className="min-h-screen bg-surface font-sans text-ink antialiased">
      <div className="mx-auto max-w-3xl px-5 md:px-8">
        <nav className="flex items-center justify-between py-6" aria-label="Site">
          <Link to="/product" className="flex items-center gap-2.5">
            <Logo size={28} />
            <Wordmark />
          </Link>
          <Link
            to="/product"
            className="text-sm font-medium text-ink/70 underline underline-offset-4 hover:text-ink"
          >
            Back to the product
          </Link>
        </nav>

        <header className="pt-6 pb-2">
          <h1 className="font-display text-3xl font-medium leading-tight text-ink md:text-4xl">
            Tell us what you run.
          </h1>
          <p className="mt-3 max-w-[52ch] text-sm leading-relaxed text-ink/70 text-pretty">
            Stock, purchasing, production, the ledger — whichever part is costing you time. We read
            every enquiry ourselves and reply from the UK, usually within one working day.
          </p>
        </header>

        {outcome.kind === "answered" ? (
          <Answered />
        ) : outcome.kind === "recorded_only" ? (
          <RecordedOnly />
        ) : (
          <form ref={formRef} onSubmit={submit} className="mt-8 grid gap-5" noValidate>
            {outcome.kind === "refused" ? (
              <p
                role="alert"
                id="enquiry-error"
                className="rounded-lg border border-destructive/30 bg-destructive/5 px-3.5 py-3 text-sm text-destructive"
              >
                {outcome.message}
              </p>
            ) : null}

            <div>
              <label htmlFor="full_name" className={LABEL}>
                Your name
              </label>
              <input
                id="full_name"
                name="full_name"
                type="text"
                required
                autoComplete="name"
                maxLength={120}
                className={FIELD}
                placeholder="Dana Okafor"
                aria-describedby={
                  outcome.kind === "refused" && outcome.field === "full_name"
                    ? "enquiry-error"
                    : undefined
                }
              />
            </div>

            <div>
              <label htmlFor="email" className={LABEL}>
                Email address
              </label>
              <input
                id="email"
                name="email"
                type="email"
                required
                autoComplete="email"
                maxLength={254}
                className={FIELD}
                placeholder="dana@okaforfoods.co.uk"
                aria-describedby={
                  outcome.kind === "refused" && outcome.field === "email"
                    ? "enquiry-error"
                    : undefined
                }
              />
            </div>

            <div>
              <label htmlFor="organisation" className={LABEL}>
                Organisation <span className="font-normal text-ink/50">(optional)</span>
              </label>
              <input
                id="organisation"
                name="organisation"
                type="text"
                autoComplete="organization"
                maxLength={160}
                className={FIELD}
                placeholder="Okafor Foods"
              />
            </div>

            <div>
              <label htmlFor="message" className={LABEL}>
                What would you like to talk about?
              </label>
              <textarea
                id="message"
                name="message"
                required
                rows={6}
                minLength={20}
                maxLength={4000}
                className={FIELD}
                placeholder="We run three sites and need stock, purchasing and the ledger in one place."
                aria-describedby={
                  outcome.kind === "refused" && outcome.field === "message"
                    ? "enquiry-error message-hint"
                    : "message-hint"
                }
              />
              <p id="message-hint" className="mt-1.5 text-xs text-ink/50">
                A couple of sentences is plenty — enough that somebody can answer usefully.
              </p>
            </div>

            {/* A person never sees this, so a person never fills it. One that
                arrives filled is refused rather than quietly discarded: a form
                that answers "thank you" and files nothing is the same lie as
                one that stores and never sends. */}
            <div aria-hidden="true" className="hidden">
              <label htmlFor="company_website" className={LABEL}>
                Leave this field empty
              </label>
              <input
                id="company_website"
                name="company_website"
                type="text"
                tabIndex={-1}
                autoComplete="off"
                aria-label="Leave this field empty"
              />
            </div>

            <div className="flex flex-wrap items-center gap-4 pt-1">
              <button
                type="submit"
                disabled={outcome.kind === "sending"}
                className="min-h-11 rounded-full bg-accent px-6 py-3 text-sm font-semibold text-surface transition-transform active:scale-[0.98] disabled:opacity-60"
              >
                {outcome.kind === "sending" ? "Sending…" : "Send enquiry"}
              </button>
              <p className="text-xs text-ink/50">
                We use what you send here to reply to you, and for nothing else.
              </p>
            </div>
          </form>
        )}

        <footer className="mt-16 flex flex-col items-center gap-4 border-t border-ink/10 py-10 text-center">
          <p className="text-xs text-ink/60">
            Prefer email? Write to{" "}
            <a
              href={`mailto:${CONTACT_EMAIL}`}
              className="underline underline-offset-2 hover:text-ink"
            >
              {CONTACT_EMAIL}
            </a>
            .
          </p>
          <p className="text-[11px] font-medium uppercase tracking-widest text-ink/40">
            Built for precision in the United Kingdom · Clove ERP MMXXVI
          </p>
        </footer>
      </div>
    </div>
  );
}

/** Stored and emailed. The only state that may say somebody has been told. */
function Answered() {
  return (
    <div role="status" className="mt-8 rounded-xl border border-accent/25 bg-accent/5 px-5 py-6">
      <h2 className="font-display text-xl font-medium text-ink">
        Thank you — that has reached us.
      </h2>
      <p className="mt-2 max-w-[52ch] text-sm leading-relaxed text-ink/70 text-pretty">
        Somebody will reply to the address you gave, usually within one working day. If it is
        urgent, write to{" "}
        <a href={`mailto:${CONTACT_EMAIL}`} className="underline underline-offset-2">
          {CONTACT_EMAIL}
        </a>{" "}
        and say so in the subject.
      </p>
    </div>
  );
}

/**
 * Stored, and the email did not go.
 *
 * The enquiry is safe and on the platform console, so this is not an error —
 * but it is not "we will be in touch" either, because at this moment nobody
 * has been told. Saying so, and giving the address that does not depend on any
 * of this working, is the honest version.
 */
function RecordedOnly() {
  return (
    <div role="status" className="mt-8 rounded-xl border border-ink/20 bg-ink/[0.03] px-5 py-6">
      <h2 className="font-display text-xl font-medium text-ink">
        We have your enquiry, but our mail did not go out.
      </h2>
      <p className="mt-2 max-w-[56ch] text-sm leading-relaxed text-ink/70 text-pretty">
        It is saved and somebody will see it. So that you are not waiting on us noticing, please
        also send a line to{" "}
        <a href={`mailto:${CONTACT_EMAIL}`} className="underline underline-offset-2">
          {CONTACT_EMAIL}
        </a>
        . Apologies — that is our fault, not yours.
      </p>
    </div>
  );
}
