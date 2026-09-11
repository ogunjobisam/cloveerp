import { useState } from "react";

import { ActionBar } from "./actions-bar";
import { ActionDialog } from "./action";
import { DataPanel, Pill, Table } from "./panel";

/**
 * Keys, webhook subscriptions and the delivery log.
 *
 * Everything here is read and written through the public doors, which decide
 * the organisation themselves. A key's scopes can only narrow what the service
 * account behind it already holds; the database refuses anything wider.
 */

const PERMISSION = "administration.integrate";
const KEYS = "erp_api_keys";
const SUBS = "erp_webhook_subscriptions";
const DELIVERIES = "erp_webhook_deliveries";

type ApiKey = {
  api_key_id: string;
  label: string;
  prefix: string;
  service_principal: string | null;
  scopes: string[] | null;
  expires_at: string | null;
  revoked_at: string | null;
  revoked_reason: string | null;
  last_used_at: string | null;
  created_at: string;
};

type Subscription = {
  subscription_id: string;
  name: string;
  event_pattern: string;
  target_url: string;
  secret_hint: string | null;
  status: string;
  last_delivery_at: string | null;
  pending: number;
  failed: number;
};

type Delivery = {
  delivery_id: string;
  subscription: string | null;
  event_type: string;
  attempt: number;
  status: string;
  response_status: number | null;
  failure_reason: string | null;
  next_attempt_at: string | null;
  delivered_at: string | null;
  replay_of: string | null;
  created_at: string;
};

function when(value: string | null): string {
  if (!value) return "—";
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? value : d.toLocaleString();
}

function statusTone(status: string): "ok" | "warn" | "bad" | "muted" {
  const s = status.toLowerCase();
  if (s === "delivered" || s === "active") return "ok";
  if (s === "pending" || s === "retrying" || s === "paused") return "warn";
  if (s === "failed" || s === "dead" || s === "revoked") return "bad";
  return "muted";
}

/** A secret the database will not say twice, said once and clearly. */
function ShownOnce({
  what,
  secret,
  onDismiss,
}: {
  what: string;
  secret: string;
  onDismiss: () => void;
}) {
  return (
    <div
      role="alert"
      className="border-l-4 border-amber-500 bg-amber-500/10 p-4 text-sm sm:p-5"
      data-testid="shown-once"
    >
      <p className="font-medium">Copy this {what} now.</p>
      <p className="mt-1 text-muted-foreground">
        It is stored only as a fingerprint, so this is the one time it can be shown. If it is lost,
        issue a new one.
      </p>
      <code className="mt-3 block w-full break-all rounded bg-background p-3 font-mono text-xs">
        {secret}
      </code>
      <button
        type="button"
        onClick={onDismiss}
        className="mt-3 text-xs font-medium text-primary underline-offset-4 hover:underline"
      >
        I have copied it — hide it
      </button>
    </div>
  );
}

function secretFrom(result: unknown, key: string): string | null {
  if (result && typeof result === "object") {
    const value = (result as Record<string, unknown>)[key];
    if (typeof value === "string" && value !== "") return value;
  }
  return null;
}

export function ApiAccess() {
  const [keySecret, setKeySecret] = useState<string | null>(null);
  const [hookSecret, setHookSecret] = useState<string | null>(null);

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <section className="min-w-0 border border-border bg-card p-5">
        <h2 className="text-base font-semibold">API keys</h2>
        <p className="mt-1 text-sm text-muted-foreground">
          A key belongs to a service account in this organisation. Its scopes are ordinary
          permission codes and can only narrow what that account already holds.
        </p>

        <div className="mt-4 flex flex-wrap gap-2">
          <ActionDialog
            trigger="Issue a key"
            title="Issue an API key"
            description="Choose the service account the key acts as, and the permissions it may use."
            permission={PERMISSION}
            fn="erp_issue_api_key"
            fields={[
              {
                kind: "select",
                name: "p_app_user_id",
                label: "Service account",
                required: true,
                hint: "Machine accounts only. Create one on Administration → Permissions.",
                options: {
                  fn: "erp_permissions_directory",
                  path: "principals",
                  value: "id",
                  label: ["display_name", "kind"],
                },
              },
              {
                kind: "text",
                name: "p_label",
                label: "Name",
                required: true,
                placeholder: "Warehouse scanner",
                hint: "How this key is recognised in the list and the audit log.",
              },
              {
                kind: "multi",
                name: "p_scopes",
                label: "Permissions",
                required: true,
                hint: "Anything the service account is not granted will be refused.",
                options: {
                  fn: "erp_permissions_directory",
                  path: "permission_catalog",
                  value: "code",
                  label: ["code"],
                },
              },
              {
                kind: "date",
                name: "p_expires_at",
                label: "Expires",
                hint: "Optional. Leave empty for a key that runs until it is revoked.",
              },
            ]}
            invalidates={[KEYS]}
            submitLabel="Issue key"
            onDone={(result) => setKeySecret(secretFrom(result, "secret"))}
          />
        </div>

        {keySecret ? (
          <div className="mt-4">
            <ShownOnce what="key" secret={keySecret} onDismiss={() => setKeySecret(null)} />
          </div>
        ) : null}

        <div className="mt-5">
          <DataPanel<ApiKey>
            title="Live and past keys"
            fn={KEYS}
            empty="No keys have been issued for this organisation yet. Issue one above to let a system call the API."
          >
            {(rows) => (
              <Table columns={["Key", "Service account", "Scopes", "Last used", "State"]}>
                {rows.map((row) => (
                  <tr key={row.api_key_id} className="border-b border-border/50 last:border-0">
                    <td className="py-2 pr-4">
                      <span className="block truncate font-medium">{row.label}</span>
                      <span className="font-mono text-xs text-muted-foreground">{row.prefix}</span>
                    </td>
                    <td className="py-2 pr-4 text-sm">{row.service_principal ?? "—"}</td>
                    <td className="py-2 pr-4 font-mono text-xs text-muted-foreground">
                      {(row.scopes ?? []).length} permission
                      {(row.scopes ?? []).length === 1 ? "" : "s"}
                    </td>
                    <td className="whitespace-nowrap py-2 pr-4 text-sm">
                      {when(row.last_used_at)}
                    </td>
                    <td className="py-2">
                      {row.revoked_at ? (
                        <Pill tone="bad">Revoked</Pill>
                      ) : row.expires_at && new Date(row.expires_at) < new Date() ? (
                        <Pill tone="warn">Expired</Pill>
                      ) : (
                        <Pill tone="ok">Live</Pill>
                      )}
                    </td>
                  </tr>
                ))}
              </Table>
            )}
          </DataPanel>
        </div>

        <div className="mt-4">
          <ActionBar
            title="Ending a key"
            note="Revoking takes effect on the next call. A revoked key is never reinstated."
            actions={[
              {
                label: "Revoke a key",
                permission: PERMISSION,
                fn: "erp_revoke_api_key",
                fields: [
                  {
                    kind: "select",
                    name: "p_api_key_id",
                    label: "Key",
                    required: true,
                    options: { fn: KEYS, value: "api_key_id", label: ["label", "prefix"] },
                  },
                  {
                    kind: "text",
                    name: "p_reason",
                    label: "Why",
                    required: true,
                    placeholder: "Laptop lost",
                    hint: "Recorded against the key and in the audit log.",
                  },
                ],
                invalidates: [KEYS],
              },
            ]}
          />
        </div>
      </section>

      <section className="min-w-0 border border-border bg-card p-5">
        <h2 className="text-base font-semibold">Webhooks</h2>
        <p className="mt-1 text-sm text-muted-foreground">
          Where this organisation wants its events sent. Every delivery is signed and retried with
          backoff, and the whole history is below.
        </p>

        <div className="mt-4 flex flex-wrap gap-2">
          <ActionDialog
            trigger="Add a subscription"
            title="Add a webhook subscription"
            description="Events matching the pattern are posted to this address, signed with a secret shown once."
            permission={PERMISSION}
            fn="erp_create_webhook_subscription"
            fields={[
              {
                kind: "text",
                name: "p_name",
                label: "Name",
                required: true,
                placeholder: "Order updates to the shop",
              },
              {
                kind: "text",
                name: "p_event_pattern",
                label: "Events",
                required: true,
                placeholder: "sales.*",
                hint: "A pattern; * matches anything. Use * on its own for every event.",
              },
              {
                kind: "text",
                name: "p_target_url",
                label: "Address",
                required: true,
                placeholder: "https://example.co.uk/hooks/clove",
                hint: "Must be https. The signature is in the request headers.",
              },
            ]}
            invalidates={[SUBS]}
            submitLabel="Add subscription"
            onDone={(result) => setHookSecret(secretFrom(result, "secret"))}
          />
        </div>

        {hookSecret ? (
          <div className="mt-4">
            <ShownOnce
              what="signing secret"
              secret={hookSecret}
              onDismiss={() => setHookSecret(null)}
            />
          </div>
        ) : null}

        <div className="mt-5">
          <DataPanel<Subscription>
            title="Subscriptions"
            fn={SUBS}
            empty="No webhook subscriptions yet. Add one above to have events posted to another system."
          >
            {(rows) => (
              <Table columns={["Name", "Events", "Address", "Waiting", "Failed", "State"]}>
                {rows.map((row) => (
                  <tr key={row.subscription_id} className="border-b border-border/50 last:border-0">
                    <td className="py-2 pr-4 font-medium">{row.name}</td>
                    <td className="whitespace-nowrap py-2 pr-4 font-mono text-xs">
                      {row.event_pattern}
                    </td>
                    <td className="max-w-[18rem] py-2 pr-4">
                      <span className="block truncate font-mono text-xs" title={row.target_url}>
                        {row.target_url}
                      </span>
                    </td>
                    <td className="py-2 pr-4 text-sm">{row.pending}</td>
                    <td className="py-2 pr-4 text-sm">{row.failed}</td>
                    <td className="py-2">
                      <Pill tone={statusTone(row.status)}>{row.status}</Pill>
                    </td>
                  </tr>
                ))}
              </Table>
            )}
          </DataPanel>
        </div>

        <div className="mt-4">
          <ActionBar
            title="Looking after a subscription"
            note="Pausing stops delivery without losing the history. Rotating replaces the signing secret immediately."
            actions={[
              {
                label: "Pause or resume",
                permission: PERMISSION,
                fn: "erp_set_webhook_subscription_status",
                fields: [
                  {
                    kind: "select",
                    name: "p_subscription_id",
                    label: "Subscription",
                    required: true,
                    options: { fn: SUBS, value: "subscription_id", label: ["name"] },
                  },
                  {
                    kind: "choice",
                    name: "p_status",
                    label: "State",
                    required: true,
                    choices: [
                      { value: "active", label: "Active" },
                      { value: "paused", label: "Paused" },
                      { value: "disabled", label: "Disabled" },
                    ],
                  },
                ],
                invalidates: [SUBS],
              },
              {
                label: "Rotate the secret",
                permission: PERMISSION,
                fn: "erp_rotate_webhook_secret",
                fields: [
                  {
                    kind: "select",
                    name: "p_subscription_id",
                    label: "Subscription",
                    required: true,
                    options: { fn: SUBS, value: "subscription_id", label: ["name"] },
                  },
                ],
                invalidates: [SUBS],
              },
            ]}
          />
        </div>

        <div className="mt-5">
          <DataPanel<Delivery>
            title="Delivery log"
            fn={DELIVERIES}
            empty="Nothing has been delivered yet. Attempts appear here as soon as a matching event happens."
          >
            {(rows) => (
              <Table columns={["Event", "Subscription", "Attempt", "Answer", "When", "State"]}>
                {rows.map((row) => (
                  <tr key={row.delivery_id} className="border-b border-border/50 last:border-0">
                    <td className="whitespace-nowrap py-2 pr-4 font-mono text-xs">
                      {row.event_type}
                    </td>
                    <td className="py-2 pr-4 text-sm">{row.subscription ?? "—"}</td>
                    <td className="py-2 pr-4 text-sm">{row.attempt}</td>
                    <td className="py-2 pr-4 text-sm">
                      <span className="block truncate" title={row.failure_reason ?? undefined}>
                        {row.response_status ?? row.failure_reason ?? "—"}
                      </span>
                    </td>
                    <td className="whitespace-nowrap py-2 pr-4 text-sm">
                      {when(row.delivered_at ?? row.created_at)}
                    </td>
                    <td className="py-2">
                      <Pill tone={statusTone(row.status)}>{row.status}</Pill>
                    </td>
                  </tr>
                ))}
              </Table>
            )}
          </DataPanel>
        </div>

        <div className="mt-4">
          <ActionBar
            title="Sending one again"
            note="A replay sends the original payload again as a new attempt. The first attempt stays in the log."
            actions={[
              {
                label: "Replay a delivery",
                permission: PERMISSION,
                fn: "erp_replay_webhook_delivery",
                fields: [
                  {
                    kind: "select",
                    name: "p_delivery_id",
                    label: "Delivery",
                    required: true,
                    options: {
                      fn: DELIVERIES,
                      value: "delivery_id",
                      label: ["event_type", "status"],
                    },
                  },
                ],
                invalidates: [DELIVERIES, SUBS],
              },
            ]}
          />
        </div>
      </section>
    </div>
  );
}
