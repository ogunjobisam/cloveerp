import { createFileRoute, Link } from "@tanstack/react-router";

import { CONTACT_EMAIL } from "../lib/brand";
import { Logo, Wordmark } from "../components/erp/logo";

/**
 * The privacy policy on cloveerp.com.
 *
 * Marketing copy, so it is plain English rather than ui() — the terminology
 * layer renames the product's words for a tenant, and a visitor who has not
 * signed in has no tenant to rename anything. /contact and /product are
 * written the same way.
 *
 * Every claim here is one the code keeps, so the page does not drift from the
 * product: the analytics are Cloudflare's cookieless Web Analytics
 * (src/lib/content-security-policy.ts names the only two analytics hosts the
 * site contacts); the fonts are served from the application itself (#516, so
 * the browser calls no font host); the contact form stores what it is given,
 * hashes the caller's address with a secret salt for a per-hour rate limit and
 * stores only the digest, emails staff through Resend and subscribes to the
 * follow-up list only on an explicit opt-in (supabase/functions/enquiry); and
 * the application's sign-in is Supabase with no public sign-up
 * (disable_signup). If one of those changes, this page changes with it.
 *
 * The data controller is named by e-mail for now, at the owner's direction;
 * registered company details can be added here later without touching anything
 * else.
 */

export const Route = createFileRoute("/privacy")({
  head: () => ({
    meta: [
      { title: "Privacy — Clove ERP" },
      {
        name: "description",
        content:
          "How Clove ERP handles your data: cookieless analytics, self-hosted fonts, the contact form, and your rights.",
      },
      { property: "og:title", content: "Privacy — Clove ERP" },
      {
        property: "og:description",
        content:
          "How Clove ERP handles your data: cookieless analytics, self-hosted fonts, the contact form, and your rights.",
      },
      { property: "og:type", content: "website" },
      { property: "og:url", content: "https://cloveerp.com/privacy" },
    ],
    links: [{ rel: "canonical", href: "https://cloveerp.com/privacy" }],
  }),
  component: PrivacyPage,
});

const H2 = "font-display text-xl font-medium text-ink";
const P = "mt-2 max-w-[62ch] text-sm leading-relaxed text-ink/75 text-pretty";
const SECTION = "pt-8";

function MailLink() {
  return (
    <a href={`mailto:${CONTACT_EMAIL}`} className="underline underline-offset-2 hover:text-ink">
      {CONTACT_EMAIL}
    </a>
  );
}

function PrivacyPage() {
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
            Privacy
          </h1>
          <p className="mt-3 max-w-[58ch] text-sm leading-relaxed text-ink/70 text-pretty">
            This explains what Clove ERP collects, why, and what you can ask us to do about it. It
            is written to match what our software actually does, in plain English.
          </p>
          <p className="mt-3 text-xs font-medium uppercase tracking-widest text-ink/40">
            Last updated 14 October 2026
          </p>
        </header>

        <main className="pb-4">
          <section className={SECTION}>
            <h2 className={H2}>Who we are</h2>
            <p className={P}>
              Clove ERP provides this website and the Clove ERP application. We decide how the
              personal data described here is handled. To reach us about anything on this page —
              including a request to see or delete the data we hold about you — write to{" "}
              <MailLink />.
            </p>
          </section>

          <section className={SECTION}>
            <h2 className={H2}>When you browse this website</h2>
            <p className={P}>
              We use Cloudflare Web Analytics to understand how this website is used — which pages
              are visited, roughly where visitors come from, and how the site performs. This is
              privacy-first analytics: it does not use cookies, it does not fingerprint your device
              or browser, and it does not track you across other websites. The measurements are
              aggregated and cannot be used to identify you.
            </p>
            <p className={P}>
              To collect them, a small Cloudflare script runs on each page and sends anonymous
              measurements to Cloudflare, which processes them on our behalf. We do not sell this
              data and we do not use it for advertising.
            </p>
          </section>

          <section className={SECTION}>
            <h2 className={H2}>Fonts and other third parties</h2>
            <p className={P}>
              The typefaces on this website are served from Clove ERP itself. Your browser does not
              request fonts from Google Fonts or any other font service, so no font provider
              receives your address when you visit.
            </p>
            <p className={P}>
              When you simply browse, your browser contacts only Cloudflare, which hosts this site
              and provides the analytics above. If you use the contact form, your message is also
              handled by our email provider (below). We do not embed third-party advertising,
              social-media or tracking scripts.
            </p>
          </section>

          <section className={SECTION}>
            <h2 className={H2}>When you contact us</h2>
            <p className={P}>
              When you send a message through our contact form, we collect the name, email address
              and message you give us, and, if you provide them, your organisation and a note of
              which page you came from. We use these only to read and reply to your enquiry.
            </p>
            <p className={P}>
              To stop automated abuse of the form, we keep a one-way, salted fingerprint of your
              network address for a short time — enough to tell that a single sender has submitted
              the form many times in an hour. We do not store your network address itself, and the
              fingerprint cannot be turned back into it.
            </p>
            <p className={P}>
              Your enquiry is stored securely and emailed to our team through our email provider,
              Resend, which processes it on our behalf. The form also offers an optional tick-box to
              hear more from us: we add you to that follow-up list only if you tick it, and you can
              unsubscribe at any time. If you do not tick it, we use your details only to answer
              your enquiry.
            </p>
          </section>

          <section className={SECTION}>
            <h2 className={H2}>When you use the application</h2>
            <p className={P}>
              When your organisation uses the Clove ERP application, signing in is handled by our
              platform provider, Supabase, which processes your sign-in data on our behalf. Your
              session is kept in your browser so you stay signed in; it is not shared with other
              websites. Accounts are created by your organisation&rsquo;s administrators — the
              application does not offer public sign-up.
            </p>
            <p className={P}>
              The business records your organisation keeps in the application belong to your
              organisation, which decides how they are used; we hold them to run the service. If you
              are a user of a customer&rsquo;s system and want to see or correct your details,
              please ask that organisation, which can also ask us.
            </p>
          </section>

          <section className={SECTION}>
            <h2 className={H2}>How long we keep things</h2>
            <p className={P}>
              We keep enquiries only as long as we need them to deal with your request and our
              ordinary business records. Analytics are aggregated and hold nothing that identifies
              you. The salted fingerprint from the contact form is short-lived, kept only for the
              rate limit.
            </p>
          </section>

          <section className={SECTION}>
            <h2 className={H2}>Your rights</h2>
            <p className={P}>
              You can ask us to see the personal data we hold about you, to correct it, or to delete
              it, and you can withdraw consent to the follow-up list at any time. Write to{" "}
              <MailLink /> and we will respond. If you are in the UK or the EU and are not satisfied
              with our response, you can complain to your data protection regulator.
            </p>
          </section>

          <section className={SECTION}>
            <h2 className={H2}>Changes to this page</h2>
            <p className={P}>
              When what we do changes, we change this page and update the date at the top. The
              current version is always the one you are reading here.
            </p>
          </section>
        </main>

        <footer className="mt-12 flex flex-col items-center gap-4 border-t border-ink/10 py-10 text-center">
          <p className="text-xs text-ink/60">
            Questions about your data? Write to <MailLink />.
          </p>
          <p className="text-[11px] font-medium uppercase tracking-widest text-ink/40">
            Built for precision in the United Kingdom · Clove ERP MMXXVI
          </p>
        </footer>
      </div>
    </div>
  );
}
