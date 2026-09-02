import { createFileRoute } from "@tanstack/react-router";

import { ActionBar, pickFrom } from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";
import { PageHeader } from "../../components/erp/page";
import { DataPanel, Pill, Table } from "../../components/erp/panel";

export const Route = createFileRoute("/operations/devices")({
  head: () => ({
    meta: [
      { title: "Devices and scanning — Clove ERP" },
      {
        name: "description",
        content: "Handheld scanners, device enrolment and offline queue health.",
      },
      { property: "og:title", content: "Devices and scanning — Clove ERP" },
      {
        property: "og:description",
        content: "Handheld scanners, device enrolment and offline queue health.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Devices />
    </Gate>
  ),
});

/** Shaped by erp.device_operations_report(): a finding per thing that is
 *  wrong in §14 — a device with no session, a session with no supervisor,
 *  an action conflicted with no reason. Empty is the good state. */
type Finding = {
  finding: string;
  reference: string;
  detail: string;
};

/** Shaped by erp_devices(). */
type Device = {
  code: string;
  name: string;
  device_class: string;
  site: string;
  status: string;
  serial_number: string | null;
  registered_at: string;
  last_seen_at: string | null;
  open_session: boolean;
};

/** Shaped by erp_device_actions(): every action in the organisation, newest
 *  first. `applied` is the one that changed stock and carries what the module
 *  returned; `conflicted` carries the reason it did not. */
type Action = {
  id: string;
  device: string;
  site: string;
  task_code: string;
  status: string;
  input_method: string;
  keyed_reason: string | null;
  captured_at: string;
  received_at: string;
  applied_at: string | null;
  applied_result: string | null;
  conflict_reason: string | null;
  payload: Record<string, unknown>;
};

/** Shaped by erp_device_task_handlers(): the twenty-two steps of §14.3 and,
 *  for each, the module function a queued action applies through — or the
 *  register's sentence on why nothing applies it yet. */
type TaskHandler = {
  code: string;
  name: string;
  task_group: string;
  seq: number;
  module_code: string | null;
  sql_function: string | null;
  payload_keys: { key: string; type: string; required: boolean }[];
  writes_nothing: boolean;
  not_handled_reason: string | null;
  note: string;
};

/** Shaped by erp_scan_rules(). A rule with no product class is the step's
 *  default; erp.evaluate_scan() prefers the specific one when both exist. */
type ScanRule = {
  id: string;
  task_code: string;
  task_name: string;
  task_group: string;
  item_class: string | null;
  accepted_symbologies: string[];
  mandatory_identifiers: string[];
  when_absent: string;
  updated_at: string;
};

/** From erp.scan_rule's when_absent check. */
const WHEN_ABSENT = [
  { value: "exception_with_reason", label: "Raise an exception and ask for a reason" },
  { value: "refuse", label: "Refuse the scan" },
  { value: "accept", label: "Accept it anyway" },
];

function when(value: string | null) {
  return value ? new Date(value).toLocaleString() : "—";
}

function actionTone(status: string): "ok" | "warn" | "bad" | "muted" {
  switch (status) {
    case "applied":
      return "ok";
    case "conflicted":
      return "bad";
    case "received":
    case "pending":
      return "warn";
    default:
      return "muted";
  }
}

function Devices() {
  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Devices and scanning">
        The warehouse client is a device with a session, sending actions that are received first and
        applied second, so a pick captured offline arrives whole and in order. What the client reads
        at each step is a scan rule: which symbologies a step accepts, which identifiers a barcode
        must carry, and what happens when one is missing.
      </PageHeader>

      <ActionBar
        note="Registering a device is the first act; a session is opened from the device itself. Scan rules are per step, with an optional product class that overrides the step's default."
        actions={[
          {
            label: "Register a device",
            permission: "administration.configure",
            fn: "erp_register_device",
            fields: [
              { kind: "text", name: "p_code", label: "Code", required: true },
              {
                kind: "text",
                name: "p_site_code",
                label: "Site code",
                required: true,
                hint: "The code of the site this device works at.",
              },
              { kind: "text", name: "p_name", label: "Name", required: true },
              pickFrom("erp_device_classes", "code", ["code", "name"], "p_device_class", "Class"),
              { kind: "text", name: "p_serial_number", label: "Serial number" },
            ],
            invalidates: ["erp_devices", "erp_device_operations"],
          },
          {
            label: "Set a scan rule",
            permission: "administration.configure",
            fn: "erp_upsert_scan_rule",
            fields: [
              pickFrom("erp_device_tasks", "code", ["code", "name"], "p_task_code", "Step"),
              {
                kind: "text",
                name: "p_accepted_symbologies",
                label: "Accepted symbologies",
                required: true,
                hint: "Comma separated codes from the symbology list below, e.g. gs1_128, gs1_datamatrix.",
              },
              {
                kind: "text",
                name: "p_mandatory_identifiers",
                label: "Mandatory identifiers",
                hint: "Comma separated GS1 application identifiers, e.g. 01, 10, 17. Leave empty when any recognised barcode will do.",
              },
              {
                kind: "choice",
                name: "p_when_absent",
                label: "When one is missing",
                required: true,
                choices: WHEN_ABSENT,
              },
              {
                kind: "text",
                name: "p_item_class",
                label: "Product class",
                hint: "Leave empty for the step's default rule.",
              },
            ],
            invalidates: ["erp_scan_rules", "erp_device_operations"],
          },
          {
            label: "Apply my queued actions",
            permission: "inventory.move",
            fn: "erp_drain_device_actions",
            fields: [
              {
                kind: "text",
                name: "p_device_code",
                label: "Device code",
                hint: "Leave empty to apply your queued actions on every device. Only actions captured under your own session apply; anyone else's are held for them.",
              },
            ],
            invalidates: ["erp_device_actions", "erp_device_operations"],
          },
        ]}
      />

      <DataPanel<Finding>
        title="What is wrong"
        description="Read from the same report the build fails on. A session without a device, an action conflicted for no reason, a keyed entry with no reason — each is one row here and one failure there."
        fn="erp_device_operations"
        empty="Nothing to report. Every device session, action and scan rule is as §14 expects."
      >
        {(rows) => (
          <Table columns={["Finding", "Reference", "Detail"]}>
            {rows.map((r, i) => (
              <tr
                key={`${r.finding}-${r.reference}-${i}`}
                className="border-b border-border/50 align-top last:border-0"
              >
                <td className="py-2 pr-4">
                  <Pill tone="bad">{r.finding}</Pill>
                </td>
                <td className="py-2 pr-4 font-mono text-xs">{r.reference}</td>
                <td className="py-2 text-sm text-muted-foreground">{r.detail}</td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Device>
        title="Devices"
        description="Every registered device, its class and site, and whether a session is open on it now."
        fn="erp_devices"
        empty="No device is registered. Register one above, then open a session from it."
      >
        {(rows) => (
          <Table columns={["Device", "Class", "Site", "Session", "Last seen", "State"]}>
            {rows.map((r) => (
              <tr key={r.code} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4">
                  <div className="text-sm">{r.name}</div>
                  <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                    {r.code}
                    {r.serial_number ? ` · ${r.serial_number}` : ""}
                  </div>
                </td>
                <td className="py-2 pr-4 text-sm">{r.device_class}</td>
                <td className="py-2 pr-4 font-mono text-xs">{r.site}</td>
                <td className="py-2 pr-4">
                  {r.open_session ? <Pill tone="ok">Open</Pill> : <Pill tone="muted">None</Pill>}
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">{when(r.last_seen_at)}</td>
                <td className="py-2">
                  <Pill tone={r.status === "active" ? "ok" : "muted"}>{r.status}</Pill>
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<Action>
        title="Action queue"
        description="Every action received from a device, newest first. Received is the act of capture reaching the server; applied is the moment the module that owns the step did the work, and the outcome is what it returned. A conflict names what it collided with, in the module's own words."
        fn="erp_device_actions"
        empty="No device has sent an action yet. A device queues its work offline and sends it when the network returns, so this fills up from the warehouse rather than from here."
      >
        {(rows) => (
          <Table columns={["Received", "Device", "Step", "Input", "State", "Applied", "Outcome"]}>
            {rows.map((r) => (
              <tr key={r.id} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {when(r.received_at)}
                  {r.captured_at !== r.received_at ? (
                    <div className="mt-0.5">captured {when(r.captured_at)}</div>
                  ) : null}
                </td>
                <td className="py-2 pr-4 font-mono text-xs">
                  {r.device}
                  <div className="mt-0.5 text-muted-foreground">{r.site}</div>
                </td>
                <td className="py-2 pr-4 text-sm">{r.task_code}</td>
                <td className="py-2 pr-4 text-sm">
                  {r.input_method}
                  {r.keyed_reason ? (
                    <div className="mt-0.5 text-xs text-muted-foreground">{r.keyed_reason}</div>
                  ) : null}
                </td>
                <td className="py-2 pr-4">
                  <Pill tone={actionTone(r.status)}>{r.status}</Pill>
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">{when(r.applied_at)}</td>
                <td className="py-2 text-xs text-muted-foreground">
                  {r.status === "applied" ? (
                    <span className="font-mono">{r.applied_result ?? "done"}</span>
                  ) : (
                    (r.conflict_reason ?? "—")
                  )}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<TaskHandler>
        title="What each step applies"
        description="Product data, the same for every organisation. For each of §14.3's steps, the module function a queued action applies through and what its payload must carry — or, where nothing applies it yet, the reason an action for it conflicts rather than waits. The build fails if a step has neither."
        fn="erp_device_task_handlers"
        empty="No step is registered, which is itself unexpected."
      >
        {(rows) => (
          <Table columns={["Step", "Applies through", "Payload", "Note"]}>
            {rows.map((r) => (
              <tr key={r.code} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4">
                  <div className="text-sm">{r.name}</div>
                  <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                    {r.code} · {r.task_group}
                  </div>
                </td>
                <td className="py-2 pr-4">
                  {r.sql_function ? (
                    <>
                      <Pill tone="ok">{r.module_code}</Pill>
                      <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                        {r.sql_function}
                      </div>
                    </>
                  ) : r.writes_nothing ? (
                    <Pill tone="muted">Reads only</Pill>
                  ) : (
                    <Pill tone="warn">Not yet</Pill>
                  )}
                </td>
                <td className="py-2 pr-4 font-mono text-xs">
                  {r.payload_keys.length > 0
                    ? r.payload_keys.map((k) => (k.required ? k.key : `${k.key}?`)).join(", ")
                    : "—"}
                </td>
                <td className="py-2 text-xs text-muted-foreground">
                  {r.not_handled_reason ?? r.note}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<ScanRule>
        title="Scan rules"
        description="Per step and, where one is named, per product class. The identifiers are GS1 application identifiers: 01 is the GTIN, 10 the batch, 17 the expiry, 21 the serial, 00 the SSCC."
        fn="erp_scan_rules"
        empty="No scan rule is set. Until one is, every step accepts any recognised barcode and requires nothing of it."
      >
        {(rows) => (
          <Table columns={["Step", "Product class", "Accepts", "Requires", "When missing"]}>
            {rows.map((r) => (
              <tr key={r.id} className="border-b border-border/50 align-top last:border-0">
                <td className="py-2 pr-4">
                  <div className="text-sm">{r.task_name}</div>
                  <div className="mt-0.5 font-mono text-xs text-muted-foreground">
                    {r.task_code} · {r.task_group}
                  </div>
                </td>
                <td className="py-2 pr-4 text-sm">
                  {r.item_class ?? <span className="text-muted-foreground">Default</span>}
                </td>
                <td className="py-2 pr-4 font-mono text-xs">{r.accepted_symbologies.join(", ")}</td>
                <td className="py-2 pr-4 font-mono text-xs">
                  {r.mandatory_identifiers.length > 0 ? r.mandatory_identifiers.join(", ") : "—"}
                </td>
                <td className="py-2 text-sm">
                  {r.when_absent === "refuse" ? (
                    <Pill tone="bad">Refuse</Pill>
                  ) : r.when_absent === "accept" ? (
                    <Pill tone="muted">Accept</Pill>
                  ) : (
                    <Pill tone="warn">Exception with reason</Pill>
                  )}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>

      <DataPanel<{ code: string; name: string; is_gs1: boolean; is_two_dimensional: boolean }>
        title="Symbologies this product reads"
        description="Product data, the same for every organisation. A scan rule may only accept codes from this list."
        fn="erp_symbologies"
        empty="No symbology is registered, which is itself unexpected."
      >
        {(rows) => (
          <Table columns={["Code", "Name", "GS1", "Shape"]}>
            {rows.map((r) => (
              <tr key={r.code} className="border-b border-border/50 last:border-0">
                <td className="py-2 pr-4 font-mono text-xs">{r.code}</td>
                <td className="py-2 pr-4 text-sm">{r.name}</td>
                <td className="py-2 pr-4 text-sm">{r.is_gs1 ? "Yes" : "No"}</td>
                <td className="py-2 text-sm text-muted-foreground">
                  {r.is_two_dimensional ? "2D" : "1D"}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </DataPanel>
    </div>
  );
}
