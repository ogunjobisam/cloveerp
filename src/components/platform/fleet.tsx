import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { ChevronDown, ChevronRight, ExternalLink, Rocket, Server } from "lucide-react";

import { Pill, Table } from "../erp/panel";
import { TOUCH } from "../erp/page";
import { APEX_HOST } from "../../lib/backend";
import { callErp } from "../../lib/erp";
import {
  atLeast,
  buildRequestIsStale,
  CHECKLIST_ITEMS,
  dayText,
  deploymentAddress,
  deploymentHealthLine,
  deploymentLifecycleNotes,
  deploymentOrigin,
  earliestPurgeDate,
  fleetActions,
  isDeploymentAddress,
  lastExportText,
  OFFBOARDING_COOL_OFF_DAYS,
  STALE_BUILD_REQUEST_MINUTES,
  SWEEP_STARTS,
  type ChecklistItem,
  type ClientDeployment,
  type ClientDeploymentStatus,
  type DeploymentEvent,
  type HealthLine,
  type HealthTone,
  type LifecycleNote,
  type PlatformRole,
} from "../../lib/platform";
import { FormDialog } from "./dialogs";
import { Card, Fail, INPUT, LINK_BUTTON } from "./kit";

/**
 * The register of client deployments: one Supabase project per client, one
 * subdomain each (the owner's decision of 7 October, 20261011020000).
 *
 * Everything here is the control plane's. A client's own console — at
 * <code>.cloveerp.com/platform, which the owner reaches from a row — is where
 * its organisation is onboarded, its people invited and its support given; a
 * client's database holds one customer and knows nothing of the others.
 *
 * The console holds no token for GitHub. Asking for a build, or for a release
 * train, writes a request; the control plane wakes the sweep (fleet_sweep.yml)
 * at once when it has been given the means to, and the sweep's ten-minute
 * schedule finds the request otherwise (SWEEP_STARTS). The row then follows
 * the run through the events the workflow records on it, so a build's
 * progress is read here and not in a run log.
 *
 * A row whose project is up also says what the fleet poll last read from
 * the client's own database (deploymentHealthLine), and says so when the poll
 * has not heard from it for a day.
 *
 * And a client can be paused, moved and let go (20261012020000), each from
 * its row and each with a reason: suspended, its address shows only that its
 * service is suspended while its project keeps running and receiving
 * releases; renamed, it gets a new address while its code stays, and the old
 * one sends people on for ninety days; offboarded, its database is exported
 * off the platform and its project is due to be purged thirty days after its
 * contract's term ends. What a row offers is decided by fleetActions in
 * src/lib/platform.ts, by its state and the viewer's rank; the doors decide
 * regardless.
 */

/** Where a run's log is: the repository the workflows run in. */
const RUN_URL = "https://github.com/ogunjobisam/cloveerp/actions/runs/";

const ACTIVE: ReadonlySet<ClientDeploymentStatus> = new Set(["requested", "creating", "building"]);

/** The states a release goes to (deploy.yml's targets, 20261012020000). */
const RELEASED: ReadonlySet<ClientDeploymentStatus> = new Set([
  "built",
  "live",
  "suspended",
  "retiring",
]);

function statusTone(status: ClientDeploymentStatus): "ok" | "warn" | "bad" | "muted" {
  if (status === "live") return "ok";
  if (status === "failed") return "bad";
  if (status === "suspended" || status === "retiring") return "warn";
  return "muted";
}

function statusWord(d: ClientDeployment): string {
  if (d.status === "requested" && d.request_status === "requested") return "Queued";
  if (d.status === "requested" && d.request_status === "claimed") return "Starting";
  if (d.status === "retiring") return "Offboarding";
  return d.status.charAt(0).toUpperCase() + d.status.slice(1);
}

function when(iso: string | null): string {
  return iso ? new Date(iso).toLocaleString() : "—";
}

const TONE_TEXT: Record<HealthTone, string> = {
  ok: "text-emerald-700 dark:text-emerald-400",
  warn: "text-amber-700 dark:text-amber-400",
  bad: "text-destructive",
  muted: "text-muted-foreground",
};

export function Fleet({ role }: { role: PlatformRole }) {
  const queryClient = useQueryClient();
  const mayOperate = atLeast(role, "operator");
  const isOwner = atLeast(role, "owner");

  const fleet = useQuery({
    queryKey: ["erp_platform_deployments"],
    queryFn: () => callErp<ClientDeployment[]>("erp_platform_deployments"),
    // While something is queued or building, follow it: the workflow writes
    // an event per step, and ten seconds is how long a step takes to show.
    refetchInterval: (q) =>
      (q.state.data ?? []).some((d) => ACTIVE.has(d.status)) ? 10_000 : false,
  });

  const refresh = () => queryClient.invalidateQueries({ queryKey: ["erp_platform_deployments"] });

  const rows = fleet.data ?? [];
  // Whether a request has stalled is a matter of time as well as of the row.
  // Reading when the list was last fetched makes every refetch redraw the
  // rows, even one that changed nothing, so Start again appears on time.
  const now = new Date(Math.max(Date.now(), fleet.dataUpdatedAt));

  return (
    <div className="flex flex-col gap-5">
      {isOwner ? (
        <Card
          title="Request a client deployment"
          icon={<Server className="size-4 text-primary" />}
          description="Makes the client a Supabase project of its own, builds it from every migration, and proves it — about four hours. Its address answers as soon as it is built: every subdomain is served by the one application, so there is no domain or DNS record to add."
          action={<RequestDeployment onDone={refresh} />}
        >
          <p className="text-sm text-muted-foreground">
            The code becomes the client&apos;s address,{" "}
            <code className="rounded bg-muted px-1 py-0.5 font-mono text-xs">
              code.cloveerp.com
            </code>
            , and is held once across the fleet. Nobody is invited by the build: the first
            administrator is onboarded from the client&apos;s own console once it is live.
          </p>
        </Card>
      ) : null}

      {isOwner ? (
        <Card
          title="Release"
          icon={<Rocket className="size-4 text-primary" />}
          description="A release train goes to the demonstration first, then to every client at once, then to the control plane last; a client that fails stops the control plane. Every merge still releases the demonstration on its own."
          action={<RequestRelease deployments={rows} onDone={refresh} />}
        >
          <p className="text-sm text-muted-foreground">
            Start one at the end of a sprint, or whenever a fix cannot wait. The application follows
            on its own once every database carries the commit, so nothing needs publishing.
          </p>
        </Card>
      ) : null}

      <Card
        title="Client deployments"
        icon={<Server className="size-4 text-primary" />}
        description="Every client on a project of its own, from requested to live. Open a client's console to onboard its organisation, invite its people or support them; everything about one client happens there."
      >
        {fleet.isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : fleet.error ? (
          <Fail error={fleet.error} />
        ) : rows.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            No client deployment yet. Requesting one is the first thing to do.
          </p>
        ) : (
          <Table
            columns={[
              "Client",
              "Address",
              "State",
              "Project",
              "Last release",
              "By hand",
              "Actions",
            ]}
          >
            {rows.map((d) => (
              <DeploymentRow
                key={d.code}
                d={d}
                role={role}
                mayOperate={mayOperate}
                now={now}
                onDone={refresh}
              />
            ))}
          </Table>
        )}
      </Card>
    </div>
  );
}

function DeploymentRow({
  d,
  role,
  mayOperate,
  now,
  onDone,
}: {
  d: ClientDeployment;
  role: PlatformRole;
  mayOperate: boolean;
  now: Date;
  onDone: () => void;
}) {
  const [open, setOpen] = useState(false);
  const tick = useMutation({
    mutationFn: ({ item, done }: { item: ChecklistItem; done: boolean }) =>
      callErp("erp_platform_deployment_checklist", { p_code: d.code, p_item: item, p_done: done }),
    onSuccess: onDone,
  });
  // What the row offers, by its state and the viewer's rank
  // (src/lib/platform.ts). Retry once a build has stopped, or a request never
  // became a run; Start again once a request in flight has stalled. Neither
  // while one is creating or building, nor while a request is in flight and
  // fresh: a second build started under a running one waits for it (they
  // share a concurrency group) and then finds the row built, and the running
  // one can no longer mark it built.
  const offers = new Set(fleetActions(d, role, now));
  const stalled = buildRequestIsStale(d, now);
  const lastRun = d.last_release_run_id ?? d.build_run_id;
  // Its project is up and the register says something of it: a line of its
  // own under the row, so the row and its health read as one.
  const health = deploymentHealthLine(d, now);
  const notes = deploymentLifecycleNotes(d, now);
  const moved = notes.filter((n) => n.key === "moved");
  const standing = notes.filter((n) => n.key !== "moved");
  const exported = lastExportText(d, now);
  const origin = deploymentOrigin(d);

  return (
    <>
      <tr className={health ? "align-top" : "border-b border-border/60 align-top last:border-0"}>
        <td className="py-3 pr-4">
          <div className="text-sm font-medium">{d.client_name}</div>
          <div className="font-mono text-[11px] text-muted-foreground">{d.code}</div>
          {d.owner_email ? (
            <div className="mt-1 text-xs text-muted-foreground">{d.owner_email}</div>
          ) : null}
        </td>
        <td className="py-3 pr-4 text-xs">
          <div className="font-mono">{deploymentAddress(d)}</div>
          <LifecycleLines notes={moved} />
        </td>
        <td className="py-3 pr-4">
          <Pill tone={statusTone(d.status)}>{statusWord(d)}</Pill>
          <LifecycleLines notes={standing} />
          {d.last_event ? (
            <div className="mt-1 max-w-[18rem] text-xs text-muted-foreground">
              {d.last_event.phase} {d.last_event.status}
              {d.last_event.detail ? `: ${d.last_event.detail}` : ""}
              <span className="block text-[11px]">{when(d.last_event.at)}</span>
            </div>
          ) : null}
          {stalled ? (
            <div className="mt-1 text-[11px] text-amber-700 dark:text-amber-400">
              Nothing has happened for {STALE_BUILD_REQUEST_MINUTES} minutes, so the build may be
              lost.
            </div>
          ) : d.status === "requested" && d.request_status === "requested" ? (
            <div className="mt-1 text-[11px] text-muted-foreground">
              The build starts {SWEEP_STARTS}.
            </div>
          ) : null}
        </td>
        <td className="py-3 pr-4 text-xs">
          {d.project_ref ? (
            <>
              <div className="font-mono">{d.project_ref}</div>
              <div className="text-muted-foreground">
                {d.region} · {d.instance_size}
              </div>
            </>
          ) : (
            <span className="text-muted-foreground">Not made yet</span>
          )}
          {exported ? (
            <div className="mt-1 text-[11px] text-muted-foreground">
              {exported}
              {d.last_export_object ? (
                <span className="block break-all font-mono">{d.last_export_object}</span>
              ) : null}
            </div>
          ) : d.status === "retiring" ? (
            <div className="mt-1 text-[11px] text-amber-700 dark:text-amber-400">
              Not exported yet.
            </div>
          ) : null}
        </td>
        <td className="py-3 pr-4 text-xs">
          {d.last_release_sha ? (
            <>
              <div className="flex items-center gap-1.5">
                <span className="font-mono">{d.last_release_sha.slice(0, 12)}</span>
                <Pill
                  tone={
                    d.last_release_outcome === "success"
                      ? "ok"
                      : d.last_release_outcome === "failure"
                        ? "bad"
                        : "warn"
                  }
                >
                  {d.last_release_outcome ?? "unknown"}
                </Pill>
              </div>
              <div className="text-muted-foreground">{when(d.last_release_at)}</div>
            </>
          ) : (
            <span className="text-muted-foreground">None yet</span>
          )}
          {lastRun ? (
            <a
              href={`${RUN_URL}${lastRun}`}
              target="_blank"
              rel="noreferrer"
              className="mt-1 inline-flex items-center gap-1 text-[11px] underline-offset-2 hover:underline"
            >
              The run
              <ExternalLink className="size-3" />
            </a>
          ) : null}
        </td>
        <td className="py-3 pr-4">
          <ul className="flex flex-col gap-1">
            {CHECKLIST_ITEMS.map((item) => {
              const state = d.checklist[item.key];
              return (
                <li key={item.key}>
                  <label className="flex items-center gap-2 text-xs">
                    <input
                      type="checkbox"
                      checked={state?.done ?? false}
                      disabled={!mayOperate || tick.isPending || d.status === "retired"}
                      onChange={(e) => tick.mutate({ item: item.key, done: e.target.checked })}
                    />
                    <span className={state?.done ? "text-muted-foreground line-through" : ""}>
                      {item.label}
                    </span>
                  </label>
                </li>
              );
            })}
          </ul>
          {tick.error ? (
            <div className="mt-2">
              <Fail error={tick.error} />
            </div>
          ) : null}
        </td>
        <td className="py-3 pr-0">
          <div className="flex flex-col items-start gap-1.5">
            {offers.has("open-console") ? (
              <a
                href={`${origin}/platform`}
                target="_blank"
                rel="noreferrer"
                className={`${LINK_BUTTON} text-xs`}
              >
                Open its console
                <ExternalLink className="size-3" />
              </a>
            ) : null}
            {offers.has("onboard") ? (
              <a
                href={`${origin}/platform?section=customers`}
                target="_blank"
                rel="noreferrer"
                className="text-xs underline-offset-2 hover:underline"
              >
                Onboard its first organisation
              </a>
            ) : null}
            {offers.has("retry") ? <RetryBuild d={d} onDone={onDone} /> : null}
            {offers.has("start-again") ? <StartAgain d={d} onDone={onDone} /> : null}
            {offers.has("suspend") ? <SuspendDeployment d={d} onDone={onDone} /> : null}
            {offers.has("reinstate") ? <ReinstateDeployment d={d} onDone={onDone} /> : null}
            {offers.has("rename") ? <RenameDeployment d={d} onDone={onDone} /> : null}
            {offers.has("export") ? <RequestExport d={d} onDone={onDone} /> : null}
            {offers.has("offboard") ? <BeginOffboarding d={d} now={now} onDone={onDone} /> : null}
            {offers.has("retire") ? <RetireDeployment d={d} onDone={onDone} /> : null}
            <button
              type="button"
              onClick={() => setOpen((v) => !v)}
              className="inline-flex items-center gap-0.5 text-xs text-muted-foreground underline-offset-2 hover:underline"
            >
              {open ? <ChevronDown className="size-3.5" /> : <ChevronRight className="size-3.5" />}
              {open ? "Hide steps" : "Steps"}
            </button>
          </div>
        </td>
      </tr>
      {health ? (
        <tr className="border-b border-border/60 last:border-0">
          <td colSpan={7} className="pb-3 pr-0 pt-0">
            <DeploymentHealthSummary line={health} />
          </td>
        </tr>
      ) : null}
      {open ? (
        <tr className="border-b border-border/60 last:border-0">
          <td colSpan={7} className="py-2 pr-0">
            <DeploymentEvents code={d.code} />
          </td>
        </tr>
      ) : null}
    </>
  );
}

/** What a row says of where a deployment stands: suspended, being offboarded, moved. */
function LifecycleLines({ notes }: { notes: LifecycleNote[] }) {
  if (notes.length === 0) return null;
  return (
    <>
      {notes.map((note) => (
        <div key={note.key} className={`mt-1 max-w-[18rem] text-[11px] ${TONE_TEXT[note.tone]}`}>
          {note.text}
        </div>
      ))}
    </>
  );
}

/**
 * What the fleet poll last read from a client's database, in one line: when
 * it was polled, its assurance, its size, when its queue was last drained,
 * support windows open, whether its staff are in step, and its latest backup.
 * Silence comes first and what the poll could not read last.
 */
function DeploymentHealthSummary({ line }: { line: HealthLine }) {
  return (
    <div className="flex flex-col gap-0.5 text-[11px]">
      {line.silence ? <p className="text-amber-700 dark:text-amber-400">{line.silence}</p> : null}
      {line.parts.length > 0 ? (
        <p className="text-muted-foreground">
          <span className="font-medium uppercase tracking-wide">Health</span>
          {line.parts.map((part) => (
            <span key={part.key}>
              {" · "}
              <span className={TONE_TEXT[part.tone]}>{part.text}</span>
            </span>
          ))}
        </p>
      ) : null}
      {line.errors.map((error, i) => (
        <p key={`${i}-${error}`} className="text-destructive">
          Poll error: {error}
        </p>
      ))}
    </div>
  );
}

function DeploymentEvents({ code }: { code: string }) {
  const events = useQuery({
    queryKey: ["erp_platform_deployment_events", code],
    queryFn: () => callErp<DeploymentEvent[]>("erp_platform_deployment_events", { p_code: code }),
    refetchInterval: 10_000,
  });
  if (events.isPending) return <p className="text-xs text-muted-foreground">Loading…</p>;
  if (events.error) return <Fail error={events.error} />;
  const rows = events.data ?? [];
  if (rows.length === 0)
    return <p className="text-xs text-muted-foreground">No step recorded yet.</p>;
  return (
    <Table columns={["When", "Step", "What happened", "Run"]}>
      {rows.map((e) => (
        <tr key={e.id} className="border-b border-border/60 last:border-0">
          <td className="py-1.5 pr-4 text-xs text-muted-foreground">{when(e.at)}</td>
          <td className="py-1.5 pr-4 text-xs">
            {e.phase}{" "}
            <Pill tone={e.status === "failed" ? "bad" : e.status === "done" ? "ok" : "muted"}>
              {e.status}
            </Pill>
          </td>
          <td className="py-1.5 pr-4 text-xs">{e.detail ?? ""}</td>
          <td className="py-1.5 pr-0 text-xs">
            {e.run_id ? (
              <a
                href={`${RUN_URL}${e.run_id}`}
                target="_blank"
                rel="noreferrer"
                className="font-mono underline-offset-2 hover:underline"
              >
                {e.run_id}
              </a>
            ) : (
              ""
            )}
          </td>
        </tr>
      ))}
    </Table>
  );
}

function RequestDeployment({ onDone }: { onDone: () => void }) {
  const [form, setForm] = useState({ code: "", name: "", owner_email: "", reason: "" });
  const ready =
    isDeploymentAddress(form.code) &&
    form.name.trim().length >= 2 &&
    /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(form.owner_email) &&
    form.reason.trim().length >= 20;
  return (
    <FormDialog
      trigger={
        <button
          type="button"
          className={`${TOUCH} rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground`}
        >
          New client deployment
        </button>
      }
      title="Request a client deployment"
      description={`A row in the register and a build, which starts ${SWEEP_STARTS}. The reason is kept with the deployment and in the activity log.`}
      submitLabel="Request the build"
      busyLabel="Requesting…"
      ready={ready}
      run={() =>
        callErp("erp_platform_request_deployment", {
          p_code: form.code.trim().toLowerCase(),
          p_client_name: form.name.trim(),
          p_owner_email: form.owner_email.trim(),
          p_reason: form.reason.trim(),
        })
      }
      onDone={onDone}
      onClosed={() => setForm({ code: "", name: "", owner_email: "", reason: "" })}
    >
      <div className="grid gap-3">
        <label className="block text-sm font-medium">
          Client&apos;s name
          <input
            value={form.name}
            onChange={(e) => setForm({ ...form, name: e.target.value })}
            placeholder="Acme Manufacturing Ltd"
            className={INPUT}
          />
        </label>
        <label className="block text-sm font-medium">
          Code, which becomes the address
          <input
            value={form.code}
            onChange={(e) => setForm({ ...form, code: e.target.value.toLowerCase() })}
            placeholder="acme"
            className={`${INPUT} font-mono`}
          />
        </label>
        <label className="block text-sm font-medium">
          First administrator&apos;s email
          <input
            type="email"
            value={form.owner_email}
            onChange={(e) => setForm({ ...form, owner_email: e.target.value })}
            className={INPUT}
          />
        </label>
        <label className="block text-sm font-medium">
          Reason
          <textarea
            value={form.reason}
            onChange={(e) => setForm({ ...form, reason: e.target.value })}
            placeholder="Which client, what was agreed, and when it goes live. At least twenty characters."
            rows={3}
            className={INPUT}
          />
        </label>
      </div>
    </FormDialog>
  );
}

function RequestRelease({
  deployments,
  onDone,
}: {
  deployments: ClientDeployment[];
  onDone: () => void;
}) {
  const [targets, setTargets] = useState("all");
  const [reason, setReason] = useState("");
  const named = targets
    .split(",")
    .map((t) => t.trim().toLowerCase())
    .filter((t) => t !== "");
  const ready = named.length > 0 && reason.trim().length >= 20;
  // Every client whose project is up takes releases: a suspended one's project
  // keeps running, and one being offboarded is still served.
  const built = deployments.filter((d) => RELEASED.has(d.status));
  return (
    <FormDialog
      trigger={
        <button
          type="button"
          className={`${TOUCH} rounded-md border border-input px-3 text-sm font-medium`}
        >
          Release now
        </button>
      }
      title="Ask for a release"
      description={`The release starts ${SWEEP_STARTS}, and goes to the demonstration, then the clients named, then the control plane.`}
      submitLabel="Ask for the release"
      busyLabel="Asking…"
      ready={ready}
      run={() =>
        callErp("erp_platform_request_release", { p_targets: named, p_reason: reason.trim() })
      }
      onDone={onDone}
      onClosed={() => {
        setTargets("all");
        setReason("");
      }}
    >
      <div className="grid gap-3">
        <label className="block text-sm font-medium">
          Targets
          <input
            value={targets}
            onChange={(e) => setTargets(e.target.value)}
            className={`${INPUT} font-mono`}
          />
          <span className="mt-1 block text-xs font-normal text-muted-foreground">
            all, control, demonstration, or clients by code, separated by commas
            {built.length > 0 ? `: ${built.map((d) => d.code).join(", ")}` : ""}.
          </span>
        </label>
        <label className="block text-sm font-medium">
          Reason
          <textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="What is being released and why now. At least twenty characters."
            rows={3}
            className={INPUT}
          />
        </label>
      </div>
    </FormDialog>
  );
}

/**
 * Retiring a client deployment before its project is deleted
 * (20261011040000): it stops being a release target, its address answers
 * nothing, its code stays held, and its first administrator's address is
 * cleared. It deletes nothing, so the dialog says what is left to do by hand.
 */
function RetireDeployment({ d, onDone }: { d: ClientDeployment; onDone: () => void }) {
  const [reason, setReason] = useState("");
  return (
    <FormDialog
      trigger={
        <button
          type="button"
          className="text-xs text-destructive underline-offset-2 hover:underline"
        >
          Retire
        </button>
      }
      title={`Retire ${d.client_name}`}
      description="It stops receiving releases and its address shows nothing. Its code stays held, so nobody else can take it. It is refused while a build or a release is running for it, and while a contract in force names it unless its offboarding has begun. Nothing is deleted: its project is yours to delete afterwards."
      submitLabel="Retire it"
      busyLabel="Retiring…"
      danger
      ready={reason.trim().length >= 20}
      run={() =>
        callErp("erp_platform_retire_deployment", { p_code: d.code, p_reason: reason.trim() })
      }
      onDone={onDone}
      done={() => (
        <div className="flex flex-col gap-2 text-sm">
          <p>
            {d.client_name} is retired, and nothing runs for it now. What is left is yours, by hand:
          </p>
          <ul className="list-disc pl-5 text-muted-foreground">
            {d.project_ref ? (
              <li>
                Delete project <code className="font-mono text-xs">{d.project_ref}</code> in the
                Supabase dashboard.
              </li>
            ) : null}
          </ul>
        </div>
      )}
      onClosed={() => setReason("")}
    >
      <label className="block text-sm font-medium">
        Why it is retired
        <textarea
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="What it was for, and what becomes of its project. At least twenty characters."
          rows={3}
          className={INPUT}
        />
      </label>
    </FormDialog>
  );
}

function RetryBuild({ d, onDone }: { d: ClientDeployment; onDone: () => void }) {
  const [reason, setReason] = useState("");
  return (
    <FormDialog
      trigger={
        <button type="button" className={`${LINK_BUTTON} text-xs`}>
          Retry the build
        </button>
      }
      title={`Retry the build of ${d.client_name}`}
      description={
        d.project_ref
          ? "Its project exists, so the build carries on from the migration that stopped it."
          : "No project was made yet, so the build starts from the beginning."
      }
      submitLabel="Queue the build again"
      busyLabel="Queuing…"
      ready={reason.trim().length >= 20}
      run={() =>
        callErp("erp_platform_retry_deployment", { p_code: d.code, p_reason: reason.trim() })
      }
      onDone={onDone}
      onClosed={() => setReason("")}
    >
      <label className="block text-sm font-medium">
        What stopped it, and what was done
        <textarea
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          rows={3}
          className={INPUT}
        />
      </label>
    </FormDialog>
  );
}

/**
 * Starting a stalled build again (erp_platform_restart_deployment).
 *
 * Offered only once the newest request has had twenty minutes with nothing
 * happening (buildRequestIsStale): queued or claimed and never started, or
 * started with no step recorded since. The door cancels that request and
 * queues a new one, so the sweep starts a fresh run and a late answer from
 * the lost one cannot settle it.
 */
function StartAgain({ d, onDone }: { d: ClientDeployment; onDone: () => void }) {
  const [reason, setReason] = useState("");
  return (
    <FormDialog
      trigger={
        <button type="button" className={`${LINK_BUTTON} text-xs`}>
          Start again
        </button>
      }
      title={`Start the build of ${d.client_name} again`}
      description={`Its last request has had ${STALE_BUILD_REQUEST_MINUTES} minutes with nothing happening. Starting again cancels that request and queues a new one, which starts ${SWEEP_STARTS}.${
        d.project_ref
          ? " Its project exists, so the build carries on from where it stopped."
          : " No project was made yet, so the build starts from the beginning."
      }`}
      submitLabel="Start it again"
      busyLabel="Queuing…"
      ready={reason.trim().length >= 20}
      run={() =>
        callErp("erp_platform_restart_deployment", { p_code: d.code, p_reason: reason.trim() })
      }
      onDone={onDone}
      onClosed={() => setReason("")}
    >
      <label className="block text-sm font-medium">
        Why it is started again
        <textarea
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="What was seen, for example: queued for an hour and the sweep never started it. At least twenty characters."
          rows={3}
          className={INPUT}
        />
      </label>
    </FormDialog>
  );
}

/** The answer a lifecycle door gives, read for the one thing a dialog says back. */
function purgeDueOf(result: unknown): string | null {
  if (result === null || typeof result !== "object") return null;
  const due: unknown = Reflect.get(result, "purge_due_at");
  return typeof due === "string" ? due : null;
}

/**
 * Suspending a client's service (erp_platform_suspend_deployment). Supabase
 * cannot pause a project on a paid plan, so the project keeps running and
 * keeps receiving releases; what stops is its address being served. The
 * directory answers "suspended" for it, with nothing to talk to.
 */
function SuspendDeployment({ d, onDone }: { d: ClientDeployment; onDone: () => void }) {
  const [reason, setReason] = useState("");
  return (
    <FormDialog
      trigger={
        <button
          type="button"
          className="text-xs text-amber-700 underline-offset-2 hover:underline dark:text-amber-400"
        >
          Suspend
        </button>
      }
      title={`Suspend ${d.client_name}`}
      description={`Its address, ${deploymentAddress(d)}, stops being served: anybody who opens it, its own console included, is told only that the organisation's service is suspended. Its project keeps running and keeps receiving releases, and nothing is deleted. Reinstate it to serve it again.`}
      submitLabel="Suspend it"
      busyLabel="Suspending…"
      danger
      ready={reason.trim().length >= 20}
      run={() =>
        callErp("erp_platform_suspend_deployment", { p_code: d.code, p_reason: reason.trim() })
      }
      onDone={onDone}
      onClosed={() => setReason("")}
    >
      <label className="block text-sm font-medium">
        Why it is suspended
        <textarea
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="For example: the August invoice is sixty days overdue. At least twenty characters."
          rows={3}
          className={INPUT}
        />
        <span className="mt-1 block text-xs font-normal text-muted-foreground">
          Kept with the deployment and in the activity log. The client&apos;s people are not shown
          it.
        </span>
      </label>
    </FormDialog>
  );
}

/** Serving a suspended client again (erp_platform_reinstate_deployment). */
function ReinstateDeployment({ d, onDone }: { d: ClientDeployment; onDone: () => void }) {
  const [reason, setReason] = useState("");
  return (
    <FormDialog
      trigger={
        <button type="button" className={`${LINK_BUTTON} text-xs`}>
          Reinstate
        </button>
      }
      title={`Reinstate ${d.client_name}`}
      description={`Its address, ${deploymentAddress(d)}, is served again and it is live. A browser that saw the suspension may take up to five minutes to notice.`}
      submitLabel="Reinstate it"
      busyLabel="Reinstating…"
      ready={reason.trim().length >= 20}
      run={() =>
        callErp("erp_platform_reinstate_deployment", { p_code: d.code, p_reason: reason.trim() })
      }
      onDone={onDone}
      onClosed={() => setReason("")}
    >
      <label className="block text-sm font-medium">
        Why it is reinstated
        <textarea
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="For example: the overdue invoice was paid on 14 October. At least twenty characters."
          rows={3}
          className={INPUT}
        />
      </label>
    </FormDialog>
  );
}

/**
 * Giving a client a new address (erp_platform_rename_deployment). Its code
 * never changes — contracts, invoices and the register's history name it —
 * so a rename is a new address: the rename workflow points the client's
 * project, its sign-in links and its one organisation at it, and the old
 * address sends people on for ninety days.
 */
function RenameDeployment({ d, onDone }: { d: ClientDeployment; onDone: () => void }) {
  const [address, setAddress] = useState("");
  const [reason, setReason] = useState("");
  const current = d.address ?? d.code;
  const shaped = isDeploymentAddress(address);
  const ready = shaped && address !== current && reason.trim().length >= 20;
  return (
    <FormDialog
      trigger={
        <button type="button" className={`${LINK_BUTTON} text-xs`}>
          Rename
        </button>
      }
      title={`Give ${d.client_name} a new address`}
      description={`Its people sign in at the new address once the rename has run, which starts ${SWEEP_STARTS}. Its old address, ${deploymentAddress(d)}, sends them on for ninety days. Its code, ${d.code}, stays the same.`}
      submitLabel="Rename it"
      busyLabel="Asking…"
      ready={ready}
      run={() =>
        callErp("erp_platform_rename_deployment", {
          p_code: d.code,
          p_new_address: address,
          p_reason: reason.trim(),
        })
      }
      onDone={onDone}
      onClosed={() => {
        setAddress("");
        setReason("");
      }}
    >
      <div className="grid gap-3">
        <label className="block text-sm font-medium">
          New address
          <span className="flex items-center gap-1">
            <input
              value={address}
              onChange={(e) => setAddress(e.target.value.trim().toLowerCase())}
              placeholder={current}
              className={`${INPUT} font-mono`}
            />
            <span className="mt-1 shrink-0 font-mono text-xs text-muted-foreground">
              .{APEX_HOST}
            </span>
          </span>
          <span className="mt-1 block text-xs font-normal text-muted-foreground">
            {address !== "" && !shaped
              ? "Three to sixty-three lower-case letters, digits or hyphens, not starting or ending with a hyphen."
              : address === current
                ? "That is its address now."
                : "Held once across the fleet, like a code: refused if any client has it, or had it in the last ninety days."}
          </span>
        </label>
        <label className="block text-sm font-medium">
          Reason
          <textarea
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="Why the client is moving address, and who asked. At least twenty characters."
            rows={3}
            className={INPUT}
          />
        </label>
      </div>
    </FormDialog>
  );
}

/**
 * Beginning to let a client go (erp_platform_begin_offboarding): it is marked
 * as being offboarded, an export of its database is queued, and its project
 * is due to be purged thirty days after the later of today and the end of
 * the current term of a contract in force naming it. Its address stays
 * served meanwhile. Retiring it and deleting its project come after.
 */
function BeginOffboarding({
  d,
  now,
  onDone,
}: {
  d: ClientDeployment;
  now: Date;
  onDone: () => void;
}) {
  const [reason, setReason] = useState("");
  const earliest = dayText(earliestPurgeDate(now));
  return (
    <FormDialog
      trigger={
        <button
          type="button"
          className="text-xs text-destructive underline-offset-2 hover:underline"
        >
          Begin offboarding
        </button>
      }
      title={`Begin offboarding ${d.client_name}`}
      description={`An export of its database is made, encrypted, off the platform; it starts ${SWEEP_STARTS}. Its address stays served meanwhile, so its people can take what they need. Its project is due to be purged ${OFFBOARDING_COOL_OFF_DAYS} days after the later of today and the end of the current term of any contract in force naming it: ${earliest ?? "thirty days from today"} at the earliest. Nothing is deleted by this.`}
      submitLabel="Begin offboarding"
      busyLabel="Beginning…"
      danger
      ready={reason.trim().length >= 20}
      run={() =>
        callErp<unknown>("erp_platform_begin_offboarding", {
          p_code: d.code,
          p_reason: reason.trim(),
        })
      }
      onDone={onDone}
      done={(result) => {
        const due = dayText(purgeDueOf(result));
        return (
          <div className="flex flex-col gap-2 text-sm">
            <p>
              {d.client_name} is being offboarded.{" "}
              {due ? `Its project is due to be purged on ${due}.` : null}
            </p>
            <p className="text-muted-foreground">
              Its row says when the export is made. On the purge date, retire it and delete its
              project in the Supabase dashboard.
            </p>
          </div>
        );
      }}
      onClosed={() => setReason("")}
    >
      <label className="block text-sm font-medium">
        Why it is offboarded
        <textarea
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="For example: the contract ends on 31 December and the client gave notice. At least twenty characters."
          rows={3}
          className={INPUT}
        />
      </label>
    </FormDialog>
  );
}

/** An export of a client's database off the platform, now (erp_platform_request_export). */
function RequestExport({ d, onDone }: { d: ClientDeployment; onDone: () => void }) {
  const [reason, setReason] = useState("");
  return (
    <FormDialog
      trigger={
        <button type="button" className={`${LINK_BUTTON} text-xs`}>
          Export now
        </button>
      }
      title={`Export ${d.client_name}'s database`}
      description={`A copy of its database, encrypted to the backup key and written to the off-platform bucket under exports/${d.code}/. It starts ${SWEEP_STARTS}. While one is waiting, asking again queues nothing more.`}
      submitLabel="Export it"
      busyLabel="Asking…"
      ready={reason.trim().length >= 20}
      run={() =>
        callErp("erp_platform_request_export", { p_code: d.code, p_reason: reason.trim() })
      }
      onDone={onDone}
      onClosed={() => setReason("")}
    >
      <label className="block text-sm font-medium">
        Why it is exported now
        <textarea
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="For example: the client asked for a copy of its data. At least twenty characters."
          rows={3}
          className={INPUT}
        />
      </label>
    </FormDialog>
  );
}
