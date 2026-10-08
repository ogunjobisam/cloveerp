import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { ChevronDown, ChevronRight, ExternalLink, Rocket, Server } from "lucide-react";

import { Pill, Table } from "../erp/panel";
import { TOUCH } from "../erp/page";
import { callErp } from "../../lib/erp";
import {
  atLeast,
  CHECKLIST_ITEMS,
  type ChecklistItem,
  type ClientDeployment,
  type ClientDeploymentStatus,
  type DeploymentEvent,
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
 * train, writes a request the scheduled sweep (fleet_sweep.yml) claims within
 * ten minutes and starts; the row then follows the run through the events the
 * workflow records on it, so a build's progress is read here and not in a
 * run log.
 */

/** Where a run's log is: the repository the workflows run in. */
const RUN_URL = "https://github.com/ogunjobisam/cloveerp/actions/runs/";

const ACTIVE: ReadonlySet<ClientDeploymentStatus> = new Set(["requested", "creating", "building"]);

/**
 * Where the owner may retire a deployment (20261011040000): any state but a
 * build in progress, which would refuse to finish, and retired already.
 */
const RETIRABLE: ReadonlySet<ClientDeploymentStatus> = new Set([
  "requested",
  "failed",
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
  return d.status.charAt(0).toUpperCase() + d.status.slice(1);
}

function when(iso: string | null): string {
  return iso ? new Date(iso).toLocaleString() : "—";
}

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
            columns={["Client", "Where it is", "Project", "Last release", "By hand", "Actions"]}
          >
            {rows.map((d) => (
              <DeploymentRow
                key={d.code}
                d={d}
                mayOperate={mayOperate}
                isOwner={isOwner}
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
  mayOperate,
  isOwner,
  onDone,
}: {
  d: ClientDeployment;
  mayOperate: boolean;
  isOwner: boolean;
  onDone: () => void;
}) {
  const [open, setOpen] = useState(false);
  const tick = useMutation({
    mutationFn: ({ item, done }: { item: ChecklistItem; done: boolean }) =>
      callErp("erp_platform_deployment_checklist", { p_code: d.code, p_item: item, p_done: done }),
    onSuccess: onDone,
  });
  // Retry once a build has stopped, or a request never became a run. Not
  // while one is creating or building: a second build started under a
  // running one waits for it (they share a concurrency group) and then finds
  // the row built, and the running one can no longer mark it built.
  const retryable =
    d.status === "failed" ||
    (d.status === "requested" &&
      d.request_status !== "requested" &&
      d.request_status !== "claimed");
  const lastRun = d.last_release_run_id ?? d.build_run_id;

  return (
    <>
      <tr className="border-b border-border/60 align-top last:border-0">
        <td className="py-3 pr-4">
          <div className="text-sm font-medium">{d.client_name}</div>
          <div className="font-mono text-[11px] text-muted-foreground">{d.code}</div>
          {d.owner_email ? (
            <div className="mt-1 text-xs text-muted-foreground">{d.owner_email}</div>
          ) : null}
        </td>
        <td className="py-3 pr-4">
          <Pill tone={statusTone(d.status)}>{statusWord(d)}</Pill>
          {d.last_event ? (
            <div className="mt-1 max-w-[18rem] text-xs text-muted-foreground">
              {d.last_event.phase} {d.last_event.status}
              {d.last_event.detail ? `: ${d.last_event.detail}` : ""}
              <span className="block text-[11px]">{when(d.last_event.at)}</span>
            </div>
          ) : null}
          {d.status === "requested" && d.request_status === "requested" ? (
            <div className="mt-1 text-[11px] text-muted-foreground">
              The build starts within ten minutes.
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
            {d.status === "built" || d.status === "live" || d.status === "suspended" ? (
              <>
                <a
                  href={`${d.origin}/platform`}
                  target="_blank"
                  rel="noreferrer"
                  className={`${LINK_BUTTON} text-xs`}
                >
                  Open its console
                  <ExternalLink className="size-3" />
                </a>
                <a
                  href={`${d.origin}/platform?section=customers`}
                  target="_blank"
                  rel="noreferrer"
                  className="text-xs underline-offset-2 hover:underline"
                >
                  Onboard its first organisation
                </a>
              </>
            ) : null}
            {isOwner && retryable ? <RetryBuild d={d} onDone={onDone} /> : null}
            {isOwner && RETIRABLE.has(d.status) ? <RetireDeployment d={d} onDone={onDone} /> : null}
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
      {open ? (
        <tr className="border-b border-border/60 last:border-0">
          <td colSpan={6} className="py-2 pr-0">
            <DeploymentEvents code={d.code} />
          </td>
        </tr>
      ) : null}
    </>
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
    /^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/.test(form.code) &&
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
      description="A row in the register and a build the sweep starts within ten minutes. The reason is kept with the deployment and in the activity log."
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
  const built = deployments.filter((d) => d.status === "built" || d.status === "live");
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
      description="The sweep starts deploy.yml within ten minutes: the demonstration, then the clients named, then the control plane."
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
            all, control, demonstration, or built clients by code, separated by commas
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
      description="It stops receiving releases and its address shows nothing. Its code stays held, so nobody else can take it. It is refused while a build or a release is running for it. Nothing is deleted: its project is yours to delete afterwards."
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
