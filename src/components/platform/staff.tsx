import { friendlyError } from "@/lib/errors";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { useState, type ReactNode } from "react";
import {
  Archive,
  Building2,
  ClipboardList,
  Copy,
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
import { Card, Fail, TokenNotice, statusTone, INPUT } from "./kit";

/** Who may work on the platform. */

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
    </div>
  );
}
