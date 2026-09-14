import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { callErp } from "../../lib/erp";
import { isPlatformOperator, usePlatformMe } from "../../lib/platform";
import { maySeedDemo } from "../../lib/self-service";
import { ActionButton, ErrorNote } from "./action";
import { useErpSession } from "./session-context";

/**
 * Whether demo data is offered to this viewer at all.
 *
 * Demo data is created by platform operators and owners, or by anybody while
 * the owner has opened self-service sign-up. The database refuses everyone
 * else; offering a button that can only fail is not help, and neither is a
 * card that talks about demo data with no button on it. So the button and
 * everything around it ask this one question.
 */
export function useMaySeedDemo(): boolean {
  const platform = usePlatformMe();
  const staff = isPlatformOperator(platform.data);
  const open = useQuery({
    queryKey: ["erp_self_service_organisations_open"],
    queryFn: () => callErp<unknown>("erp_self_service_organisations_open"),
    enabled: platform.isSuccess && !staff,
  });
  return maySeedDemo({ staff, open: open.data });
}

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

  const maySeed = useMaySeedDemo();

  if (session.tenant?.code.startsWith("demo-")) return null;
  if (!maySeed) return null;

  return (
    <div className="flex flex-col gap-2">
      <ActionButton onClick={() => mutation.mutate()} busy={mutation.isPending}>
        {mutation.isPending ? "Seeding…" : label}
      </ActionButton>
      <ErrorNote error={mutation.error} />
    </div>
  );
}
