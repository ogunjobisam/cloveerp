import { useMutation, useQueryClient } from "@tanstack/react-query";

import { callErp } from "../../lib/erp";
import { useErpSession } from "./gate";
import { TOUCH } from "./page";

/**
 * The one action that turns an empty operational screen into a populated one.
 *
 * Seeding creates a demo tenant — entities, sites, a viewer principal, and the
 * caller's administrator grant — and makes it the working context. Calling it
 * again returns the same tenant rather than piling up copies.
 *
 * It renders nothing once the working tenant is already a demo, which is what
 * makes it safe to offer from an empty state: on a real tenant whose sales
 * ledger is legitimately empty, "seed demo data" is not the next step and
 * should not be suggested.
 */
export function SeedDemoAction({ label = "Explore with demo data" }: { label?: string }) {
  const { session } = useErpSession();
  const queryClient = useQueryClient();

  const mutation = useMutation({
    mutationFn: () => callErp<{ tenant_id: string; already_existed: boolean }>("erp_seed_demo"),
    onSuccess: () => queryClient.invalidateQueries(),
  });

  if (session.tenant?.code.startsWith("demo-")) return null;

  return (
    <div>
      <button
        onClick={() => mutation.mutate()}
        disabled={mutation.isPending}
        className={`${TOUCH} inline-flex items-center justify-center rounded-md bg-primary px-4 text-sm font-semibold text-primary-foreground disabled:opacity-60`}
      >
        {mutation.isPending ? "Seeding…" : label}
      </button>
      {mutation.error ? (
        <p role="alert" className="mt-2 text-sm text-destructive">
          {(mutation.error as Error).message}
        </p>
      ) : null}
    </div>
  );
}
