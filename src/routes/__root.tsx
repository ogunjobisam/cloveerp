import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import {
  Outlet,
  createRootRouteWithContext,
  redirect,
  useRouter,
  HeadContent,
  Scripts,
} from "@tanstack/react-router";
import { useEffect, useState, type ReactNode } from "react";

import appCss from "../styles.css?url";
import { toast } from "sonner";
import { Toaster } from "../components/ui/sonner";
import { goesWithThePage } from "../lib/toast-age";
import { reportLovableError } from "../lib/lovable-error-reporting";
import { NotFoundComponent } from "../components/erp/not-found";
import { APEX_ORIGIN, apexRedirect } from "../lib/backend";
import { askDirectoryAgain, ensureBackend, type BackendState } from "../lib/erp";
import { hostKindOf, requestPageHost } from "../lib/request-host";

function ErrorComponent({ error, reset }: { error: Error; reset: () => void }) {
  console.error(error);
  const router = useRouter();
  useEffect(() => {
    reportLovableError(error, { boundary: "tanstack_root_error_component" });
  }, [error]);

  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="max-w-md text-center">
        <h1 className="font-display text-xl font-medium tracking-tight text-foreground">
          This page didn't load
        </h1>
        <p className="mt-2 text-sm text-muted-foreground">
          Something went wrong on our end. You can try refreshing or head back home.
        </p>
        <div className="mt-6 flex flex-wrap justify-center gap-2">
          <button
            onClick={() => {
              router.invalidate();
              reset();
            }}
            className="inline-flex items-center justify-center rounded-full bg-primary px-5 py-2.5 text-sm font-semibold text-primary-foreground transition-colors hover:bg-primary/90"
          >
            Try again
          </button>
          <a
            href="/"
            className="inline-flex items-center justify-center rounded-full border border-input bg-background px-5 py-2.5 text-sm font-semibold text-foreground transition-colors hover:bg-accent"
          >
            Go home
          </a>
        </div>
      </div>
    </div>
  );
}

export const Route = createRootRouteWithContext<{ queryClient: QueryClient }>()({
  // Which host this is (src/lib/request-host.ts): a directory host shows
  // nothing until the directory has said which project it talks to.
  //
  // The product page and the enquiry form are the apex's. Asked for on a
  // client's host or the demonstration, they are the apex's page instead:
  // answered with a redirect on the server, and a whole-page move on a
  // navigation inside the page, so no link or typed address renders them
  // there. The demonstration's enquiry form would otherwise post to the
  // demonstration's project, where nobody reads it.
  beforeLoad: async ({ location }) => {
    const host = await requestPageHost();
    const away = apexRedirect(location.pathname, location.searchStr, host);
    if (away !== null) throw redirect({ href: away });
    return { hostKind: hostKindOf(host), host };
  },
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { name: "google-site-verification", content: "hV7r-oxT-gL4bf4h7QMYT76AKgqa6EBD5vdzoiUbwlg" },
      { title: "Clove ERP — Enterprise Resource Planning" },
      {
        name: "description",
        content:
          "Clove ERP keeps entries above the rule and the derived position beneath it: finance, inventory and operations on one append-only, tenant-isolated ledger.",
      },
      { name: "author", content: "Clove ERP" },
      { property: "og:title", content: "Clove ERP — Enterprise Resource Planning" },
      {
        property: "og:description",
        content:
          "Clove ERP keeps entries above the rule and the derived position beneath it: finance, inventory and operations on one append-only, tenant-isolated ledger.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
      { property: "og:site_name", content: "Clove ERP" },
      { name: "theme-color", content: "#A2591E" },
    ],
    links: [
      { rel: "stylesheet", href: appCss },
      { rel: "preconnect", href: "https://fonts.googleapis.com" },
      { rel: "preconnect", href: "https://fonts.gstatic.com", crossOrigin: "anonymous" },
      {
        rel: "stylesheet",
        href: "https://fonts.googleapis.com/css2?family=Outfit:wght@400;500;600;700&family=Figtree:wght@400;500;600;700&display=swap",
      },
      { rel: "icon", href: "/favicon.svg", type: "image/svg+xml" },
      { rel: "alternate icon", href: "/favicon.ico", type: "image/x-icon" },
      { rel: "apple-touch-icon", href: "/favicon.svg" },
    ],
  }),
  shellComponent: RootShell,
  component: RootComponent,
  notFoundComponent: NotFoundComponent,
  errorComponent: ErrorComponent,
});

function RootShell({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <head>
        <HeadContent />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  );
}

/**
 * The tab's title follows the route the moment it changes.
 *
 * HeadContent writes the title once the new route has rendered, and a route in
 * its own chunk renders only when the chunk has arrived — so the tab still said
 * "Stock — Clove ERP" after landing on Purchasing. The destination's own head()
 * is read as the navigation starts instead. Every route here states its title
 * as a literal, so reading it needs nothing the route has not loaded yet; one
 * that ever does is skipped, and HeadContent sets it a moment later as before.
 */
function useTitleFollowsTheRoute() {
  const router = useRouter();
  useEffect(
    () =>
      router.subscribe("onBeforeNavigate", ({ toLocation }) => {
        const matches = router.matchRoutes(toLocation.pathname, toLocation.search);
        for (let i = matches.length - 1; i >= 0; i--) {
          const routeId = matches[i]?.routeId;
          const head = routeId ? router.looseRoutesById[routeId]?.options.head : undefined;
          if (!head) continue;
          try {
            const declared = (head as (ctx: never) => { meta?: { title?: string }[] })({} as never);
            const title = declared?.meta?.find((m) => typeof m?.title === "string")?.title;
            if (title) {
              document.title = title;
              return;
            }
          } catch {
            /* a head() that needs its route's data: HeadContent will set it */
          }
        }
      }),
    [router],
  );
}

/**
 * A toast showing when the page changes goes with the page (5 October
 * re-test): it sat over the next screen's process strip and its first form.
 * One raised a moment before stays, because it is the outcome of the press that
 * opened the page. A change of record on the same screen is not a change of
 * page. See src/lib/toast-age.ts.
 */
function useToastsGoWithThePage() {
  const router = useRouter();
  useEffect(
    () =>
      router.subscribe("onBeforeNavigate", ({ fromLocation, toLocation }) => {
        if (!fromLocation || fromLocation.pathname === toLocation.pathname) return;
        const now = Date.now();
        for (const t of toast.getToasts()) if (goesWithThePage(t.id, now)) toast.dismiss(t.id);
      }),
    [router],
  );
}

/**
 * On a directory host, nothing until the project is known.
 *
 * One build serves every client, and a page opened at acme.cloveerp.com
 * learns which project it talks to from the directory on the control plane
 * (src/lib/erp.ts, ensureBackend). Until it has, no screen is shown: a screen
 * rendered against no project would say "not connected", and one rendered
 * against production would be worse. The server renders this same shell for
 * a directory host, so the first paint and the hydration agree.
 *
 * Two answers that look alike are kept apart. A host the directory does not
 * hold is nobody's, and says so; it never falls through to production. A
 * directory that cannot answer just now, with no fresh copy kept in this
 * browser, is not that: the page says it could not find out, and Try again
 * asks once more.
 */
function BackendBoundary({ children }: { children: ReactNode }) {
  const [state, setState] = useState<"pending" | BackendState>("pending");
  // How many times the visitor has asked again: each asks the directory anew.
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let live = true;
    void (attempt === 0 ? ensureBackend() : askDirectoryAgain()).then((answer) => {
      if (live) setState(answer);
    });
    return () => {
      live = false;
    };
  }, [attempt]);

  if (state === "ready") return <>{children}</>;
  const where = typeof window === "undefined" ? "this address" : window.location.host;
  return (
    <div className="flex min-h-screen items-center justify-center bg-background px-4">
      <div className="w-full max-w-md text-center">
        {state === "pending" ? (
          <p role="status" className="text-sm text-muted-foreground">
            Connecting…
          </p>
        ) : state === "unreachable" ? (
          <>
            <h1 className="font-display text-xl font-medium tracking-tight text-foreground">
              Cannot connect just now
            </h1>
            <p className="mt-2 text-sm text-muted-foreground">
              The service that says which organisation is at {where} did not answer. Nothing is
              wrong with your account or your organisation. Try again in a moment.
            </p>
            <button
              type="button"
              onClick={() => {
                setState("pending");
                setAttempt((n) => n + 1);
              }}
              className="mt-6 inline-flex items-center justify-center rounded-full bg-primary px-5 py-2.5 text-sm font-semibold text-primary-foreground transition-colors hover:bg-primary/90"
            >
              Try again
            </button>
          </>
        ) : (
          <>
            <h1 className="font-display text-xl font-medium tracking-tight text-foreground">
              No organisation at this address
            </h1>
            <p className="mt-2 text-sm text-muted-foreground">
              Nothing is served at {where}. Check the address you were given, or start from the
              front door.
            </p>
            <a
              href={APEX_ORIGIN}
              className="mt-6 inline-flex items-center justify-center rounded-full border border-input bg-background px-5 py-2.5 text-sm font-semibold text-foreground transition-colors hover:bg-accent"
            >
              Go to cloveerp.com
            </a>
          </>
        )}
      </div>
    </div>
  );
}

function RootComponent() {
  const { queryClient, hostKind } = Route.useRouteContext();
  useTitleFollowsTheRoute();
  useToastsGoWithThePage();

  return (
    <QueryClientProvider client={queryClient}>
      {/* Required: nested routes render here. Removing <Outlet /> breaks all child routes. */}
      {hostKind === "directory" ? (
        <BackendBoundary>
          <Outlet />
        </BackendBoundary>
      ) : (
        <Outlet />
      )}
      {/* What an action did is said out loud, once, wherever it was pressed —
          and then goes. Bottom right put it on top of the record panel's
          buttons: "GRN-2026-000003 created" sat over "Receive an order" through
          six clicks, because a toast stops its clock while the pointer is on it
          and the pointer was on it trying to reach the button underneath. Top
          centre, just under the header, is over the page's title, where there
          is nothing to press; five seconds, and never more than three at once. */}
      <Toaster
        position="top-center"
        offset={76}
        duration={5000}
        visibleToasts={3}
        closeButton
        richColors
      />
    </QueryClientProvider>
  );
}
