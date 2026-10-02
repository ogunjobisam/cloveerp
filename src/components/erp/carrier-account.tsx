import { useQuery } from "@tanstack/react-query";

import { carrierAccount, webhookAddress } from "../../lib/carriers/carrier-account";
import { callErp, hasPermission, supabaseUrl } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { ActionButton, ActionDialog, ErrorNote, type Field } from "./action";
import { Prose } from "./page";
import { Pill } from "./panel";
import { useErpSession } from "./session-context";

/**
 * The organisation's own EasyPost account, on the Integrations screen
 * (20261004950000).
 *
 * Connect takes the API key and, optionally, the webhook's signing secret,
 * typed into fields that never show them; both go straight to the vault and
 * nothing here, nor in any read, carries them back. Once connected, a carrier
 * linked to the account is booked through it: booking asks the carrier's own
 * system for the label, and its tracking comes back to the shipment through
 * the webhook address shown here. Offered to an administrator
 * (administration.integrate); the database refuses regardless.
 */

const INVALIDATES = ["erp_carrier_account", "erp_carriers"];

export function CarrierAccount() {
  const { ui } = useT();
  const { session } = useErpSession();
  const mayRead = hasPermission(session, "administration.integrate");
  const { data, error } = useQuery({
    queryKey: ["erp_carrier_account"],
    queryFn: () => callErp<unknown>("erp_carrier_account", {}),
    enabled: mayRead,
  });
  if (!mayRead) return null;
  const account = carrierAccount(data);
  const hook = webhookAddress(supabaseUrl, account?.webhookPath ?? null);

  const connectFields: Field[] = [
    { kind: "secret", name: "p_api_key", label: "API key", required: true, placeholder: "EZTK…" },
    {
      kind: "secret",
      name: "p_webhook_secret",
      label: "Webhook signing secret",
      hint: "Optional. The secret EasyPost shows for your webhook, so tracking can reach shipments.",
    },
  ];
  const linkFields: Field[] = [
    {
      kind: "select",
      name: "p_carrier_code",
      label: "Carrier",
      required: true,
      options: { fn: "erp_carriers", value: "code", label: ["code", "name"] },
    },
    {
      kind: "text",
      name: "p_provider_account",
      label: "Carrier account at EasyPost",
      required: true,
      placeholder: "ca_…",
    },
  ];

  return (
    <section className="min-w-0 border border-border bg-card p-5">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="text-base font-semibold">{ui("Carrier account")}</h2>
          <Prose className="mt-1 text-sm text-muted-foreground">
            {ui(
              "Book carriers through your own EasyPost account: labels and tracking come from the carriers' own systems. The key is kept in the vault, never on a screen.",
            )}
          </Prose>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {account?.connected ? (
            <>
              <Pill tone="ok">{ui("Connected")}</Pill>
              <Pill tone={account.mode === "live" ? "ok" : "warn"}>
                {account.mode === "live" ? ui("Live") : ui("Test mode")}
              </Pill>
            </>
          ) : (
            <Pill tone="muted">{ui("Not connected")}</Pill>
          )}
        </div>
      </div>
      <ErrorNote error={error} />

      {account?.connected && hook ? (
        <div className="mt-3 text-sm">
          <span className="text-xs text-muted-foreground">{ui("Webhook address")}</span>
          <p className="mt-0.5 break-all font-mono text-xs">{hook}</p>
          <p className="mt-1 text-xs text-muted-foreground">
            {ui(
              "Add this address in EasyPost under Webhooks, with the signing secret you give here.",
            )}
          </p>
        </div>
      ) : null}

      {account?.mayConnect ? (
        <div className="mt-4 flex flex-wrap gap-2">
          <ActionDialog
            trigger={
              <ActionButton>
                {account.connected ? ui("Connect") : ui("Connect EasyPost")}
              </ActionButton>
            }
            title="Connect your EasyPost account"
            description="Paste the API key from your EasyPost dashboard: a test key (EZTK…) to try it, a live key (EZAK…) to ship. It goes straight to the vault."
            permission="administration.integrate"
            fn="erp_connect_carrier_account"
            fields={connectFields}
            prefill={{ p_provider: "easypost" }}
            invalidates={INVALIDATES}
            submitLabel="Connect"
          />
          {account.connected ? (
            <>
              <ActionDialog
                trigger={
                  <ActionButton variant="secondary">
                    {ui("Link a carrier to EasyPost")}
                  </ActionButton>
                }
                title="Link a carrier to EasyPost"
                description="Books this carrier through your EasyPost account, using the carrier account EasyPost gave it."
                permission="administration.integrate"
                fn="erp_link_carrier_provider"
                fields={linkFields}
                prefill={{ p_provider: "easypost" }}
                invalidates={INVALIDATES}
                submitLabel="Link"
              />
              <ActionDialog
                trigger={<ActionButton variant="secondary">{ui("Disconnect")}</ActionButton>}
                title="Disconnect"
                description="No more bookings through EasyPost. Connecting again takes a new key."
                permission="administration.integrate"
                fn="erp_disconnect_carrier_account"
                fields={[]}
                prefill={{ p_provider: "easypost" }}
                invalidates={INVALIDATES}
                submitLabel="Disconnect"
              />
            </>
          ) : null}
        </div>
      ) : null}
    </section>
  );
}
