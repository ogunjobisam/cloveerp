import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Siren } from "lucide-react";
import { useState, type ReactNode } from "react";

import { TOUCH } from "../erp/page";
import { Pill, Table } from "../erp/panel";
import { callErp } from "../../lib/erp";
import { Card, Fail, INPUT } from "./kit";

/**
 * Incidents and notices. Specification v1.2 Part 17.
 *
 * Everything an operator does during an incident, in the order §17.3 has it:
 * declare with the three roles, keep the channel warm, contain and say who was
 * reached, name the organisations so they are told and nobody else is, put a
 * security incident on the disclosure path and record each timeline met, and
 * resolve with the review. Maintenance is announced here too, against the
 * published notice period.
 *
 * The console does not decide what an organisation sees; erp_service_notices()
 * does, from the same rows. This screen writes them.
 */

type Incident = {
  code: string;
  severity_code: string;
  title: string;
  state: string;
  declared_at: string;
  contained_at: string | null;
  resolved_at: string | null;
  commander: string;
  communications_owner: string;
  scribe: string;
  scope: string | null;
  affects_all_tenants: boolean | null;
  is_data_integrity: boolean;
  review_url: string | null;
  updates: number;
  minutes_since_update: number | null;
  cadence_minutes: number;
  overdue: boolean;
  next_update_due_at: string | null;
  timer_state: string;
  components: string[];
  organisations: number;
  origin_dependency_code: string | null;
  review_assembled: boolean;
  open_actions: number;
  deliveries: number;
  publications: number;
};

type Component = { code: string; name: string; description: string };

type Communication = {
  incident_code: string;
  kind: string;
  at: string;
  reference: string;
  detail: string;
};

type Action = {
  id: string;
  incident_code: string;
  description: string;
  owner: string;
  due_on: string | null;
  done_at: string | null;
  done_note: string | null;
  created_at: string;
};

type SimilarAction = {
  incident_code: string;
  action_id: string;
  description: string;
  owner: string;
  due_on: string | null;
  shared_component: string;
};

type Dependency = {
  code: string;
  provider: string;
  status_url: string;
  affects_service: boolean;
  components: string[];
  last_observed_at: string | null;
  indicator: string | null;
  description: string | null;
  live_incident_code: string | null;
  observations_24h: number;
};

const TIMER: Record<string, { tone: "ok" | "warn" | "bad" | "muted"; text: string }> = {
  kept: { tone: "ok", text: "On time" },
  due: { tone: "warn", text: "Update due" },
  prompted: { tone: "warn", text: "Owner prompted" },
  escalated_commander: { tone: "bad", text: "Escalated to commander" },
  escalated_owner: { tone: "bad", text: "Escalated to owner" },
  closed: { tone: "muted", text: "Closed" },
  none: { tone: "muted", text: "No timer" },
};

type Disclosure = {
  incident_code: string;
  is_security: boolean;
  obligation_code: string;
  obligation_title: string;
  obliged_party: string;
  due_at: string;
  notified_at: string | null;
  notified_by: string | null;
  overdue: boolean;
  hours_left: number;
};

type Window = {
  code: string;
  title: string;
  detail: string | null;
  starts_at: string;
  ends_at: string;
  announced_at: string;
  announced_by: string;
  is_emergency: boolean;
  emergency_reason: string | null;
  affects_all_tenants: boolean;
  organisations: string[];
  state: string;
  notice_hours: number;
  cancel_reason: string | null;
};

type Severity = { code: string; name: string };

function when(value: string | null) {
  return value ? new Date(value).toLocaleString() : "—";
}

const BUTTON = `${TOUCH} rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground disabled:opacity-60`;

/** A small form that calls one door and refreshes the lists it changes. */
function Act({
  label,
  fn,
  invalidates,
  children,
  build,
}: {
  label: string;
  fn: string;
  invalidates: string[];
  children: ReactNode;
  build: () => Record<string, unknown> | null;
}) {
  const queryClient = useQueryClient();
  const m = useMutation({
    mutationFn: (args: Record<string, unknown>) => callErp(fn, args),
    onSuccess: () => {
      for (const k of invalidates) void queryClient.invalidateQueries({ queryKey: [k] });
    },
  });
  return (
    <form
      className="flex flex-col gap-2 rounded-lg border border-border/60 p-3"
      onSubmit={(e) => {
        e.preventDefault();
        const args = build();
        if (args) m.mutate(args);
      }}
    >
      {children}
      {m.error ? <Fail error={m.error} /> : null}
      {m.isSuccess ? <p className="text-xs text-muted-foreground">Done.</p> : null}
      <button type="submit" className={`${BUTTON} self-start`} disabled={m.isPending}>
        {m.isPending ? "Working…" : label}
      </button>
    </form>
  );
}

export function Incidents() {
  const incidents = useQuery({
    queryKey: ["erp_platform_incidents"],
    queryFn: () => callErp<Incident[]>("erp_platform_incidents"),
  });
  const disclosures = useQuery({
    queryKey: ["erp_platform_disclosures"],
    queryFn: () => callErp<Disclosure[]>("erp_platform_disclosures"),
  });
  const severities = useQuery({
    queryKey: ["erp_support_severities"],
    queryFn: () => callErp<Severity[]>("erp_support_severities"),
    retry: false,
  });
  const components = useQuery({
    queryKey: ["erp_platform_components"],
    queryFn: () => callErp<Component[]>("erp_platform_components"),
  });
  const actions = useQuery({
    queryKey: ["erp_platform_incident_actions"],
    queryFn: () => callErp<Action[]>("erp_platform_incident_actions"),
  });
  const dependencies = useQuery({
    queryKey: ["erp_platform_dependencies"],
    queryFn: () => callErp<Dependency[]>("erp_platform_dependencies"),
  });

  const [code, setCode] = useState("");
  const [severity, setSeverity] = useState("sev2");
  const [title, setTitle] = useState("");
  const [commander, setCommander] = useState("");
  const [comms, setComms] = useState("");
  const [scribe, setScribe] = useState("");
  const [integrity, setIntegrity] = useState(false);

  const [chosen, setChosen] = useState<string[]>([]);
  const [declareOrgs, setDeclareOrgs] = useState("");
  const [declareEveryone, setDeclareEveryone] = useState(false);
  const [promise, setPromise] = useState("");

  const [target, setTarget] = useState("");
  const [body, setBody] = useState("");
  const [noChange, setNoChange] = useState(false);
  const [affected, setAffected] = useState("");
  const [notAffected, setNotAffected] = useState("");
  const [beingDone, setBeingDone] = useState("");
  const [meanwhile, setMeanwhile] = useState("");
  const [nextMinutes, setNextMinutes] = useState("");
  const [actionText, setActionText] = useState("");
  const [actionOwner, setActionOwner] = useState("");
  const [actionDue, setActionDue] = useState("");
  const [doneNote, setDoneNote] = useState("");
  const communication = useQuery({
    queryKey: ["erp_platform_incident_communication", target],
    queryFn: () =>
      callErp<Communication[]>("erp_platform_incident_communication", { p_code: target || null }),
    enabled: Boolean(target),
  });
  const reached = useQuery({
    queryKey: ["erp_platform_incident_organisations", target],
    queryFn: () =>
      callErp<{ tenant_code: string; named_at: string; named_by: string | null }[] | null>(
        "erp_platform_incident_organisations",
        { p_incident_code: target },
      ),
    enabled: Boolean(target),
  });
  const similar = useQuery({
    queryKey: ["erp_platform_similar_incident_actions", target],
    queryFn: () =>
      callErp<SimilarAction[]>("erp_platform_similar_incident_actions", { p_code: target }),
    enabled: Boolean(target),
  });
  const [scope, setScope] = useState("");
  const [everyone, setEveryone] = useState(false);
  const [orgs, setOrgs] = useState("");
  const [review, setReview] = useState("");
  const [obligation, setObligation] = useState("security_disclosure_to_organisation");
  const [note, setNote] = useState("");

  const sevOptions = severities.data ?? [
    { code: "sev1", name: "Severity 1" },
    { code: "sev2", name: "Severity 2" },
    { code: "sev3", name: "Severity 3" },
    { code: "sev4", name: "Severity 4" },
  ];

  return (
    <div className="flex flex-col gap-6">
      <Card
        title="Incidents"
        icon={<Siren className="size-4 text-primary" />}
        description="Declared, not drifted into. Communication is on a timer and scoped to who was reached: a named organisation is told, an unnamed one is not alarmed."
      >
        {incidents.isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : incidents.error ? (
          <Fail error={incidents.error} />
        ) : (incidents.data ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">No incident has been declared.</p>
        ) : (
          <Table columns={["Incident", "State", "Communication", "Scope"]}>
            {incidents.data!.map((r) => (
              <tr key={r.code} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4">
                  <div className="text-sm">{r.title}</div>
                  <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                    {r.code} · {r.severity_code} · {when(r.declared_at)}
                  </div>
                  {r.is_data_integrity ? (
                    <div className="mt-1">
                      <Pill tone="bad">Data integrity</Pill>
                    </div>
                  ) : null}
                </td>
                <td className="py-2 pr-4">
                  {r.state === "resolved" ? (
                    <Pill tone="ok">Resolved</Pill>
                  ) : r.state === "contained" ? (
                    <Pill tone="muted">Contained</Pill>
                  ) : (
                    <Pill tone="bad">Live</Pill>
                  )}
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {r.updates} update{r.updates === 1 ? "" : "s"} · every {r.cadence_minutes} min
                  {r.next_update_due_at && r.state !== "resolved"
                    ? ` · next by ${when(r.next_update_due_at)}`
                    : ""}
                  <div className="mt-1 flex flex-wrap gap-1">
                    {r.overdue ? <Pill tone="bad">Overdue an update</Pill> : null}
                    {r.state !== "resolved" && TIMER[r.timer_state] ? (
                      <Pill tone={TIMER[r.timer_state]!.tone}>{TIMER[r.timer_state]!.text}</Pill>
                    ) : null}
                  </div>
                  <div className="mt-1">
                    {r.deliveries} delivered · {r.publications} published
                    {r.open_actions > 0 ? ` · ${r.open_actions} open action(s)` : ""}
                    {r.review_assembled ? " · review assembled" : ""}
                  </div>
                </td>
                <td className="py-2 text-xs text-muted-foreground">
                  {r.scope ?? "not yet contained"}
                  {r.affects_all_tenants ? " · everyone" : ""}
                  {r.organisations > 0 ? ` · ${r.organisations} named` : ""}
                  {r.components.length > 0 ? (
                    <div className="mt-0.5">{r.components.join(", ")}</div>
                  ) : null}
                  {r.origin_dependency_code ? (
                    <div className="mt-0.5">Origin: {r.origin_dependency_code}</div>
                  ) : null}
                </td>
              </tr>
            ))}
          </Table>
        )}

        <div className="mt-5 grid gap-3 md:grid-cols-2">
          <Act
            label="Declare"
            fn="erp_platform_declare_incident"
            invalidates={["erp_platform_incidents"]}
            build={() =>
              code && title && commander && comms && scribe
                ? {
                    p_code: code,
                    p_severity_code: severity,
                    p_title: title,
                    p_commander: commander,
                    p_communications_owner: comms,
                    p_scribe: scribe,
                    p_is_data_integrity: integrity,
                    p_affects_all_tenants: declareEveryone ? true : null,
                    p_components: chosen.length > 0 ? chosen : null,
                    p_tenant_codes: declareOrgs.trim()
                      ? declareOrgs
                          .split(",")
                          .map((s) => s.trim())
                          .filter(Boolean)
                      : null,
                    p_next_update_minutes: promise ? Number(promise) : null,
                  }
                : null
            }
          >
            <p className="text-sm font-medium">Declare an incident</p>
            <label className="block text-xs font-medium">
              Code
              <input className={INPUT} value={code} onChange={(e) => setCode(e.target.value)} />
            </label>
            <label className="block text-xs font-medium">
              Severity
              <select
                className={INPUT}
                value={severity}
                onChange={(e) => setSeverity(e.target.value)}
              >
                {sevOptions.map((s) => (
                  <option key={s.code} value={s.code}>
                    {s.name}
                  </option>
                ))}
              </select>
            </label>
            <label className="block text-xs font-medium">
              Title
              <input className={INPUT} value={title} onChange={(e) => setTitle(e.target.value)} />
            </label>
            <label className="block text-xs font-medium">
              Commander
              <input
                className={INPUT}
                value={commander}
                onChange={(e) => setCommander(e.target.value)}
              />
            </label>
            <label className="block text-xs font-medium">
              Communications owner
              <input className={INPUT} value={comms} onChange={(e) => setComms(e.target.value)} />
            </label>
            <label className="block text-xs font-medium">
              Scribe
              <input className={INPUT} value={scribe} onChange={(e) => setScribe(e.target.value)} />
            </label>
            <label className="flex items-center gap-2 text-xs">
              <input
                type="checkbox"
                checked={integrity}
                onChange={(e) => setIntegrity(e.target.checked)}
              />
              Data integrity is in question: stop the affected path rather than keep trading
            </label>
            <fieldset className="text-xs">
              <legend className="font-medium">Components touched</legend>
              <div className="mt-1 flex flex-wrap gap-x-3 gap-y-1">
                {(components.data ?? []).map((c) => (
                  <label key={c.code} className="flex items-center gap-1" title={c.description}>
                    <input
                      type="checkbox"
                      checked={chosen.includes(c.code)}
                      onChange={(e) =>
                        setChosen((prev) =>
                          e.target.checked ? [...prev, c.code] : prev.filter((x) => x !== c.code),
                        )
                      }
                    />
                    {c.name}
                  </label>
                ))}
              </div>
            </fieldset>
            <label className="flex items-center gap-2 text-xs">
              <input
                type="checkbox"
                checked={declareEveryone}
                onChange={(e) => setDeclareEveryone(e.target.checked)}
              />
              It reaches every organisation — say so now, not at containment
            </label>
            <label className="block text-xs font-medium">
              Organisations reached, comma separated (told the moment you declare)
              <input
                className={INPUT}
                value={declareOrgs}
                onChange={(e) => setDeclareOrgs(e.target.value)}
              />
            </label>
            <label className="block text-xs font-medium">
              First update promised in (minutes; the severity's cadence if blank)
              <input
                className={INPUT}
                inputMode="numeric"
                value={promise}
                onChange={(e) => setPromise(e.target.value)}
              />
            </label>
            {target && (similar.data ?? []).length > 0 ? (
              <div className="rounded-md border border-amber-500/40 bg-amber-500/5 p-2 text-xs">
                <p className="font-medium">Open actions on the same components</p>
                <ul className="mt-1 flex flex-col gap-0.5">
                  {similar.data!.map((a) => (
                    <li key={a.action_id}>
                      {a.incident_code} · {a.shared_component}: {a.description} — {a.owner}
                      {a.due_on ? ` (due ${a.due_on})` : ""}
                    </li>
                  ))}
                </ul>
              </div>
            ) : null}
          </Act>

          <div className="flex flex-col gap-3">
            <label className="block text-xs font-medium">
              Incident code the actions below apply to
              <input className={INPUT} value={target} onChange={(e) => setTarget(e.target.value)} />
            </label>
            <Act
              label="Post update"
              fn="erp_platform_post_incident_update"
              invalidates={["erp_platform_incidents"]}
              build={() =>
                target && (body || affected || notAffected || beingDone || meanwhile)
                  ? {
                      p_code: target,
                      p_body: body || null,
                      p_is_no_change: noChange,
                      p_affected: affected || null,
                      p_not_affected: notAffected || null,
                      p_being_done: beingDone || null,
                      p_meanwhile: meanwhile || null,
                      p_next_update_minutes: nextMinutes ? Number(nextMinutes) : null,
                    }
                  : null
              }
            >
              <p className="text-xs text-muted-foreground">
                Five fields, rendered once into the text every channel carries: the banner, the
                email, the status page and the history.
              </p>
              <label className="block text-xs font-medium">
                Affected
                <input
                  className={INPUT}
                  value={affected}
                  onChange={(e) => setAffected(e.target.value)}
                />
              </label>
              <label className="block text-xs font-medium">
                Not affected
                <input
                  className={INPUT}
                  value={notAffected}
                  onChange={(e) => setNotAffected(e.target.value)}
                />
              </label>
              <label className="block text-xs font-medium">
                What is being done
                <input
                  className={INPUT}
                  value={beingDone}
                  onChange={(e) => setBeingDone(e.target.value)}
                />
              </label>
              <label className="block text-xs font-medium">
                Meanwhile (what the organisation can do)
                <input
                  className={INPUT}
                  value={meanwhile}
                  onChange={(e) => setMeanwhile(e.target.value)}
                />
              </label>
              <label className="block text-xs font-medium">
                Next update in (minutes, within the cadence)
                <input
                  className={INPUT}
                  inputMode="numeric"
                  value={nextMinutes}
                  onChange={(e) => setNextMinutes(e.target.value)}
                />
              </label>
              <label className="block text-xs font-medium">
                In prose, if the fields do not fit
                <textarea
                  className={INPUT}
                  rows={2}
                  value={body}
                  onChange={(e) => setBody(e.target.value)}
                />
              </label>
              <label className="flex items-center gap-2 text-xs">
                <input
                  type="checkbox"
                  checked={noChange}
                  onChange={(e) => setNoChange(e.target.checked)}
                />
                Nothing has changed, and saying so is the update
              </label>
            </Act>
            <Act
              label="Name affected organisations"
              fn="erp_platform_name_affected_organisations"
              invalidates={["erp_platform_incidents"]}
              build={() =>
                target && orgs.trim()
                  ? {
                      p_incident_code: target,
                      p_tenant_codes: orgs
                        .split(",")
                        .map((s) => s.trim())
                        .filter(Boolean),
                    }
                  : null
              }
            >
              <label className="block text-xs font-medium">
                Organisation codes, comma separated
                <input className={INPUT} value={orgs} onChange={(e) => setOrgs(e.target.value)} />
              </label>
              {/* Who has been named so far, from the record rather than from
                  memory of what was typed. */}
              <p className="text-xs text-muted-foreground">
                {reached.isPending
                  ? "Reading the organisations reached…"
                  : (reached.data ?? []).length === 0
                    ? "Nobody named yet: everyone, or nobody, depending on the scope declared."
                    : `Named: ${(reached.data ?? []).map((o) => o.tenant_code).join(", ")}`}
              </p>
            </Act>
            <Act
              label="Contain"
              fn="erp_platform_contain_incident"
              invalidates={["erp_platform_incidents"]}
              build={() =>
                target && scope
                  ? { p_code: target, p_scope: scope, p_affects_all_tenants: everyone }
                  : null
              }
            >
              <label className="block text-xs font-medium">
                What it reached
                <input className={INPUT} value={scope} onChange={(e) => setScope(e.target.value)} />
              </label>
              <label className="flex items-center gap-2 text-xs">
                <input
                  type="checkbox"
                  checked={everyone}
                  onChange={(e) => setEveryone(e.target.checked)}
                />
                It reached every organisation
              </label>
            </Act>
            <Act
              label="Flag as a security incident"
              fn="erp_platform_flag_security_incident"
              invalidates={["erp_platform_incidents", "erp_platform_disclosures"]}
              build={() => (target ? { p_incident_code: target } : null)}
            >
              <p className="text-xs text-muted-foreground">
                Dates every published disclosure timeline from the declaration.
              </p>
            </Act>
            <Act
              label="Record disclosure"
              fn="erp_platform_record_disclosure"
              invalidates={["erp_platform_disclosures"]}
              build={() =>
                target
                  ? { p_incident_code: target, p_obligation_code: obligation, p_note: note || null }
                  : null
              }
            >
              <label className="block text-xs font-medium">
                Timeline met
                <select
                  className={INPUT}
                  value={obligation}
                  onChange={(e) => setObligation(e.target.value)}
                >
                  <option value="security_disclosure_to_organisation">
                    The platform told the organisation
                  </option>
                </select>
              </label>
              <label className="block text-xs font-medium">
                Note
                <input className={INPUT} value={note} onChange={(e) => setNote(e.target.value)} />
              </label>
            </Act>
            <Act
              label="Resolve"
              fn="erp_platform_resolve_incident"
              invalidates={["erp_platform_incidents"]}
              build={() => (target ? { p_code: target, p_review_url: review || null } : null)}
            >
              <label className="block text-xs font-medium">
                Post-incident review link (severity 1 and 2 need a link or an assembled review)
                <input
                  className={INPUT}
                  value={review}
                  onChange={(e) => setReview(e.target.value)}
                />
              </label>
            </Act>
            <Act
              label="Assemble the review"
              fn="erp_platform_assemble_incident_review"
              invalidates={["erp_platform_incidents", "erp_platform_incident_communication"]}
              build={() => (target ? { p_code: target } : null)}
            >
              <p className="text-xs text-muted-foreground">
                Built from what was actually said and when: the updates, the prompts the timer
                recorded, the organisations reached and the actions. Shared with those organisations
                through their history.
              </p>
            </Act>
            <Act
              label="Add an action"
              fn="erp_platform_add_incident_action"
              invalidates={["erp_platform_incident_actions", "erp_platform_incidents"]}
              build={() =>
                target && actionText && actionOwner
                  ? {
                      p_code: target,
                      p_description: actionText,
                      p_owner: actionOwner,
                      p_due_on: actionDue || null,
                    }
                  : null
              }
            >
              <label className="block text-xs font-medium">
                Action
                <input
                  className={INPUT}
                  value={actionText}
                  onChange={(e) => setActionText(e.target.value)}
                />
              </label>
              <label className="block text-xs font-medium">
                Owner
                <input
                  className={INPUT}
                  value={actionOwner}
                  onChange={(e) => setActionOwner(e.target.value)}
                />
              </label>
              <label className="block text-xs font-medium">
                Due
                <input
                  className={INPUT}
                  type="date"
                  value={actionDue}
                  onChange={(e) => setActionDue(e.target.value)}
                />
              </label>
            </Act>
          </div>
        </div>
      </Card>

      <Card
        title="Communication"
        description="What each incident said to whom: every delivery to an organisation, every publication to a status page, every prompt the timer recorded, every action tracked. Choose an incident code above."
      >
        {!target ? (
          <p className="text-sm text-muted-foreground">
            Type an incident code above to read its record.
          </p>
        ) : communication.isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : communication.error ? (
          <Fail error={communication.error} />
        ) : (communication.data ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">
            Nothing has been delivered, published or prompted for {target} yet. The platform sweep
            delivers within a minute on a scheduled host.
          </p>
        ) : (
          <Table columns={["When", "Kind", "Reference", "Detail"]}>
            {communication.data!.map((c, n) => (
              <tr key={n} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4 text-xs">{when(c.at)}</td>
                <td className="py-2 pr-4 text-xs">{c.kind}</td>
                <td className="py-2 pr-4 font-mono text-xs">{c.reference}</td>
                <td className="py-2 text-xs text-muted-foreground">{c.detail}</td>
              </tr>
            ))}
          </Table>
        )}
      </Card>

      <Card
        title="Actions"
        description="Tracked to completion, because a review whose actions nobody did is the next incident's first line."
      >
        {actions.isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : actions.error ? (
          <Fail error={actions.error} />
        ) : (actions.data ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">No action is tracked.</p>
        ) : (
          <>
            <Table columns={["Incident", "Action", "Owner", "Due", "State"]}>
              {actions.data!.map((a) => (
                <tr key={a.id} className="border-b border-border/50 align-top last:border-0">
                  <td className="py-2 pr-4 font-mono text-xs">{a.incident_code}</td>
                  <td className="py-2 pr-4 text-sm">
                    {a.description}
                    {a.done_note ? (
                      <div className="mt-0.5 text-xs text-muted-foreground">{a.done_note}</div>
                    ) : null}
                  </td>
                  <td className="py-2 pr-4 text-xs">{a.owner}</td>
                  <td className="py-2 pr-4 text-xs">{a.due_on ?? "—"}</td>
                  <td className="py-2">
                    {a.done_at ? (
                      <Pill tone="ok">Done</Pill>
                    ) : a.due_on && new Date(a.due_on) < new Date() ? (
                      <Pill tone="bad">Overdue</Pill>
                    ) : (
                      <Pill tone="warn">Open</Pill>
                    )}
                  </td>
                </tr>
              ))}
            </Table>
            <div className="mt-3">
              <Act
                label="Mark done"
                fn="erp_platform_complete_incident_action"
                invalidates={["erp_platform_incident_actions", "erp_platform_incidents"]}
                build={() => {
                  const open = (actions.data ?? []).find((a) => !a.done_at);
                  return open && doneNote ? { p_action_id: open.id, p_note: doneNote } : null;
                }}
              >
                <p className="text-xs text-muted-foreground">
                  Closes the oldest open action with a note saying what was done.
                </p>
                <label className="block text-xs font-medium">
                  What was done
                  <input
                    className={INPUT}
                    value={doneNote}
                    onChange={(e) => setDoneNote(e.target.value)}
                  />
                </label>
              </Act>
            </div>
          </>
        )}
      </Card>

      <Card
        title="Providers below the platform"
        description="What each provider's status feed last said. A major or critical indicator declares an incident here with the origin stated; recovery resolves it. A feed never observed means the poll job is not scheduled in the platform organisation."
      >
        {dependencies.isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : dependencies.error ? (
          <Fail error={dependencies.error} />
        ) : (
          <Table columns={["Provider", "Carries", "Last observed", "Indicator", "Incident"]}>
            {(dependencies.data ?? []).map((d) => (
              <tr key={d.code} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4 text-sm">
                  {d.provider}
                  <div className="mt-0.5 text-xs text-muted-foreground">
                    <a href={d.status_url} target="_blank" rel="noreferrer" className="underline">
                      {d.status_url}
                    </a>
                  </div>
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {d.affects_service ? d.components.join(", ") || "—" : "nothing operational"}
                </td>
                <td className="py-2 pr-4 text-xs">
                  {d.last_observed_at ? when(d.last_observed_at) : "never"}
                  {d.observations_24h > 0 ? (
                    <div className="mt-0.5 text-muted-foreground">{d.observations_24h} in 24 h</div>
                  ) : null}
                </td>
                <td className="py-2 pr-4">
                  {d.indicator === null ? (
                    <Pill tone="muted">Unobserved</Pill>
                  ) : d.indicator === "none" ? (
                    <Pill tone="ok">Operational</Pill>
                  ) : d.indicator === "minor" ? (
                    <Pill tone="warn">Minor</Pill>
                  ) : d.indicator === "unknown" ? (
                    <Pill tone="muted">Unreadable</Pill>
                  ) : (
                    <Pill tone="bad">{d.indicator}</Pill>
                  )}
                  {d.description ? (
                    <div className="mt-0.5 text-xs text-muted-foreground">{d.description}</div>
                  ) : null}
                </td>
                <td className="py-2 font-mono text-xs">{d.live_incident_code ?? "—"}</td>
              </tr>
            ))}
          </Table>
        )}
      </Card>

      <Card
        title="Disclosure obligations"
        description="Every security incident's timelines, dated from its declaration. The platform records its own; the organisation's are shown to it with the clock running, and the discipline report fails a platform deadline that passed unrecorded."
      >
        {disclosures.isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : disclosures.error ? (
          <Fail error={disclosures.error} />
        ) : (disclosures.data ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">No incident is on the disclosure path.</p>
        ) : (
          <Table columns={["Incident", "Obligation", "Who", "Due", "State"]}>
            {disclosures.data!.map((d) => (
              <tr
                key={`${d.incident_code}-${d.obligation_code}`}
                className="border-b border-border/50 align-top last:border-0"
              >
                <td className="py-2 pr-4 font-mono text-xs">{d.incident_code}</td>
                <td className="py-2 pr-4 text-sm">{d.obligation_title}</td>
                <td className="py-2 pr-4 text-xs">{d.obliged_party}</td>
                <td className="py-2 pr-4 text-xs">
                  {when(d.due_at)}
                  {d.notified_at === null ? (
                    <div className="mt-0.5 text-muted-foreground">{d.hours_left} h left</div>
                  ) : null}
                </td>
                <td className="py-2">
                  {d.notified_at ? (
                    <Pill tone="ok">Recorded</Pill>
                  ) : d.overdue ? (
                    <Pill tone="bad">Overdue</Pill>
                  ) : (
                    <Pill tone="warn">Open</Pill>
                  )}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </Card>

      <Maintenance />
    </div>
  );
}

function Maintenance() {
  const windows = useQuery({
    queryKey: ["erp_platform_maintenance_windows"],
    queryFn: () => callErp<Window[]>("erp_platform_maintenance_windows"),
  });
  const [code, setCode] = useState("");
  const [title, setTitle] = useState("");
  const [detail, setDetail] = useState("");
  const [starts, setStarts] = useState("");
  const [ends, setEnds] = useState("");
  const [everyone, setEveryone] = useState(true);
  const [orgs, setOrgs] = useState("");
  const [emergency, setEmergency] = useState(false);
  const [reason, setReason] = useState("");
  const [cancelCode, setCancelCode] = useState("");
  const [cancelReason, setCancelReason] = useState("");

  return (
    <Card
      title="Maintenance windows"
      description="Planned maintenance is announced at least two days ahead, against the published notice period. Inside it, only an emergency with its reason, and it reads as one to every organisation it touches."
    >
      {windows.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : windows.error ? (
        <Fail error={windows.error} />
      ) : (windows.data ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">No maintenance has been announced.</p>
      ) : (
        <Table columns={["Window", "When", "Notice", "For", "State"]}>
          {windows.data!.map((w) => (
            <tr key={w.code} className="border-b border-border/50 align-top last:border-0">
              <td className="py-2 pr-4">
                <div className="text-sm">{w.title}</div>
                <div className="mt-0.5 font-mono text-xs text-muted-foreground">{w.code}</div>
                {w.is_emergency ? (
                  <div className="mt-1 text-xs">
                    <Pill tone="bad">Emergency</Pill> {w.emergency_reason}
                  </div>
                ) : null}
              </td>
              <td className="py-2 pr-4 text-xs">
                {when(w.starts_at)}
                <div className="text-muted-foreground">to {when(w.ends_at)}</div>
              </td>
              <td className="py-2 pr-4 text-xs tabular-nums">{w.notice_hours} h</td>
              <td className="py-2 pr-4 text-xs">
                {w.affects_all_tenants ? "everyone" : w.organisations.join(", ")}
              </td>
              <td className="py-2">
                {w.state === "cancelled" ? (
                  <Pill tone="muted">Cancelled</Pill>
                ) : w.state === "past" ? (
                  <Pill tone="muted">Past</Pill>
                ) : w.state === "in_progress" ? (
                  <Pill tone="warn">In progress</Pill>
                ) : (
                  <Pill tone="ok">Planned</Pill>
                )}
                {w.cancel_reason ? (
                  <div className="mt-0.5 text-xs text-muted-foreground">{w.cancel_reason}</div>
                ) : null}
              </td>
            </tr>
          ))}
        </Table>
      )}

      <div className="mt-5 grid gap-3 md:grid-cols-2">
        <Act
          label="Announce"
          fn="erp_platform_announce_maintenance"
          invalidates={["erp_platform_maintenance_windows"]}
          build={() =>
            code && title && starts && ends
              ? {
                  p_code: code,
                  p_title: title,
                  p_detail: detail || null,
                  p_starts_at: new Date(starts).toISOString(),
                  p_ends_at: new Date(ends).toISOString(),
                  p_affects_all_tenants: everyone,
                  p_tenant_codes: everyone
                    ? null
                    : orgs
                        .split(",")
                        .map((s) => s.trim())
                        .filter(Boolean),
                  p_is_emergency: emergency,
                  p_emergency_reason: emergency ? reason : null,
                }
              : null
          }
        >
          <p className="text-sm font-medium">Announce maintenance</p>
          <label className="block text-xs font-medium">
            Code
            <input className={INPUT} value={code} onChange={(e) => setCode(e.target.value)} />
          </label>
          <label className="block text-xs font-medium">
            Title
            <input className={INPUT} value={title} onChange={(e) => setTitle(e.target.value)} />
          </label>
          <label className="block text-xs font-medium">
            What to expect
            <input className={INPUT} value={detail} onChange={(e) => setDetail(e.target.value)} />
          </label>
          <label className="block text-xs font-medium">
            Starts
            <input
              type="datetime-local"
              className={INPUT}
              value={starts}
              onChange={(e) => setStarts(e.target.value)}
            />
          </label>
          <label className="block text-xs font-medium">
            Ends
            <input
              type="datetime-local"
              className={INPUT}
              value={ends}
              onChange={(e) => setEnds(e.target.value)}
            />
          </label>
          <label className="flex items-center gap-2 text-xs">
            <input
              type="checkbox"
              checked={everyone}
              onChange={(e) => setEveryone(e.target.checked)}
            />
            Every organisation
          </label>
          {!everyone ? (
            <label className="block text-xs font-medium">
              Organisation codes, comma separated
              <input className={INPUT} value={orgs} onChange={(e) => setOrgs(e.target.value)} />
            </label>
          ) : null}
          <label className="flex items-center gap-2 text-xs">
            <input
              type="checkbox"
              checked={emergency}
              onChange={(e) => setEmergency(e.target.checked)}
            />
            Emergency: inside the notice period, with a reason
          </label>
          {emergency ? (
            <label className="block text-xs font-medium">
              Why it cannot wait
              <input className={INPUT} value={reason} onChange={(e) => setReason(e.target.value)} />
            </label>
          ) : null}
        </Act>
        <Act
          label="Cancel window"
          fn="erp_platform_cancel_maintenance"
          invalidates={["erp_platform_maintenance_windows"]}
          build={() =>
            cancelCode && cancelReason ? { p_code: cancelCode, p_reason: cancelReason } : null
          }
        >
          <p className="text-sm font-medium">Cancel a window</p>
          <label className="block text-xs font-medium">
            Code
            <input
              className={INPUT}
              value={cancelCode}
              onChange={(e) => setCancelCode(e.target.value)}
            />
          </label>
          <label className="block text-xs font-medium">
            Why
            <input
              className={INPUT}
              value={cancelReason}
              onChange={(e) => setCancelReason(e.target.value)}
            />
          </label>
        </Act>
      </div>
    </Card>
  );
}
