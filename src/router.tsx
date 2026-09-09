import { QueryClient } from "@tanstack/react-query";
import { createRouter } from "@tanstack/react-router";
import { routeTree } from "./routeTree.gen";
import { ErpError } from "./lib/erp";

/**
 * A refusal is an answer, not a fault.
 *
 * The default three retries turned every "no" from the database into fifteen
 * seconds of "Loading…" followed by a message — a screen a person reads as
 * broken rather than as forbidden. A decided refusal (the database said no, or
 * the routine does not exist on this project) is returned to the screen at
 * once; everything else still gets its retries, because a dropped connection
 * genuinely is worth asking again.
 */
const decided = (error: unknown): boolean => {
  if (!(error instanceof ErpError)) return false;
  if (error.isPermissionDenied) return true;
  return error.code === "PGRST202" || error.code === "PGRST301" || error.code === "42883";
};

export const getRouter = () => {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: {
        retry: (attempt, error) => !decided(error) && attempt < 2,
      },
      mutations: { retry: false },
    },
  });

  const router = createRouter({
    routeTree,
    context: { queryClient },
    scrollRestoration: true,
    defaultPreloadStaleTime: 0,
  });

  return router;
};
