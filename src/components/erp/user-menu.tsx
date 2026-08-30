import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { Check, ChevronDown } from "lucide-react";

import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

import { callErp, hasPermission, type ErpSession } from "../../lib/erp";
import { usePlatformMe } from "../../lib/platform";
import { useT } from "../../lib/i18n";
import { TOUCH } from "./page";

type MyTenant = {
  tenant_id: string;
  code: string;
  name: string;
  principal_id: string;
  is_active: boolean;
};

function initials(name: string): string {
  const parts = name.trim().split(/\s+/).slice(0, 2);
  const letters = parts.map((p) => p[0] ?? "").join("");
  return (letters || name.slice(0, 2)).toUpperCase();
}

/**
 * Who am I, where am I, and how do I leave.
 *
 * These three questions were answered in three different places: a display
 * name in the header's right margin, a tenant select beside the scope
 * selects, and a sign-out link that looked like body text. One menu is the
 * conventional answer in every ERP shell worth copying, and it also gives
 * tenant settings a home that is not the navigation rail.
 */
export function UserMenu({
  session,
  onSignOut,
  onNavigate,
  className,
}: {
  session: ErpSession;
  onSignOut: () => void;
  onNavigate?: () => void;
  className?: string;
}) {
  const { t } = useT();
  const queryClient = useQueryClient();

  const { data: tenants } = useQuery({
    queryKey: ["erp_my_tenants"],
    queryFn: () => callErp<MyTenant[]>("erp_my_tenants"),
  });

  const choose = useMutation({
    mutationFn: (tenantId: string) => callErp("erp_set_active_tenant", { p_tenant_id: tenantId }),
    // Everything on screen is scoped to the tenant that just changed.
    onSuccess: () => queryClient.invalidateQueries(),
  });

  const name = session.principal?.display_name ?? "Signed in";
  const email = session.principal?.email ?? null;
  const mayAdminister = hasPermission(session, "administration.configure");
  const switchable = (tenants ?? []).length > 1;

  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        className={`${TOUCH} inline-flex items-center gap-2 rounded-md px-2 text-sm hover:bg-muted ${className ?? ""}`}
        aria-label="Account menu"
      >
        <span className="grid size-7 shrink-0 place-items-center rounded-full bg-primary/10 text-[11px] font-semibold text-foreground">
          {initials(name)}
        </span>
        <span className="hidden max-w-[10rem] truncate md:inline">{name}</span>
        <ChevronDown className="size-4 shrink-0 text-muted-foreground" />
      </DropdownMenuTrigger>

      <DropdownMenuContent align="end" className="w-72">
        <DropdownMenuLabel className="flex flex-col gap-0.5">
          <span className="truncate text-sm font-medium">{name}</span>
          {email ? (
            <span className="truncate text-xs font-normal text-muted-foreground">{email}</span>
          ) : null}
          <span className="text-xs font-normal text-muted-foreground">
            {session.tenant?.name ?? "No tenant"}
            {session.tenant?.code ? ` · ${session.tenant.code}` : ""}
          </span>
          {session.principal?.timezone || session.principal?.user_locale ? (
            <span className="text-[11px] font-normal text-muted-foreground">
              {[session.principal.timezone, session.principal.user_locale]
                .filter(Boolean)
                .join(" · ")}
            </span>
          ) : null}
        </DropdownMenuLabel>

        {switchable ? (
          <>
            <DropdownMenuSeparator />
            <DropdownMenuLabel className="text-[11px] uppercase tracking-wide text-muted-foreground">
              {t("nav.switch_tenant", "Switch tenant")}
            </DropdownMenuLabel>
            {(tenants ?? []).map((tenant) => (
              <DropdownMenuItem
                key={tenant.tenant_id}
                disabled={choose.isPending || tenant.is_active}
                onSelect={() => {
                  if (!tenant.is_active) choose.mutate(tenant.tenant_id);
                }}
                className="gap-2"
              >
                <Check
                  className={`size-4 shrink-0 ${tenant.is_active ? "opacity-100" : "opacity-0"}`}
                />
                <span className="truncate">
                  {tenant.code} — {tenant.name}
                </span>
              </DropdownMenuItem>
            ))}
          </>
        ) : null}

        {mayAdminister ? (
          <>
            <DropdownMenuSeparator />
            <DropdownMenuItem asChild>
              <Link to="/administration/tenant" onClick={onNavigate}>
                {t("nav.tenant_settings", "Tenant settings")}
              </Link>
            </DropdownMenuItem>
            <DropdownMenuItem asChild>
              <Link to="/administration/terminology" onClick={onNavigate}>
                {t("nav.terminology", "Terminology & branding")}
              </Link>
            </DropdownMenuItem>
          </>
        ) : null}

        {platform.data?.is_staff ? (
          <>
            <DropdownMenuSeparator />
            <DropdownMenuItem asChild>
              <Link to="/platform" onClick={onNavigate}>
                {t("nav.platform_console", "Platform console")}
              </Link>
            </DropdownMenuItem>
          </>
        ) : null}

        <DropdownMenuSeparator />
        <DropdownMenuItem onSelect={onSignOut}>{t("action.sign_out", "Sign out")}</DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
