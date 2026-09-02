import { useQuery } from "@tanstack/react-query";

import { callErp } from "./erp";

/**
 * Whether the organisation in session is the platform's own (v1.5 §17.5).
 *
 * The commercial module — price book, quotes, contracts — belongs to exactly
 * one organisation on a deployment. The database refuses every other one; this
 * hook keeps those tiles off the launchpad and the rail so nobody is offered a
 * door that will be refused.
 */
export function usePlatformOrganisation(enabled = true): boolean {
  const q = useQuery({
    queryKey: ["erp_is_platform_organisation"],
    queryFn: () => callErp<boolean>("erp_is_platform_organisation"),
    enabled,
    staleTime: 5 * 60_000,
  });
  return q.data === true;
}
