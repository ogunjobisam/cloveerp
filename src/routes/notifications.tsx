import { useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";

import { ActionButton, ErrorNote, useErpAction } from "../components/erp/action";
import { ActionBar, codeField } from "../components/erp/actions-bar";
import { Gate } from "../components/erp/gate";
import { PageHeader, TOUCH } from "../components/erp/page";
import { DataPanel, Pill, Table } from "../components/erp/panel";
import { useErpSession } from "../components/erp/session-context";
import { callErp, hasPermission } from "../lib/erp";
import { useT } from "../lib/i18n";

/**
 * Notifications. Specification v1.2 §15.6.
 *
 * A person's own messages with their delivery tracked, their channel choices
 * within the organisation's bounds, their quiet hours with the severity that
 * breaks through, and — for an administrator — the routes from events to
 * audiences. In-app is the channel that always works: everything another
 * channel failed to carry arrives here with the reason.
 */

export const Route = createFileRoute("/notifications")({
  head: () => ({
    meta: [
      { title: "Notifications — Clove ERP" },
      {
        name: "description",
        content: "Approvals, exceptions and system notices awaiting your attention.",
      },
      { property: "og:title", content: "Notifications — Clove ERP" },
      {
        property: "og:description",
        content: "Approvals, exceptions and system notices awaiting your attention.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Notifications />
    </Gate>
  ),
});

type Notification = {
  id: string;
  severity: string;
  channel_kind: string;
  subject: string;
  body: string;
  status: string;
  created_at: string;
  read_at: string | null;
  digest_of: number;
  is_escalation: boolean;
  failure_reason: string | null;
};

type Settings = {
  preferences: { channel_kind: string; is_enabled: boolean }[];
  quiet_hours: {
    days_of_week: number[];
    starts_at: string;
    ends_at: string;
    timezone: string;
    override_at_or_above: string;
  }[];
  services_installed: boolean;
  unread: number;
};

type RouteRow = {
  code: string;
  name: string;
  event_pattern: string;
  severity: string;
  audience_kind: string;
  audience: string;
  channel_kind: string;
  template_code: string | null;
  digest_minutes: number | null;
  escalate_after_minutes: number | null;
  escalate_to: string | null;
  is_mandatory: boolean;
  status: string;
};

type Health = {
  channel_kind: string;
  pending: number;
  held: number;
  sent: number;
  delivered: number;
  read: number;
  failed: number;
  suppressed: number;
  oldest_pending_minutes: number | null;
};

type ChannelRow = {
  id: string;
  code: string;
  name: string;
  kind: string;
  settings: Record<string, unknown>;
  credential_ref: string | null;
  is_enabled: boolean;
};

const CHANNELS = ["email", "sms", "push", "webhook"];
const DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const FIELD = `${TOUCH} mt-1 w-full rounded-md border border-input bg-background px-3 text-sm`;

function when(value: string | null) {
  return value ? new Date(value).toLocaleString() : "—";
}

function Notifications() {
  const { ui } = useT();
  const { session } = useErpSession();
  const settings = useQuery({
    queryKey: ["erp_my_notification_settings", {}],
    queryFn: async () => {
      // The arrays, filled in once. callErp's type argument casts rather than
      // checks, and every read below trusts it; a response missing one field
      // threw, and the throw reaches the root boundary, so the cost was not
      // this panel but every screen in the product.
      const d = await callErp<Settings>("erp_my_notification_settings");
      return {
        ...d,
        preferences: d?.preferences ?? [],
        quiet_hours: d?.quiet_hours ?? [],
        services_installed: d?.services_installed ?? false,
        unread: d?.unread ?? 0,
      };
    },
  });
  const install = useErpAction({
    fn: "erp_configure_notifications",
    invalidates: ["erp_my_notification_settings", "erp_change_sets"],
  });
  const admin = hasPermission(session, "administration.configure");

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={ui("Notifications")}>
        {ui(
          "What the product told you, what it held for your quiet hours, and what it could not deliver another way. In-app is the channel that always works; nothing addressed to you is lost because another channel failed.",
        )}
      </PageHeader>

      {settings.data && !settings.data.services_installed && admin ? (
        <section className="rounded-xl border border-border bg-card p-4 sm:p-5">
          <p className="text-sm">
            {ui(
              "Notification services are not installed. Installing them is a configuration change, approved and promoted like a module: the two jobs that route events to audiences and dispatch what was routed.",
            )}
          </p>
          <div className="mt-3">
            <ActionButton
              onClick={() => install.mutate({})}
              disabled={install.isPending}
              variant="secondary"
            >
              {ui("Install notification services")}
            </ActionButton>
          </div>
          {install.error ? <ErrorNote error={install.error} /> : null}
        </section>
      ) : null}

      <Inbox />

      <Preferences settings={settings.data ?? null} />

      {admin ? (
        <>
          <ActionBar
            title="Notification routes"
            note="A route binds an event pattern and a severity to an audience. A mandatory route reaches its audience in-app even when they switched the channel off."
            actions={[
              {
                label: "Define a route",
                permission: "administration.configure",
                fn: "erp_upsert_notification_route",
                fields: [
                  codeField("p_code", "Code", "APPROVALS-FINANCE", {
                    fn: "erp_notification_routes",
                    value: "code",
                    label: ["code", "name"],
                  }),
                  {
                    kind: "text",
                    name: "p_name",
                    label: "Name",
                    required: true,
                    placeholder: "Finance approvals",
                  },
                  {
                    kind: "text",
                    name: "p_event_pattern",
                    label: "Event pattern",
                    required: true,
                    hint: "A LIKE pattern over event types, e.g. approval.% or release.printed.",
                  },
                  {
                    kind: "choice",
                    name: "p_severity",
                    label: "Severity",
                    required: true,
                    choices: ["info", "low", "medium", "high", "critical"].map((s) => ({
                      value: s,
                      label: s,
                    })),
                  },
                  {
                    kind: "choice",
                    name: "p_audience_kind",
                    label: "Audience",
                    required: true,
                    choices: [
                      { value: "role", label: "Everyone holding a role" },
                      { value: "department", label: "A department" },
                      { value: "user", label: "A named person" },
                      { value: "object_owner", label: "Whoever owns the affected object" },
                    ],
                  },
                  {
                    kind: "text",
                    name: "p_role_code",
                    label: "Role code",
                    placeholder: "finance-approver",
                    hint: "Only when the audience is a role. Codes are listed on the Permissions page.",
                  },
                  {
                    kind: "combo",
                    name: "p_department_code",
                    label: "Department code",
                    hint: "Only when the audience is a department.",
                    options: { fn: "erp_departments", value: "code", label: ["code", "name"] },
                  },
                  {
                    kind: "select",
                    name: "p_app_user_id",
                    label: "Person",
                    hint: "Only when the audience is one named person.",
                    options: { fn: "erp_principals", value: "id", label: ["display_name"] },
                  },
                  {
                    kind: "choice",
                    name: "p_channel_kind",
                    label: "Channel",
                    required: true,
                    // sms and push are not offered: the product has no such
                    // channel, and the door refuses them by name rather than
                    // marking a message sent that nothing sent.
                    choices: [
                      { value: "in_app", label: "In app" },
                      { value: "email", label: "Email" },
                      { value: "webhook", label: "Webhook" },
                    ],
                  },
                  {
                    kind: "combo",
                    name: "p_template_code",
                    label: "Template code",
                    hint: "Optional. The wording used for the message.",
                    options: {
                      fn: "erp_output_templates",
                      value: "code",
                      label: ["code", "kind"],
                    },
                  },
                  { kind: "number", name: "p_digest_minutes", label: "Digest every (minutes)" },
                  {
                    kind: "number",
                    name: "p_escalate_after_minutes",
                    label: "Escalate after (minutes)",
                  },
                  {
                    kind: "text",
                    name: "p_escalate_to_role_code",
                    label: "Escalate to role",
                    placeholder: "finance-manager",
                    hint: "Who hears about it if nobody acts in time.",
                  },
                  {
                    kind: "choice",
                    name: "p_is_mandatory",
                    label: "Mandatory",
                    boolean: true,
                    choices: [
                      { value: "false", label: "No" },
                      { value: "true", label: "Yes" },
                    ],
                  },
                ],
                invalidates: ["erp_notification_routes"],
              },
              {
                label: "Switch a route off or on",
                permission: "administration.configure",
                fn: "erp_set_notification_route_status",
                fields: [
                  {
                    kind: "combo",
                    name: "p_code",
                    label: "Route code",
                    required: true,
                    options: {
                      fn: "erp_notification_routes",
                      value: "code",
                      label: ["code", "name"],
                    },
                  },
                  {
                    kind: "choice",
                    name: "p_status",
                    label: "State",
                    required: true,
                    choices: [
                      { value: "active", label: "On" },
                      { value: "inactive", label: "Off" },
                    ],
                  },
                ],
                invalidates: ["erp_notification_routes"],
              },
            ]}
          />

          <ActionBar
            title={ui("Channels")}
            note={ui(
              "Where a message goes when it is not in-app: an email sender, or a webhook that posts to a chat service. A webhook names its URL here and its credential as a reference, never the credential itself.",
            )}
            actions={[
              {
                label: "Configure a channel",
                permission: "administration.configure",
                fn: "erp_upsert_notification_channel",
                mapArgs: (values: Record<string, string>) => ({
                  p_code: values["p_code"],
                  p_name: values["p_name"],
                  p_kind: values["p_kind"],
                  p_settings: values["p_url"] ? { url: values["p_url"] } : {},
                  p_credential_ref: values["p_credential_ref"] || null,
                  p_is_enabled: values["p_is_enabled"] !== "false",
                }),
                fields: [
                  codeField("p_code", "Code", "OPS-WEBHOOK"),
                  {
                    kind: "text",
                    name: "p_name",
                    label: "Name",
                    required: true,
                    placeholder: "Operations webhook",
                  },
                  {
                    kind: "choice",
                    name: "p_kind",
                    label: "Kind",
                    required: true,
                    choices: [
                      { value: "email", label: "Email" },
                      { value: "webhook", label: "Webhook" },
                    ],
                  },
                  {
                    kind: "text",
                    name: "p_url",
                    label: "Where the post goes (webhook only)",
                    hint: "The full https URL. A token in the URL is a credential; put it in the reference below instead.",
                  },
                  {
                    kind: "text",
                    name: "p_credential_ref",
                    label: "Credential reference",
                    hint: "A pointer into a secret store, such as env://OPS_CHAT_TOKEN. Never the secret.",
                  },
                  {
                    kind: "choice",
                    name: "p_is_enabled",
                    label: "Enabled",
                    boolean: true,
                    choices: [
                      { value: "true", label: "Yes" },
                      { value: "false", label: "No" },
                    ],
                  },
                ],
                invalidates: ["erp_notification_channels"],
              },
            ]}
          />

          <DataPanel<ChannelRow>
            title={ui("Configured channels")}
            description={ui(
              "What this organisation has configured. A message routed to a kind with no enabled channel fails with its reason and is delivered in-app instead, so nothing addressed to somebody is lost.",
            )}
            fn="erp_notification_channels"
            empty={ui(
              "No channel is configured, so only in-app delivery works. Add one under Actions above.",
            )}
          >
            {(rows) => (
              <Table columns={["Code", "Name", "Kind", "Where", "State"]}>
                {rows.map((c) => (
                  <tr key={c.id} className="border-b border-border/50 last:border-0">
                    <td className="py-2 pr-4 font-mono text-xs">{c.code}</td>
                    <td className="py-2 pr-4">{c.name}</td>
                    <td className="py-2 pr-4">{c.kind}</td>
                    <td className="py-2 pr-4 text-xs text-muted-foreground">
                      {String(c.settings?.["url"] ?? "—")}
                    </td>
                    <td className="py-2 pr-4">
                      {c.is_enabled ? (
                        <Pill tone="ok">{ui("On")}</Pill>
                      ) : (
                        <Pill tone="muted">{ui("Off")}</Pill>
                      )}
                    </td>
                  </tr>
                ))}
              </Table>
            )}
          </DataPanel>

          <DataPanel<RouteRow>
            title={ui("Routes")}
            description={ui(
              "An event and a severity to an audience: a role, a department, a person, or whoever owns the affected object. A route may digest, escalate on a timer, and be mandatory.",
            )}
            fn="erp_notification_routes"
            empty={ui(
              "No route is defined, so no event reaches anybody. Define one under Actions above.",
            )}
          >
            {(rows) => (
              <Table columns={["Route", "Events", "Audience", "Channel", "Timers", "State"]}>
                {rows.map((r) => (
                  <tr key={r.code} className="border-b border-border/50 align-top last:border-0">
                    <td className="py-2 pr-4 text-sm">
                      {r.name}
                      <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                        {r.code} · {r.severity}
                      </div>
                    </td>
                    <td className="py-2 pr-4 font-mono text-xs">{r.event_pattern}</td>
                    <td className="py-2 pr-4 text-xs">
                      {r.audience_kind}: {r.audience}
                    </td>
                    <td className="py-2 pr-4 text-xs">
                      {r.channel_kind}
                      {r.template_code ? ` · ${r.template_code}` : ""}
                      {r.is_mandatory ? (
                        <div className="mt-1">
                          <Pill tone="warn">mandatory</Pill>
                        </div>
                      ) : null}
                    </td>
                    <td className="py-2 pr-4 text-xs text-muted-foreground">
                      {r.digest_minutes ? `digest ${r.digest_minutes} min` : ""}
                      {r.escalate_after_minutes
                        ? ` escalate ${r.escalate_after_minutes} min → ${r.escalate_to}`
                        : ""}
                    </td>
                    <td className="py-2">
                      <Pill tone={r.status === "active" ? "ok" : "muted"}>{r.status}</Pill>
                    </td>
                  </tr>
                ))}
              </Table>
            )}
          </DataPanel>

          <DataPanel<Health>
            title={ui("Delivery, last seven days")}
            description={ui(
              "Queue depth, the oldest waiting print and the last confirmed one per printer, with the signal §15.4 names when something is wrong.",
            )}
            fn="erp_notification_health"
            empty={ui("Nothing has been delivered in the last seven days.")}
          >
            {(rows) => (
              <Table
                columns={[
                  "Channel",
                  "Pending",
                  "Held",
                  "Sent",
                  "Delivered",
                  "Read",
                  "Failed",
                  "Suppressed",
                ]}
              >
                {rows.map((h) => (
                  <tr key={h.channel_kind} className="border-b border-border/50 last:border-0">
                    <td className="py-2 pr-4 text-sm">{h.channel_kind}</td>
                    <td className="py-2 pr-4 text-xs tabular-nums">
                      {h.pending}
                      {h.oldest_pending_minutes ? ` (${h.oldest_pending_minutes} min)` : ""}
                    </td>
                    <td className="py-2 pr-4 text-xs tabular-nums">{h.held}</td>
                    <td className="py-2 pr-4 text-xs tabular-nums">{h.sent}</td>
                    <td className="py-2 pr-4 text-xs tabular-nums">{h.delivered}</td>
                    <td className="py-2 pr-4 text-xs tabular-nums">{h.read}</td>
                    <td className="py-2 pr-4 text-xs tabular-nums">{h.failed}</td>
                    <td className="py-2 text-xs tabular-nums">{h.suppressed}</td>
                  </tr>
                ))}
              </Table>
            )}
          </DataPanel>
        </>
      ) : null}
    </div>
  );
}

function Inbox() {
  const { ui } = useT();
  const read = useErpAction({
    fn: "erp_mark_notification_read",
    invalidates: ["erp_my_notifications", "erp_my_notification_settings"],
  });
  return (
    <DataPanel<Notification>
      title={ui("Notifications")}
      description={ui(
        "What the product told you, what it held for your quiet hours, and what it could not deliver another way. In-app is the channel that always works; nothing addressed to you is lost because another channel failed.",
      )}
      fn="erp_my_notifications"
      empty={ui("Nothing has been sent to you.")}
    >
      {(rows) => (
        <ul className="flex flex-col gap-3">
          {rows.map((n) => (
            <li key={n.id} className="border-b border-border/50 pb-3 last:border-0 last:pb-0">
              <div className="flex flex-wrap items-center gap-2">
                <span className={`text-sm ${n.status === "read" ? "" : "font-semibold"}`}>
                  {n.subject}
                </span>
                <span className="font-mono text-xs text-muted-foreground">{n.severity}</span>
                <span className="text-xs text-muted-foreground">{n.channel_kind}</span>
                {n.is_escalation ? <Pill tone="bad">{ui("Escalated")}</Pill> : null}
                {n.digest_of > 0 ? <Pill tone="muted">{ui("Digest")}</Pill> : null}
                <Pill
                  tone={
                    n.status === "read"
                      ? "muted"
                      : n.status === "failed" || n.status === "suppressed"
                        ? "bad"
                        : "ok"
                  }
                >
                  {n.status}
                </Pill>
              </div>
              <p className="mt-1 whitespace-pre-wrap text-sm text-muted-foreground">{n.body}</p>
              {n.failure_reason ? <p className="mt-1 text-xs">{n.failure_reason}</p> : null}
              <div className="mt-1 flex items-center gap-3 text-xs text-muted-foreground">
                {when(n.created_at)}
                {n.status === "delivered" || n.status === "sent" ? (
                  <button
                    type="button"
                    className={`${TOUCH} rounded-md border border-input px-3 font-medium`}
                    onClick={() => read.mutate({ p_notification_id: n.id })}
                  >
                    {ui("Mark as read")}
                  </button>
                ) : null}
              </div>
            </li>
          ))}
          {read.error ? <ErrorNote error={read.error} /> : null}
        </ul>
      )}
    </DataPanel>
  );
}

function Preferences({ settings }: { settings: Settings | null }) {
  const { ui } = useT();
  const { session } = useErpSession();
  const queryClient = useQueryClient();
  const setPref = useErpAction({
    fn: "erp_set_notification_preference",
    invalidates: ["erp_my_notification_settings"],
  });
  const setQuiet = useErpAction({
    fn: "erp_set_my_quiet_hours",
    invalidates: ["erp_my_notification_settings"],
    onDone: () =>
      void queryClient.invalidateQueries({ queryKey: ["erp_my_notification_settings"] }),
  });

  const existing = settings?.quiet_hours[0];
  const [days, setDays] = useState<number[]>([1, 2, 3, 4, 5]);
  const [from, setFrom] = useState("19:00");
  const [until, setUntil] = useState("07:00");
  const [timezone, setTimezone] = useState(session.principal?.timezone ?? "UTC");
  const [override, setOverride] = useState("critical");

  useEffect(() => {
    if (existing) {
      setDays(existing.days_of_week);
      setFrom(existing.starts_at.slice(0, 5));
      setUntil(existing.ends_at.slice(0, 5));
      setTimezone(existing.timezone);
      setOverride(existing.override_at_or_above);
    }
  }, [existing]);

  const enabled = (channel: string) =>
    settings?.preferences.find((p) => p.channel_kind === channel)?.is_enabled ?? true;

  return (
    <section className="min-w-0 rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <h2 className="text-sm font-semibold">{ui("Your channels")}</h2>
        <p className="mt-0.5 text-xs text-muted-foreground">
          {ui(
            "Switch a channel off and anything routed to it reaches you here instead; a route your role requires reaches you here regardless.",
          )}
        </p>
      </header>
      <div className="flex flex-col gap-5 px-4 py-4 sm:px-5">
        <div className="flex flex-wrap gap-4">
          {CHANNELS.map((c) => (
            <label key={c} className={`${TOUCH} flex items-center gap-2 text-sm`}>
              <input
                type="checkbox"
                className="h-5 w-5"
                checked={enabled(c)}
                onChange={(e) =>
                  setPref.mutate({ p_channel_kind: c, p_is_enabled: e.target.checked })
                }
              />
              {c}
            </label>
          ))}
          <span className={`${TOUCH} flex items-center gap-2 text-sm text-muted-foreground`}>
            in_app · always on
          </span>
        </div>
        {setPref.error ? <ErrorNote error={setPref.error} /> : null}

        <form
          className="flex flex-col gap-3"
          onSubmit={(e) => {
            e.preventDefault();
            setQuiet.mutate({
              p_days_of_week: days,
              p_starts_at: from,
              p_ends_at: until,
              p_timezone: timezone,
              p_override_at_or_above: override,
            });
          }}
        >
          <h3 className="text-sm font-semibold">{ui("Quiet hours")}</h3>
          <p className="text-xs text-muted-foreground">
            {ui(
              "Between these times on these days, notifications below the override severity wait until the window ends.",
            )}
          </p>
          <fieldset className="flex flex-wrap gap-3">
            <legend className="text-xs font-medium">{ui("Days")}</legend>
            {DAYS.map((d, i) => (
              <label key={d} className={`${TOUCH} flex items-center gap-1 text-sm`}>
                <input
                  type="checkbox"
                  className="h-5 w-5"
                  checked={days.includes(i + 1)}
                  onChange={(e) =>
                    setDays(
                      e.target.checked ? [...days, i + 1].sort() : days.filter((x) => x !== i + 1),
                    )
                  }
                />
                {d}
              </label>
            ))}
          </fieldset>
          <div className="grid gap-3 sm:grid-cols-4">
            <label className="block text-xs font-medium">
              {ui("From")}
              <input
                type="time"
                className={FIELD}
                value={from}
                onChange={(e) => setFrom(e.target.value)}
              />
            </label>
            <label className="block text-xs font-medium">
              {ui("Until")}
              <input
                type="time"
                className={FIELD}
                value={until}
                onChange={(e) => setUntil(e.target.value)}
              />
            </label>
            <label className="block text-xs font-medium">
              {ui("Time zone")}
              <input
                className={FIELD}
                value={timezone}
                onChange={(e) => setTimezone(e.target.value)}
              />
            </label>
            <label className="block text-xs font-medium">
              {ui("Breaks through at or above")}
              <select
                className={FIELD}
                value={override}
                onChange={(e) => setOverride(e.target.value)}
              >
                {["low", "medium", "high", "critical"].map((s) => (
                  <option key={s} value={s}>
                    {s}
                  </option>
                ))}
              </select>
            </label>
          </div>
          <div className="flex flex-wrap gap-2">
            <ActionButton
              type="submit"
              variant="primary"
              disabled={setQuiet.isPending || days.length === 0}
            >
              {ui("Save quiet hours")}
            </ActionButton>
            <ActionButton
              variant="secondary"
              disabled={setQuiet.isPending}
              onClick={() =>
                setQuiet.mutate({
                  p_days_of_week: null,
                  p_starts_at: null,
                  p_ends_at: null,
                  p_timezone: timezone,
                })
              }
            >
              {ui("Clear quiet hours")}
            </ActionButton>
          </div>
          {setQuiet.error ? <ErrorNote error={setQuiet.error} /> : null}
        </form>
      </div>
    </section>
  );
}
