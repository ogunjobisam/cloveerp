import { friendlyError } from "@/lib/errors";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createFileRoute } from "@tanstack/react-router";
import { useMemo, useState } from "react";

import { ActionBar } from "../../components/erp/actions-bar";
import { Gate } from "../../components/erp/gate";

import { useErpSession } from "../../components/erp/session-context";
import { PageHeader, Prose, TOUCH } from "../../components/erp/page";
import { Pill, Table } from "../../components/erp/panel";
import { callErp, hasPermission } from "../../lib/erp";

export const Route = createFileRoute("/administration/permissions")({
  head: () => ({
    meta: [
      { title: "Permissions — Clove ERP" },
      {
        name: "description",
        content: "View principals and assign or remove permission grants for a tenant.",
      },
      { property: "og:title", content: "Permissions — Clove ERP" },
      {
        property: "og:description",
        content: "View principals and assign or remove permission grants for a tenant.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <Permissions />
    </Gate>
  ),
});

type Principal = {
  id: string;
  display_name: string;
  email: string | null;
  kind: "person" | "service";
  status: string;
  created_at: string;
};

type Role = {
  id: string;
  code: string;
  name: string;
  description: string | null;
  status: string;
  permissions: string[];
};

type Grant = {
  id: string;
  app_user_id: string;
  role_id: string;
  entity_id: string | null;
  site_id: string | null;
  valid_from: string;
  valid_to: string | null;
  grant_reason: string | null;
  created_at: string;
};

type CatalogItem = {
  code: string;
  module_code: string;
  action: string;
  is_mutating: boolean;
};

type Directory = {
  principals: Principal[];
  roles: Role[];
  grants: Grant[];
  permission_catalog: CatalogItem[];
};

function isGrantActive(g: Grant): boolean {
  const today = new Date().toISOString().slice(0, 10);
  return g.valid_from <= today && (!g.valid_to || g.valid_to >= today);
}

function Permissions() {
  const { session } = useErpSession();
  const queryClient = useQueryClient();

  const allowed = hasPermission(session, "administration.roles");

  const { data, isPending, error } = useQuery({
    queryKey: ["erp_permissions_directory"],
    queryFn: () => callErp<Directory>("erp_permissions_directory"),
    enabled: allowed,
  });

  const invalidate = () => {
    queryClient.invalidateQueries({ queryKey: ["erp_permissions_directory"] });
    queryClient.invalidateQueries({ queryKey: ["erp_session"] });
  };

  if (!allowed) {
    return (
      <div className="flex min-w-0 flex-col gap-6">
        <PageHeader title="Permissions">Principals, roles, and the grants between them.</PageHeader>
        <p className="rounded-xl border border-border bg-card p-4 text-sm text-muted-foreground sm:p-5">
          This account does not hold <code className="font-mono text-xs">administration.roles</code>
          , so the directory is not offered. Absence of a grant is a refusal, not a default.
        </p>
      </div>
    );
  }

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title="Permissions">
        A grant is the only way a principal gains a permission. Everything on this page is scoped to{" "}
        <span className="font-medium">{session.tenant?.name}</span> by the database, not by this
        screen.
      </PageHeader>

      <ActionBar
        title="Bringing somebody in"
        note="Bringing somebody into this organisation. An invitation returns a single-use token to hand over."
        actions={[
          {
            label: "Invite a person",
            permission: "administration.users",
            fn: "erp_invite_principal",
            fields: [
              {
                kind: "text",
                name: "p_email",
                label: "Email",
                required: true,
                placeholder: "sam@northwindfoods.co.uk",
                hint: "They sign in with this address.",
              },
              {
                kind: "text",
                name: "p_display_name",
                label: "Name",
                required: true,
                placeholder: "Sam Ogunjobi",
                hint: "The name shown beside their actions.",
              },
            ],
            invalidates: ["erp_permissions_directory"],
          },
          {
            label: "Create a service user",
            permission: "administration.users",
            fn: "erp_create_service_principal",
            fields: [
              {
                kind: "text",
                name: "p_display_name",
                label: "Name",
                required: true,
                placeholder: "Warehouse scanner",
                hint: "A name for the machine account, not a person.",
              },
            ],
            invalidates: ["erp_permissions_directory"],
          },
        ]}
      />

      {isPending ? (
        <p className="text-sm text-muted-foreground">Loading…</p>
      ) : error ? (
        <div role="alert" className="rounded-xl border border-border bg-card p-5">
          <p className="text-sm font-medium text-destructive">This did not load.</p>
          <p className="mt-1 text-xs text-muted-foreground">{friendlyError(error).title}</p>
        </div>
      ) : data ? (
        <>
          <GrantForm directory={data} onDone={invalidate} />
          <GrantsPanel directory={data} onDone={invalidate} />
          <RolesPanel directory={data} onDone={invalidate} />
        </>
      ) : null}
    </div>
  );
}

function GrantForm({ directory, onDone }: { directory: Directory; onDone: () => void }) {
  const [appUserId, setAppUserId] = useState("");
  const [roleId, setRoleId] = useState("");
  const [validFrom, setValidFrom] = useState("");
  const [validTo, setValidTo] = useState("");
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);

  const mutation = useMutation({
    mutationFn: () =>
      callErp("erp_grant_role", {
        p_app_user_id: appUserId,
        p_role_id: roleId,
        p_valid_from: validFrom || undefined,
        p_valid_to: validTo || null,
        p_grant_reason: reason || null,
      }),
    onSuccess: () => {
      setAppUserId("");
      setRoleId("");
      setValidFrom("");
      setValidTo("");
      setReason("");
      setError(null);
      onDone();
    },
    onError: (e) => setError((e as Error).message),
  });

  const activeRoles = directory.roles.filter((r) => r.status === "active");

  return (
    <section className="rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <h2 className="text-sm font-semibold">Assign a role</h2>
        <Prose className="mt-0.5 text-xs text-muted-foreground">
          Granting takes effect from the validity date; the database, not this form, decides.
        </Prose>
      </header>
      <form
        className="grid grid-cols-1 gap-3 px-4 py-4 sm:px-5 md:grid-cols-2 lg:grid-cols-3"
        onSubmit={(e) => {
          e.preventDefault();
          setError(null);
          mutation.mutate();
        }}
      >
        <label className="flex flex-col gap-1 text-sm">
          <span className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Principal
          </span>
          <select
            required
            value={appUserId}
            onChange={(e) => setAppUserId(e.target.value)}
            className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
          >
            <option value="">Choose…</option>
            {directory.principals.map((p) => (
              <option key={p.id} value={p.id}>
                {p.display_name}
                {p.status !== "active" ? ` (${p.status})` : ""}
              </option>
            ))}
          </select>
        </label>

        <label className="flex flex-col gap-1 text-sm">
          <span className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Role
          </span>
          <select
            required
            value={roleId}
            onChange={(e) => setRoleId(e.target.value)}
            className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
          >
            <option value="">Choose…</option>
            {activeRoles.map((r) => (
              <option key={r.id} value={r.id}>
                {r.name} ({r.permissions.length})
              </option>
            ))}
          </select>
        </label>

        <label className="flex flex-col gap-1 text-sm">
          <span className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Reason
          </span>
          <input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="Why this grant exists"
            className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
          />
        </label>

        <label className="flex flex-col gap-1 text-sm">
          <span className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Valid from
          </span>
          <input
            type="date"
            value={validFrom}
            onChange={(e) => setValidFrom(e.target.value)}
            className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
          />
        </label>

        <label className="flex flex-col gap-1 text-sm">
          <span className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Valid to
          </span>
          <input
            type="date"
            value={validTo}
            onChange={(e) => setValidTo(e.target.value)}
            className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
          />
        </label>

        <div className="flex items-end">
          <button
            type="submit"
            disabled={mutation.isPending}
            className={`${TOUCH} inline-flex items-center justify-center rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground disabled:opacity-60`}
          >
            {mutation.isPending ? "Granting…" : "Grant role"}
          </button>
        </div>

        {error ? (
          <p role="alert" className="text-sm text-destructive sm:col-span-2 lg:col-span-3">
            {error}
          </p>
        ) : null}
      </form>
    </section>
  );
}

function GrantsPanel({ directory, onDone }: { directory: Directory; onDone: () => void }) {
  const [error, setError] = useState<string | null>(null);
  const mutation = useMutation({
    mutationFn: (id: string) => callErp("erp_revoke_role", { p_user_role_id: id }),
    onSuccess: () => {
      setError(null);
      onDone();
    },
    onError: (e) => setError((e as Error).message),
  });

  const principalName = (id: string) =>
    directory.principals.find((p) => p.id === id)?.display_name ?? "Unknown principal";
  const roleName = (id: string) => directory.roles.find((r) => r.id === id)?.name ?? "Unknown role";

  return (
    <section className="rounded-xl border border-border bg-card">
      <header className="border-b border-border px-4 py-4 sm:px-5">
        <h2 className="text-sm font-semibold">Grants ({directory.grants.length})</h2>
        <p className="mt-0.5 text-xs text-muted-foreground">
          Removing a grant takes effect immediately; the principal's next session reflects it.
        </p>
      </header>
      <div className="px-5 py-4">
        {directory.grants.length === 0 ? (
          <p className="text-sm text-muted-foreground">No grants exist in this organisation yet.</p>
        ) : (
          <Table columns={["Principal", "Role", "Validity", "Reason", "State", ""]}>
            {directory.grants.map((g) => (
              <tr key={g.id} className="border-b border-border/50 last:border-0">
                <td className="py-2 pr-4">{principalName(g.app_user_id)}</td>
                <td className="py-2 pr-4">{roleName(g.role_id)}</td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">
                  {g.valid_from} → {g.valid_to ?? "open"}
                </td>
                <td className="py-2 pr-4 text-xs text-muted-foreground">{g.grant_reason ?? "—"}</td>
                <td className="py-2 pr-4">
                  {isGrantActive(g) ? (
                    <Pill tone="ok">Active</Pill>
                  ) : (
                    <Pill tone="muted">Inactive</Pill>
                  )}
                </td>
                <td className="py-2 text-right">
                  <button
                    onClick={() => mutation.mutate(g.id)}
                    disabled={mutation.isPending}
                    className={`${TOUCH} inline-flex items-center justify-center rounded-md border border-input px-4 text-xs font-medium text-destructive disabled:opacity-50`}
                  >
                    Remove
                  </button>
                </td>
              </tr>
            ))}
          </Table>
        )}
        {error ? (
          <p role="alert" className="mt-3 text-sm text-destructive">
            {error}
          </p>
        ) : null}
      </div>
    </section>
  );
}

function RolesPanel({ directory, onDone }: { directory: Directory; onDone: () => void }) {
  const [editing, setEditing] = useState<Role | null>(null);
  const [creating, setCreating] = useState(false);

  return (
    <section className="rounded-xl border border-border bg-card">
      <header className="flex flex-col gap-3 border-b border-border px-4 py-4 sm:px-5 md:flex-row md:items-start md:justify-between md:gap-4">
        <div>
          <h2 className="text-sm font-semibold">Roles ({directory.roles.length})</h2>
          <Prose className="mt-0.5 text-xs text-muted-foreground">
            A role is a named set of permissions. Nothing here takes effect until it is granted.
          </Prose>
        </div>
        <button
          onClick={() => {
            setEditing(null);
            setCreating(true);
          }}
          className={`${TOUCH} inline-flex shrink-0 items-center justify-center rounded-md border border-input px-4 text-xs font-medium`}
        >
          New role
        </button>
      </header>

      <div className="flex flex-col gap-4 px-4 py-4 sm:px-5">
        {creating || editing ? (
          <RoleForm
            key={editing?.id ?? "new"}
            directory={directory}
            role={editing}
            onDone={() => {
              setCreating(false);
              setEditing(null);
              onDone();
            }}
            onCancel={() => {
              setCreating(false);
              setEditing(null);
            }}
          />
        ) : null}

        {directory.roles.length === 0 ? (
          <p className="text-sm text-muted-foreground">No roles exist in this organisation yet.</p>
        ) : (
          <ul className="flex flex-col gap-3">
            {directory.roles.map((r) => (
              <li key={r.id} className="rounded-lg border border-border/60 p-4">
                <div className="flex items-center justify-between gap-3">
                  <div>
                    <p className="text-sm font-medium">
                      {r.name}{" "}
                      <span className="font-mono text-xs text-muted-foreground">{r.code}</span>
                    </p>
                    {r.description ? (
                      <p className="mt-0.5 text-xs text-muted-foreground">{r.description}</p>
                    ) : null}
                  </div>
                  <div className="flex items-center gap-2">
                    {r.status !== "active" ? <Pill tone="muted">{r.status}</Pill> : null}
                    <button
                      onClick={() => {
                        setCreating(false);
                        setEditing(r);
                      }}
                      className={`${TOUCH} inline-flex items-center justify-center rounded-md border border-input px-4 text-xs font-medium`}
                    >
                      Edit permissions
                    </button>
                  </div>
                </div>
                <ul className="mt-3 flex flex-wrap gap-1.5">
                  {r.permissions.map((p) => (
                    <li
                      key={p}
                      className="rounded-full bg-muted px-2.5 py-1 font-mono text-xs text-muted-foreground"
                    >
                      {p}
                    </li>
                  ))}
                </ul>
              </li>
            ))}
          </ul>
        )}
      </div>
    </section>
  );
}

function RoleForm({
  directory,
  role,
  onDone,
  onCancel,
}: {
  directory: Directory;
  role: Role | null;
  onDone: () => void;
  onCancel: () => void;
}) {
  const [code, setCode] = useState(role?.code ?? "");
  const [name, setName] = useState(role?.name ?? "");
  const [description, setDescription] = useState(role?.description ?? "");
  const [selected, setSelected] = useState<Set<string>>(new Set(role?.permissions ?? []));
  const [error, setError] = useState<string | null>(null);

  const byModule = useMemo(() => {
    const map = new Map<string, CatalogItem[]>();
    for (const item of directory.permission_catalog) {
      const list = map.get(item.module_code) ?? [];
      list.push(item);
      map.set(item.module_code, list);
    }
    return [...map.entries()].sort(([a], [b]) => a.localeCompare(b));
  }, [directory.permission_catalog]);

  const mutation = useMutation({
    mutationFn: () =>
      callErp("erp_save_role", {
        p_role_id: role?.id ?? null,
        p_code: code,
        p_name: name,
        p_description: description || null,
        p_permissions: [...selected].sort(),
      }),
    onSuccess: onDone,
    onError: (e) => setError((e as Error).message),
  });

  const toggle = (perm: string) => {
    const next = new Set(selected);
    if (next.has(perm)) next.delete(perm);
    else next.add(perm);
    setSelected(next);
  };

  return (
    <form
      className="rounded-lg border border-border bg-background p-4"
      onSubmit={(e) => {
        e.preventDefault();
        setError(null);
        mutation.mutate();
      }}
    >
      <p className="text-sm font-semibold">{role ? `Edit ${role.name}` : "New role"}</p>

      <div className="mt-3 grid grid-cols-1 gap-3 md:grid-cols-3">
        <label className="flex flex-col gap-1 text-sm">
          <span className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Code
          </span>
          <input
            required
            disabled={Boolean(role)}
            value={code}
            onChange={(e) => setCode(e.target.value)}
            placeholder="inventory-clerk"
            className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 font-mono text-sm disabled:opacity-60`}
          />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          <span className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Name
          </span>
          <input
            required
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Stock clerk"
            className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
          />
        </label>
        <label className="flex flex-col gap-1 text-sm">
          <span className="text-xs font-medium uppercase tracking-wide text-muted-foreground">
            Description
          </span>
          <input
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            className={`${TOUCH} w-full rounded-md border border-input bg-background px-2 text-sm`}
          />
        </label>
      </div>

      <div className="mt-4 grid grid-cols-1 gap-3 md:grid-cols-2 lg:grid-cols-3">
        {byModule.map(([moduleCode, items]) => (
          <fieldset key={moduleCode} className="rounded-md border border-border/60 p-3">
            <legend className="px-1 font-mono text-xs text-muted-foreground">{moduleCode}</legend>
            <ul className="flex flex-col gap-1.5">
              {items.map((item) => (
                <li key={item.code}>
                  <label className="flex items-center gap-2 text-sm">
                    <input
                      type="checkbox"
                      checked={selected.has(item.code)}
                      onChange={() => toggle(item.code)}
                    />
                    <span className="font-mono text-xs">{item.action}</span>
                    {item.is_mutating ? (
                      <span className="text-[10px] uppercase tracking-wide text-muted-foreground">
                        write
                      </span>
                    ) : null}
                  </label>
                </li>
              ))}
            </ul>
          </fieldset>
        ))}
      </div>

      {error ? (
        <p role="alert" className="mt-3 text-sm text-destructive">
          {error}
        </p>
      ) : null}

      <div className="mt-4 flex gap-2">
        <button
          type="submit"
          disabled={mutation.isPending}
          className={`${TOUCH} inline-flex items-center justify-center rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground disabled:opacity-60`}
        >
          {mutation.isPending ? "Saving…" : role ? "Save changes" : "Create role"}
        </button>
        <button
          type="button"
          onClick={onCancel}
          className={`${TOUCH} inline-flex items-center justify-center rounded-md border border-input px-4 text-sm font-medium`}
        >
          Cancel
        </button>
      </div>
    </form>
  );
}
