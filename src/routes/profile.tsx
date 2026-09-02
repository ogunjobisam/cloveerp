import { useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";

import { friendlyError } from "@/lib/errors";

import { ActionButton, ErrorNote, useErpAction } from "../components/erp/action";
import { Gate } from "../components/erp/gate";
import { PageHeader, Prose, TOUCH } from "../components/erp/page";
import { useErpSession } from "../components/erp/session-context";
import { callErp } from "../lib/erp";
import { useT } from "../lib/i18n";

/**
 * My profile.
 *
 * The one screen in the product a person edits about themselves: their given
 * and family names, the name the product shows for them, and the time zone and
 * languages their screens and documents follow. Nothing here needs a
 * permission: the database checks that the caller is the subject and nobody
 * else, which is the whole of the rule. The names are personal data, so they
 * are in the erasure register like the display name they derive.
 */

export const Route = createFileRoute("/profile")({
  head: () => ({
    meta: [
      { title: "My profile — Clove ERP" },
      { name: "description", content: "Your Clove ERP account, sessions and personal preferences." },
      { property: "og:title", content: "My profile — Clove ERP" },
      { property: "og:description", content: "Your Clove ERP account, sessions and personal preferences." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Profile />
    </Gate>
  ),
});

type Locale = { code: string; name: string };

const FIELD = `${TOUCH} mt-1 w-full rounded-md border border-input bg-background px-3 text-sm`;

function LocaleSelect({
  id,
  label,
  hint,
  value,
  onChange,
  locales,
}: {
  id: string;
  label: string;
  hint: string;
  value: string;
  onChange: (v: string) => void;
  locales: Locale[];
}) {
  const { ui } = useT();
  return (
    <label htmlFor={id} className="block text-sm font-medium">
      {label}
      <select id={id} value={value} onChange={(e) => onChange(e.target.value)} className={FIELD}>
        <option value="">{ui("The organisation's default")}</option>
        {locales.map((l) => (
          <option key={l.code} value={l.code}>
            {l.name} ({l.code})
          </option>
        ))}
      </select>
      <span className="mt-1 block text-xs font-normal text-muted-foreground">{hint}</span>
    </label>
  );
}

function Profile() {
  const { ui } = useT();
  const { session } = useErpSession();
  const queryClient = useQueryClient();
  const me = session.principal;

  const [given, setGiven] = useState(me?.given_name ?? "");
  const [family, setFamily] = useState(me?.family_name ?? "");
  const [display, setDisplay] = useState(me?.display_name ?? "");
  const [timezone, setTimezone] = useState(me?.timezone ?? "");
  const [userLocale, setUserLocale] = useState(me?.user_locale ?? "");
  const [documentLocale, setDocumentLocale] = useState(me?.document_locale ?? "");
  const [reportingLocale, setReportingLocale] = useState(me?.reporting_locale ?? "");
  const [saved, setSaved] = useState(false);

  // The session is the source of truth; when it refreshes after a save, the
  // form follows it rather than keeping what was typed.
  useEffect(() => {
    setGiven(me?.given_name ?? "");
    setFamily(me?.family_name ?? "");
    setDisplay(me?.display_name ?? "");
    setTimezone(me?.timezone ?? "");
    setUserLocale(me?.user_locale ?? "");
    setDocumentLocale(me?.document_locale ?? "");
    setReportingLocale(me?.reporting_locale ?? "");
  }, [me]);

  const locales = useQuery({
    queryKey: ["erp_locales", {}],
    queryFn: () => callErp<Locale[]>("erp_locales", {}),
  });
  const timezones = useQuery({
    queryKey: ["erp_timezones", {}],
    queryFn: () => callErp<string[]>("erp_timezones", {}),
  });

  const save = useErpAction({
    fn: "erp_update_my_profile",
    invalidates: ["erp_session"],
    onDone: () => {
      setSaved(true);
      void queryClient.invalidateQueries({ queryKey: ["erp_session"] });
    },
  });

  const derived = [given.trim(), family.trim()].filter(Boolean).join(" ");
  const displayIsDerived = display.trim() === "" || display.trim() === derived;

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={ui("My profile")}>
        {ui(
          "Your names, the name the product shows for you, and the time zone and languages your screens and documents follow. Only you can change these; an administrator manages what you may do, not who you are.",
        )}
      </PageHeader>

      <form
        onSubmit={(e) => {
          e.preventDefault();
          setSaved(false);
          save.mutate({
            p_given_name: given.trim() || null,
            p_family_name: family.trim() || null,
            p_display_name: displayIsDerived ? null : display.trim(),
            p_timezone: timezone || null,
            p_user_locale: userLocale || null,
            p_document_locale: documentLocale || null,
            p_reporting_locale: reportingLocale || null,
          });
        }}
        className="flex min-w-0 flex-col gap-6"
      >
        <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
          <h2 className="text-sm font-semibold">{ui("Who you are")}</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            {ui(
              "The greeting uses your given name. The display name is what colleagues see beside what you did; it follows your names unless you set it yourself.",
            )}
          </Prose>
          <div className="mt-4 grid gap-4 sm:grid-cols-2">
            <label htmlFor="given" className="block text-sm font-medium">
              {ui("Given name")}
              <input
                id="given"
                value={given}
                onChange={(e) => setGiven(e.target.value)}
                autoComplete="given-name"
                className={FIELD}
              />
            </label>
            <label htmlFor="family" className="block text-sm font-medium">
              {ui("Family name")}
              <input
                id="family"
                value={family}
                onChange={(e) => setFamily(e.target.value)}
                autoComplete="family-name"
                className={FIELD}
              />
            </label>
            <label htmlFor="display" className="block text-sm font-medium sm:col-span-2">
              {ui("Display name")}
              <input
                id="display"
                value={display}
                onChange={(e) => setDisplay(e.target.value)}
                placeholder={derived || undefined}
                autoComplete="name"
                className={FIELD}
              />
              <span className="mt-1 block text-xs font-normal text-muted-foreground">
                {displayIsDerived
                  ? ui("Follows your given and family names.")
                  : ui("Set by you; clear it to follow your names again.")}
              </span>
            </label>
          </div>
          <dl className="mt-4 grid gap-2 text-xs text-muted-foreground sm:grid-cols-2">
            <div>
              <dt className="font-medium uppercase tracking-wide">{ui("Email")}</dt>
              <dd className="mt-0.5">{me?.email ?? "—"}</dd>
            </div>
            <div>
              <dt className="font-medium uppercase tracking-wide">{ui("Organisation")}</dt>
              <dd className="mt-0.5">{session.tenant?.name ?? "—"}</dd>
            </div>
          </dl>
        </section>

        <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
          <h2 className="text-sm font-semibold">{ui("Where and in what language")}</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            {ui(
              "Times are shown in your time zone. Each language falls back to the organisation's default when you leave it unset.",
            )}
          </Prose>
          <div className="mt-4 grid gap-4 sm:grid-cols-2">
            <label htmlFor="timezone" className="block text-sm font-medium sm:col-span-2">
              {ui("Time zone")}
              <select
                id="timezone"
                value={timezone}
                onChange={(e) => setTimezone(e.target.value)}
                className={FIELD}
              >
                <option value="">{ui("The organisation's default")}</option>
                {(timezones.data ?? []).map((z) => (
                  <option key={z} value={z}>
                    {z}
                  </option>
                ))}
              </select>
            </label>
            <LocaleSelect
              id="user-locale"
              label={ui("Screen language")}
              hint={ui("The wording of every screen, including terms your organisation renamed.")}
              value={userLocale}
              onChange={setUserLocale}
              locales={locales.data ?? []}
            />
            <LocaleSelect
              id="document-locale"
              label={ui("Document language")}
              hint={ui("Documents you raise: orders, invoices, delivery notes.")}
              value={documentLocale}
              onChange={setDocumentLocale}
              locales={locales.data ?? []}
            />
            <LocaleSelect
              id="reporting-locale"
              label={ui("Reporting language")}
              hint={ui("Reports and exports you run.")}
              value={reportingLocale}
              onChange={setReportingLocale}
              locales={locales.data ?? []}
            />
          </div>
          {locales.error || timezones.error ? (
            <p role="alert" className="mt-3 text-xs text-destructive">
              {friendlyError(locales.error ?? timezones.error).title}
            </p>
          ) : null}
        </section>

        <div className="flex flex-wrap items-center gap-3">
          <ActionButton type="submit" variant="primary" disabled={save.isPending}>
            {save.isPending ? ui("Saving…") : ui("Save my profile")}
          </ActionButton>
          {saved && !save.isPending && !save.error ? (
            <p role="status" className="text-sm text-ok">
              {ui("Saved. Your screens follow the new settings from the next load.")}
            </p>
          ) : null}
        </div>
        {save.error ? <ErrorNote error={save.error} /> : null}
      </form>
    </div>
  );
}
