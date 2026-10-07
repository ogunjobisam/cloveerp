import { createIsomorphicFn } from "@tanstack/react-start";

import { chooseBackend, pageHost } from "./backend";

/**
 * Whether the host a page was opened at is one this build knows, or a
 * client's, whose project only the directory knows (src/lib/backend.ts).
 *
 * Asked by the root route on both sides of the first render, so that the
 * server and the browser agree on what to show: on a client's host both show
 * the connecting shell until the directory has answered, and no screen is
 * rendered on the server against a project it does not have. The server
 * reads the host the request was made to, as the visitor typed it;
 * the browser reads its own.
 */
export type HostKind = "static" | "directory";

const env = {
  url: import.meta.env["VITE_SUPABASE_URL"] as string | undefined,
  key: import.meta.env["VITE_SUPABASE_PUBLISHABLE_KEY"] as string | undefined,
};

export function hostKindOf(host: string | null): HostKind {
  return chooseBackend(host, env) === null ? "directory" : "static";
}

/** The host a request was made to, without its port, as the visitor typed it. */
export function requestHost(request: Request): string {
  const named =
    request.headers.get("x-forwarded-host") ??
    request.headers.get("host") ??
    new URL(request.url).host;
  return (named.split(",")[0] ?? "").trim().split(":")[0]?.toLowerCase() ?? "";
}

export const requestHostKind = createIsomorphicFn()
  .server(async (): Promise<HostKind> => {
    const { getRequest } = await import("@tanstack/react-start/server");
    const host = requestHost(getRequest());
    return hostKindOf(host === "" ? null : host);
  })
  .client(async (): Promise<HostKind> => hostKindOf(pageHost()));
