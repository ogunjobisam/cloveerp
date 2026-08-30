import { useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";

import { ActionButton, ErrorNote, useErpAction } from "./action";
import { BrandMark } from "./logo";
import { Prose } from "./page";
import { BRAND_DEFAULTS, BRAND_KEYS, useBrand } from "../../lib/brand";
import { useT } from "../../lib/i18n";

/**
 * Tenant branding.
 *
 * The five values below are resource overrides, not a new table: branding is
 * wording plus two colours, and tenant wording already has a governed,
 * tenant-scoped, locale-aware store. Clearing a field removes the override,
 * so "reset to ERPWare" is the absence of a row rather than a second concept.
 */
export function BrandingPanel({ locale = "en" }: { locale?: string }) {
  const brand = useBrand();
  const { resources } = useT();
  const queryClient = useQueryClient();
  const set = useErpAction({ fn: "erp_set_resource_override", invalidates: [] });

  const initial = {
    prefix: resources[BRAND_KEYS.prefix] ?? "",
    suffix: resources[BRAND_KEYS.suffix] ?? "",
    ink: resources[BRAND_KEYS.ink] ?? "",
    total: resources[BRAND_KEYS.total] ?? "",
    logo: resources[BRAND_KEYS.logo] ?? "",
  };

  const [draft, setDraft] = useState(initial);
  const [saved, setSaved] = useState(false);

  // Reload the form when the tenant (and therefore its overrides) changes.
  useEffect(() => {
    setDraft(initial);
    setSaved(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [initial.prefix, initial.suffix, initial.ink, initial.total, initial.logo]);

  async function save() {
    setSaved(false);
    for (const [field, key] of Object.entries(BRAND_KEYS) as [
      keyof typeof BRAND_KEYS,
      string,
    ][]) {
      const value = draft[field].trim();
      if (value === (initial[field] ?? "")) continue;
      await set.mutateAsync({ p_resource_key: key, p_locale: locale, p_text: value });
    }
    await queryClient.invalidateQueries({ queryKey: ["erp_resources"] });
    await queryClient.invalidateQueries({ queryKey: ["erp_resource_catalog"] });
    setSaved(true);
  }

  const fields: { field: keyof typeof BRAND_KEYS; label: string; hint: string }[] = [
    { field: "prefix", label: "Wordmark, first part", hint: BRAND_DEFAULTS.prefix },
    { field: "suffix", label: "Wordmark, second part", hint: BRAND_DEFAULTS.suffix },
    { field: "ink", label: "Entry colour", hint: BRAND_DEFAULTS.ink },
    { field: "total", label: "Total colour", hint: BRAND_DEFAULTS.total },
    { field: "logo", label: "Logo image URL", hint: "https://… (optional)" },
  ];

  return (
    <section className="rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <h2 className="text-sm font-semibold">Branding</h2>
        <Prose className="mt-0.5 text-xs text-muted-foreground">
          What this tenant is called and how its mark is drawn, in the shell and in the browser tab
          where the browser supports it. Leave a field empty to keep the product identity.
        </Prose>
      </header>

      <div className="flex flex-col gap-4 px-4 py-4 sm:px-5">
        <div className="flex items-center gap-3 rounded-lg border border-border/70 bg-background px-4 py-3">
          <BrandMark size={32} />
          <span className="font-serif text-lg font-semibold tracking-[-0.02em]">
            <span style={{ color: brand.ink }}>{brand.prefix}</span>
            <span style={{ color: brand.total }}>{brand.suffix}</span>
          </span>
          <span className="ml-auto text-xs text-muted-foreground">
            {brand.isDefault ? "Product identity" : "Tenant identity"}
          </span>
        </div>

        <div className="grid gap-3 sm:grid-cols-2">
          {fields.map(({ field, label, hint }) => (
            <label key={field} className="flex flex-col gap-1 text-sm">
              <span className="font-medium">{label}</span>
              <input
                value={draft[field]}
                placeholder={hint}
                onChange={(e) => setDraft((d) => ({ ...d, [field]: e.target.value }))}
                className="min-h-11 rounded-md border border-input bg-background px-3 text-sm"
              />
            </label>
          ))}
        </div>

        <div className="flex flex-wrap items-center gap-3">
          <ActionButton onClick={save} busy={set.isPending}>
            Save branding
          </ActionButton>
          {saved ? <span className="text-xs text-muted-foreground">Branding saved.</span> : null}
        </div>

        {set.error ? <ErrorNote error={set.error} /> : null}
      </div>
    </section>
  );
}
