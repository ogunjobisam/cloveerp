import { friendlyError } from "@/lib/errors";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { useState, type ReactNode } from "react";
import {
  Archive,
  Building2,
  ClipboardList,
  Copy,
  DoorClosed,
  DoorOpen,
  Gavel,
  LogIn,
  Pause,
  Play,
  Plus,
  ShieldCheck,
  Trash2,
  UserPlus,
  Users,
} from "lucide-react";

import { OfferOwnership } from "../erp/ownership";
import { Pill, Table } from "../erp/panel";
import { TOUCH } from "../erp/page";
import { callErp } from "../../lib/erp";
import {
  atLeast,
  ROLE_BLURB,
  type PlatformAuditRow,
  type PlatformRole,
  type PlatformStaff,
  type PlatformTenant,
} from "../../lib/platform";
import {
  readSelfServiceChange,
  selfServiceIsOpen,
  usableReason,
  type SelfServiceChange,
} from "../../lib/self-service";
import { Card, Fail, TokenNotice, statusTone, INPUT } from "./kit";

/** Who may work on the platform, and who may make an organisation without being invited. */

export function Staff({ role }: { role: PlatformRole }) {
  const queryClient = useQueryClient();
  const mayManage = atLeast(role, "owner");
  const [form, setForm] = useState({ email: "", name: "", role: "operator" as PlatformRole });

  const staff = useQuery({
    queryKey: ["erp_platform_staff"],
    queryFn: () => callErp<PlatformStaff[]>("erp_platform_staff"),
  });

  const refresh = () => queryClient.invalidateQueries({ queryKey: ["erp_platform_staff"] });

  const add = useMutation({
    mutationFn: () =>
      callErp("erp_platform_add_staff", {
        p_email: form.email,
        p_display_name: form.name || form.email,
        p_role: form.role,
      }),
    onSuccess: () => {
      setForm({ email: "", name: "", role: "operator" });
      void refresh();
    },
  });

  const setRole = useMutation({
    mutationFn: (v: { id: string; role: PlatformRole }) =>
      callErp("erp_platform_set_staff_role", { p_id: v.id, p_role: v.role }),
    onSuccess: refresh,
  });

  const revoke = useMutation({
    mutationFn: (v: { id: string; reason: string }) =>
      callErp("erp_platform_revoke_staff", { p_id: v.id, p_reason: v.reason }),
    onSuccess: refresh,
  });

  const err = add.error ?? setRole.error ?? revoke.error ?? staff.error ?? null;

  return (
    <div className="flex flex-col gap-5">
      {err ? <Fail error={err} /> : null}

      {mayManage ? (
        <Card
          title="Add someone to the platform"
          icon={<UserPlus className="size-4 text-primary" />}
          description="They are matched by the address on their sign-in, so they can be added before they have ever signed in."
        >
          <form
            onSubmit={(e) => {
              e.preventDefault();
              add.mutate();
            }}
            className="grid gap-3 sm:grid-cols-4"
          >
            <label className="block text-sm font-medium sm:col-span-2">
              Email
              <input
                required
                type="email"
                value={form.email}
                onChange={(e) => setForm({ ...form, email: e.target.value })}
                className={INPUT}
              />
            </label>
            <label className="block text-sm font-medium">
              Name
              <input
                value={form.name}
                onChange={(e) => setForm({ ...form, name: e.target.value })}
                className={INPUT}
              />
            </label>
            <label className="block text-sm font-medium">
              Role
              <select
                value={form.role}
                onChange={(e) => setForm({ ...form, role: e.target.value as PlatformRole })}
                className={INPUT}
              >
                <option value="owner">Owner</option>
                <option value="operator">Operator</option>
                <option value="support">Support</option>
              </select>
            </label>
            <p className="text-xs text-muted-foreground sm:col-span-3">{ROLE_BLURB[form.role]}</p>
            <button
              type="submit"
              disabled={add.isPending}
              className={`${TOUCH} rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground disabled:opacity-60`}
            >
              {add.isPending ? "Adding…" : "Add"}
            </button>
          </form>
        </Card>
      ) : null}

      <Card
        title="Platform staff"
        icon={<Users className="size-4 text-primary" />}
        description="Owner controls the platform, operator runs the companies, support can look and be let in."
      >
        {staff.isPending ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : (
          <Table columns={["Person", "Role", "Signed in", mayManage ? "Actions" : ""]}>
            {(staff.data ?? []).map((s) => (
              <tr key={s.id} className="border-b border-border/60 last:border-0">
                <td className="py-3 pr-4">
                  <div className="font-medium">{s.display_name}</div>
                  <div className="text-xs text-muted-foreground">{s.email}</div>
                </td>
                <td className="py-3 pr-4">
                  <Pill tone={s.role === "owner" ? "ok" : s.role === "operator" ? "warn" : "muted"}>
                    {s.role}
                  </Pill>
                </td>
                <td className="py-3 pr-4 text-xs text-muted-foreground">
                  {s.bound ? "Yes" : "Not yet"}
                </td>
                <td className="py-3 pr-0">
                  {mayManage ? (
                    <div className="flex flex-wrap items-center gap-2">
                      <select
                        aria-label={`Role of ${s.display_name}`}
                        value={s.role}
                        onChange={(e) =>
                          setRole.mutate({ id: s.id, role: e.target.value as PlatformRole })
                        }
                        className="rounded-md border border-input bg-background px-2 py-1 text-xs"
                      >
                        <option value="owner">owner</option>
                        <option value="operator">operator</option>
                        <option value="support">support</option>
                      </select>
                      <button
                        type="button"
                        onClick={() => {
                          const reason = window.prompt(`Remove ${s.display_name}? Reason:`);
                          if (reason) revoke.mutate({ id: s.id, reason });
                        }}
                        className="rounded-md border border-destructive/40 px-2 py-1 text-xs font-medium text-destructive"
                      >
                        Remove
                      </button>
                    </div>
                  ) : null}
                </td>
              </tr>
            ))}
          </Table>
        )}
      </Card>

      {/* Owners only. Hiding it is the convenience: the door checks for an
          owner on its first line, whoever calls it. */}
      {mayManage ? <SelfServiceSignUp /> : null}
    </div>
  );
}

const SELF_SERVICE_KEY = ["erp_self_service_organisations_open"];

function when(iso: string): string {
  return new Date(iso).toLocaleString(undefined, {
    day: "2-digit",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

/**
 * Self-service sign-up: whether somebody who signs in without an invitation
 * may create an organisation, or a demo, for themselves.
 *
 * Closed by default. While it is closed the database refuses both to anybody
 * but platform operators and owners, and organisations come only from Onboard a
 * company or by invitation into one that exists. Only an owner may open or
 * close it, always with a reason, and every change goes into the platform's own
 * log.
 *
 * The switch never flips on a click. It asks for the reason first, and the
 * state shown is the database's answer afterwards, not the click.
 */
function SelfServiceSignUp() {
  const queryClient = useQueryClient();
  const [asking, setAsking] = useState<boolean | null>(null);
  const [reason, setReason] = useState("");
  const [last, setLast] = useState<SelfServiceChange | null>(null);

  const state = useQuery({
    queryKey: SELF_SERVICE_KEY,
    queryFn: () => callErp<unknown>("erp_self_service_organisations_open"),
  });
  const open = state.isSuccess ? selfServiceIsOpen(state.data) : null;

  const change = useMutation({
    mutationFn: (v: { open: boolean; reason: string }) =>
      callErp<unknown>("erp_platform_set_self_service_organisations", {
        p_open: v.open,
        p_reason: v.reason.trim(),
      }),
    onSuccess: (answer, v) => {
      setLast(
        readSelfServiceChange(answer) ?? {
          open: v.open,
          reason: v.reason.trim(),
          updated_at: null,
        },
      );
      setAsking(null);
      setReason("");
      void queryClient.invalidateQueries({ queryKey: SELF_SERVICE_KEY });
    },
  });

  const ask = (next: boolean) => {
    change.reset();
    setReason("");
    setAsking(next);
  };

  return (
    <Card
      title="Self-service sign-up"
      icon={
        open ? (
          <DoorOpen className="size-4 text-primary" />
        ) : (
          <DoorClosed className="size-4 text-primary" />
        )
      }
      description="Whether somebody who signs in without an invitation may create an organisation or a demo for themselves. While it is closed, organisations come only from Onboard a company or by invitation."
    >
      {state.isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : state.error ? (
        <Fail error={state.error} />
      ) : (
        <div className="flex flex-col gap-4">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div className="min-w-0">
              <p className="flex items-center gap-2 text-sm font-medium">
                Self-service sign-up is
                <Pill tone={open ? "warn" : "ok"}>{open ? "Open" : "Closed"}</Pill>
              </p>
              <p className="mt-1 text-xs text-muted-foreground">
                {open
                  ? "Anybody who signs in can create an organisation or a demo for themselves. The limit on how many one sign-in may create still applies."
                  : "Only platform operators and owners can create organisations and demos. Everybody else who signs in without an organisation is asked for an invitation."}
              </p>
            </div>
            <button
              type="button"
              role="switch"
              aria-checked={open === true}
              aria-label="Self-service sign-up"
              onClick={() => ask(!open)}
              disabled={change.isPending || asking !== null}
              className={`${TOUCH} inline-flex shrink-0 items-center rounded-full px-1 disabled:opacity-60`}
            >
              <span
                className={`relative inline-flex h-6 w-11 items-center rounded-full transition-colors ${
                  open ? "bg-primary" : "bg-muted-foreground/30"
                }`}
              >
                <span
                  className={`inline-block size-5 rounded-full bg-background shadow transition-transform ${
                    open ? "translate-x-5" : "translate-x-0.5"
                  }`}
                />
              </span>
            </button>
          </div>

          {asking !== null ? (
            <form
              onSubmit={(e) => {
                e.preventDefault();
                if (usableReason(reason)) change.mutate({ open: asking, reason });
              }}
              className="rounded-lg border border-border p-3"
            >
              <p className="text-sm font-medium">
                {asking ? "Open self-service sign-up" : "Close self-service sign-up"}
              </p>
              <p className="mt-1 text-xs text-muted-foreground">
                {asking
                  ? "Anybody who signs in without an invitation will be able to create an organisation, or a demo, for themselves."
                  : "Somebody who signs in without an invitation will be asked for one. Organisations that already exist are not affected."}
              </p>
              <label className="mt-3 block text-sm font-medium">
                Reason
                <textarea
                  required
                  rows={2}
                  value={reason}
                  onChange={(e) => setReason(e.target.value)}
                  placeholder="Why, for the platform's record"
                  className={INPUT}
                />
              </label>
              {change.error ? (
                <div className="mt-3">
                  <Fail error={change.error} />
                </div>
              ) : null}
              <div className="mt-3 flex flex-wrap gap-2">
                <button
                  type="submit"
                  disabled={change.isPending || !usableReason(reason)}
                  className={`${TOUCH} rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground disabled:opacity-60`}
                >
                  {change.isPending ? "Saving…" : asking ? "Open sign-up" : "Close sign-up"}
                </button>
                <button
                  type="button"
                  onClick={() => {
                    change.reset();
                    setAsking(null);
                  }}
                  disabled={change.isPending}
                  className={`${TOUCH} rounded-md border border-input px-4 text-sm font-medium disabled:opacity-60`}
                >
                  Cancel
                </button>
              </div>
            </form>
          ) : null}

          {last ? (
            <p role="status" className="text-xs text-muted-foreground">
              {last.open ? "Opened" : "Closed"}{" "}
              {last.updated_at ? when(last.updated_at) : "just now"}
              {last.reason ? `, because: ${last.reason}` : ""}. The change is recorded in Activity.
            </p>
          ) : null}
        </div>
      )}
    </Card>
  );
}
