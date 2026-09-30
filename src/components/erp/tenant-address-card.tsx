import { useState } from "react";

import { useT } from "../../lib/i18n";
import { displayAddress } from "../../lib/tenant-address";
import { ActionButtons } from "./actions-bar";
import { addressHost } from "./gate";
import { Prose } from "./page";
import { useErpSession } from "./session-context";

/**
 * The organisation's address — cloveerp.com/acme — and the way to change it.
 *
 * Read from the session, which already carries the tenant's code, so there is
 * no second door to ask. Changing it goes through erp_set_tenant_address,
 * which authorises administration.configure; the old address keeps opening
 * the new one, so a link already sent does not break.
 */
export function TenantAddressCard() {
  const { ui } = useT();
  const { session } = useErpSession();
  const [copied, setCopied] = useState(false);
  const code = session.tenant?.code;
  if (!code) return null;
  const address = displayAddress(addressHost(), code);

  async function copy() {
    try {
      await navigator.clipboard.writeText(`${window.location.protocol}//${address}`);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 2000);
    } catch {
      /* clipboard refused; the address is on screen to select by hand */
    }
  }

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card p-4 sm:p-5">
      <h2 className="text-sm font-semibold">{ui("Your organisation's address")}</h2>
      <Prose className="mt-0.5 text-xs text-muted-foreground">
        {ui(
          "Where your people sign in. It puts this organisation's name on the sign-in form; what each person can open is still decided by their own account.",
        )}
      </Prose>
      <div className="mt-3 flex min-w-0 flex-wrap items-center gap-2">
        <code className="min-w-0 break-all rounded-md bg-muted px-2 py-1 font-mono text-sm">
          {address}
        </code>
        <button
          type="button"
          onClick={() => void copy()}
          className="rounded-md border border-input px-3 py-1 text-xs font-medium hover:bg-muted"
        >
          {copied ? ui("Copied") : ui("Copy")}
        </button>
      </div>
      <div className="mt-3 flex flex-wrap gap-2">
        <ActionButtons
          actions={[
            {
              label: "Change the address",
              description:
                "The address changes at once. The old one keeps working and opens the new one, and no other organisation can take it.",
              permission: "administration.configure",
              fn: "erp_set_tenant_address",
              fields: [
                {
                  kind: "text",
                  name: "p_code",
                  label: "New address",
                  required: true,
                  placeholder: "acme",
                  hint: "Letters, digits and hyphens, three to 63 characters.",
                },
              ],
              invalidates: ["erp_session"],
            },
          ]}
        />
      </div>
    </section>
  );
}
