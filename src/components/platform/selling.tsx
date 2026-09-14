import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Store } from "lucide-react";
import { useState, type ReactNode } from "react";

import { Pill } from "../erp/panel";
import { TOUCH } from "../erp/page";
import { callErp } from "../../lib/erp";
import type { PlatformRole } from "../../lib/platform";
import { priceListLoaded } from "../../lib/platform-today";
import { Card, Fail, INPUT } from "./kit";

/**
 * Selling, set up from the console.
 *
 * Quotes, contracts and the price list live inside Clove ERP's own
 * organisation (§17.5), which is two things to set up: which organisation that
 * is, and the price list in it. On 14 September this card said "price items,
 * approval chains and output templates" and stopped at "No organisation is
 * designated yet", and the four steps behind it were nowhere on screen. It now
 * says what is done and offers the next thing to do.
 *
 * Loading the price list runs erp_set_up_selling inside the platform's
 * organisation as the person pressing the button, so it needs them to belong
 * to it. The console switches to that organisation for the call and back
 * again, the same switch the account menu makes.
 */

const BUTTON = `${TOUCH} inline-flex items-center rounded-md bg-primary px-3 text-sm font-semibold text-primary-foreground disabled:opacity-60`;
const SECONDARY = `${TOUCH} inline-flex items-center rounded-md border border-input px-3 text-sm font-medium`;

export type CommercialState = {
  platform_organisation: {
    tenant_id: string;
    tenant_code: string;
    name: string | null;
    designated_at: string;
    designated_by: string;
    reason: string | null;
    status: string | null;
  } | null;
  candidates: { code: string; name: string; is_demonstration: boolean }[];
  price_items: number;
  selling: {
    installed: boolean;
    price_book: { code: string; name: string; version: number; effective_from: string } | null;
    rates: number;
    waiting: boolean;
  } | null;
  findings: { finding: string; reference: string; detail: string }[];
};

type MyTenant = {
  tenant_id: string;
  code: string;
  name: string;
  principal_id: string;
  is_active: boolean;
};

type SetUpResult = {
  price_book: string;
  version: number | null;
  items_added: number;
  items_on_book: number;
  waiting_for: string[];
};

function day(value: string | null | undefined) {
  return value ? new Date(value).toLocaleDateString() : "—";
}

function Step({ title, done, children }: { title: string; done: boolean; children: ReactNode }) {
  return (
    <li className="flex flex-col gap-2 border-b border-border/60 pb-4 last:border-0 last:pb-0">
      <div className="flex flex-wrap items-center gap-2">
        <h3 className="text-sm font-semibold">{title}</h3>
        <Pill tone={done ? "ok" : "warn"}>{done ? "Done" : "To do"}</Pill>
      </div>
      {children}
    </li>
  );
}

export function SellingSetup({ role }: { role: PlatformRole }) {
  const queryClient = useQueryClient();
  const isOwner = role === "owner";

  const state = useQuery({
    queryKey: ["erp_platform_commercial_state"],
    queryFn: () => callErp<CommercialState>("erp_platform_commercial_state"),
  });
  const tenants = useQuery({
    queryKey: ["erp_my_tenants"],
    queryFn: () => callErp<MyTenant[]>("erp_my_tenants"),
  });

  const [choice, setChoice] = useState("");
  const [reason, setReason] = useState("");
  const [moving, setMoving] = useState(false);

  const designate = useMutation({
    mutationFn: () =>
      callErp("erp_platform_designate_organisation", {
        p_tenant_code: choice,
        p_reason: reason.trim() || null,
      }),
    onSuccess: () => {
      setMoving(false);
      setReason("");
      void queryClient.invalidateQueries({ queryKey: ["erp_platform_commercial_state"] });
      void queryClient.invalidateQueries({ queryKey: ["erp_platform_contracts"] });
    },
  });

  const platform = state.data?.platform_organisation ?? null;
  const mine = tenants.data ?? [];
  const membership = platform ? mine.find((t) => t.tenant_id === platform.tenant_id) : undefined;
  const previouslyActive = mine.find((t) => t.is_active);

  const load = useMutation({
    mutationFn: async () => {
      if (!platform) throw new Error("Choose Clove ERP's own organisation first.");
      const switchBack =
        membership && !membership.is_active && previouslyActive ? previouslyActive : null;
      if (membership && !membership.is_active) {
        await callErp("erp_set_active_tenant", { p_tenant_id: platform.tenant_id });
      }
      try {
        return await callErp<SetUpResult>("erp_set_up_selling");
      } finally {
        if (switchBack) {
          await callErp("erp_set_active_tenant", { p_tenant_id: switchBack.tenant_id });
        }
      }
    },
    onSettled: () => void queryClient.invalidateQueries(),
  });

  const choices = (state.data?.candidates ?? []).filter(
    (c) => !c.is_demonstration && c.code !== platform?.tenant_code,
  );
  const selling = state.data?.selling ?? null;
  // The same test Today's "Selling is not set up" card uses, so the two agree.
  const listLoaded = state.data ? priceListLoaded(state.data) : false;

  return (
    <Card
      title="Selling"
      icon={<Store className="size-4 text-primary" />}
      description="Quotes, contracts and the price list live in Clove ERP's own organisation. Set it up once, here."
    >
      {state.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : state.error ? (
        <Fail error={state.error} />
      ) : !state.data ? null : (
        <ol className="flex flex-col gap-4">
          <Step title="1. Clove ERP's own organisation" done={Boolean(platform)}>
            {platform ? (
              <p className="text-sm">
                <span className="font-medium">{platform.name ?? platform.tenant_code}</span>{" "}
                <span className="font-mono text-xs text-muted-foreground">
                  {platform.tenant_code}
                </span>{" "}
                <Pill tone={platform.status === "active" ? "ok" : "bad"}>
                  {platform.status ?? "missing"}
                </Pill>
                <span className="ml-2 text-xs text-muted-foreground">
                  chosen {day(platform.designated_at)} by {platform.designated_by}
                </span>
              </p>
            ) : (
              <p className="text-sm text-muted-foreground">
                Choose the organisation that is Clove ERP itself, not a customer&apos;s and not a
                demonstration. Its price list, quotes and approvals live there.
              </p>
            )}

            {!isOwner ? (
              platform ? null : (
                <p className="text-xs text-muted-foreground">A platform owner chooses it.</p>
              )
            ) : platform && !moving ? (
              <button
                type="button"
                className={`${SECONDARY} self-start`}
                onClick={() => setMoving(true)}
              >
                Use a different organisation
              </button>
            ) : choices.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                There is no organisation to choose. Onboard one for Clove ERP under Customers, then
                come back.
              </p>
            ) : (
              <form
                className="flex flex-col gap-2 rounded-lg border border-border/60 p-3"
                onSubmit={(e) => {
                  e.preventDefault();
                  if (choice) designate.mutate();
                }}
              >
                <div className="grid gap-2 sm:grid-cols-2">
                  <label className="block text-xs font-medium">
                    Organisation
                    <select
                      className={INPUT}
                      value={choice}
                      onChange={(e) => setChoice(e.target.value)}
                    >
                      <option value="">Choose…</option>
                      {choices.map((c) => (
                        <option key={c.code} value={c.code}>
                          {c.name} ({c.code})
                        </option>
                      ))}
                    </select>
                  </label>
                  {platform ? (
                    <label className="block text-xs font-medium">
                      Why it is moving
                      <input
                        className={INPUT}
                        value={reason}
                        required
                        onChange={(e) => setReason(e.target.value)}
                      />
                    </label>
                  ) : null}
                </div>
                {designate.error ? <Fail error={designate.error} /> : null}
                <div className="flex flex-wrap gap-2">
                  <button
                    type="submit"
                    className={BUTTON}
                    disabled={!choice || designate.isPending}
                  >
                    {designate.isPending ? "Working…" : "Use this organisation"}
                  </button>
                  {platform ? (
                    <button type="button" className={SECONDARY} onClick={() => setMoving(false)}>
                      Keep {platform.name ?? platform.tenant_code}
                    </button>
                  ) : null}
                </div>
              </form>
            )}
          </Step>

          <Step title="2. The price list" done={listLoaded}>
            {!platform ? (
              <p className="text-sm text-muted-foreground">
                Once the organisation is chosen, its price list loads in one step.
              </p>
            ) : listLoaded && selling?.price_book ? (
              <p className="text-sm">
                <span className="font-medium">{selling.price_book.name}</span>{" "}
                <span className="font-mono text-xs text-muted-foreground">
                  {selling.price_book.code} v{selling.price_book.version}
                </span>
                <span className="ml-2 text-xs text-muted-foreground">
                  {state.data.price_items} items and {selling.rates} rates, in force from{" "}
                  {day(selling.price_book.effective_from)}. Change a rate on the Price book screen
                  in {platform.name ?? platform.tenant_code}.
                </span>
              </p>
            ) : (
              <>
                <p className="text-sm text-muted-foreground">
                  Starter, Standard and Enterprise with their extra and light users, extra companies
                  and sites, onboarding, the 30-day pilot and Priority support, each with an annual,
                  monthly and multi-year rate and a cost. Nothing already on the list is changed.
                </p>
                {selling?.waiting ? (
                  <p className="text-sm text-muted-foreground">
                    Part of it is waiting for a second administrator to approve it under
                    Configuration in {platform.name ?? platform.tenant_code}.
                  </p>
                ) : null}
                {tenants.isPending ? null : !membership ? (
                  <p className="text-sm">
                    You are not a member of {platform.name ?? platform.tenant_code}. Invite yourself
                    as its administrator under Customers, accept the invitation, then come back.
                  </p>
                ) : role === "support" ? (
                  <p className="text-xs text-muted-foreground">
                    An owner or operator loads the price list.
                  </p>
                ) : (
                  <button
                    type="button"
                    className={`${BUTTON} self-start`}
                    disabled={load.isPending}
                    onClick={() => load.mutate()}
                  >
                    {load.isPending ? "Loading the price list…" : "Load the price list"}
                  </button>
                )}
              </>
            )}
            {load.error ? <Fail error={load.error} /> : null}
            {load.data ? (
              load.data.waiting_for.length > 0 ? (
                <ul className="flex flex-col gap-1 text-sm">
                  {load.data.waiting_for.map((w) => (
                    <li key={w}>{w}</li>
                  ))}
                </ul>
              ) : (
                <p className="text-sm" role="status">
                  {load.data.items_added === 0
                    ? `Nothing was missing: ${load.data.items_on_book} items are on ${load.data.price_book}.`
                    : `${load.data.items_added} items added to ${load.data.price_book}.`}
                </p>
              )
            ) : null}
          </Step>

          {state.data.findings.length > 0 ? (
            <li>
              <ul className="flex flex-col gap-1" role="alert">
                {state.data.findings.map((f, i) => (
                  <li key={`${f.finding}-${i}`} className="text-xs text-destructive">
                    <span className="font-medium">{f.finding}</span> · {f.reference}: {f.detail}
                  </li>
                ))}
              </ul>
            </li>
          ) : null}
        </ol>
      )}
    </Card>
  );
}
