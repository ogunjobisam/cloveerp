import { createFileRoute } from "@tanstack/react-router";
import type {} from "@tanstack/react-start";

import { requestHost, robotsFor } from "../lib/request-host";

/**
 * robots.txt, by host.
 *
 * It was a static file, and static files are served before the Worker is
 * asked (wrangler's assets), so every host got the public site's: "Allow: /"
 * on a client's sign-in and on the demonstration, with the apex's sitemap.
 * One Worker answers every host, so the answer is made here instead: the
 * public site's as it always was on the apex and www, and nothing to crawl
 * anywhere else (src/lib/request-host.ts, robotsFor).
 */
export const Route = createFileRoute("/robots.txt")({
  server: {
    handlers: {
      GET: async ({ request }) =>
        new Response(robotsFor(requestHost(request) || null), {
          headers: {
            "Content-Type": "text/plain; charset=utf-8",
            "Cache-Control": "public, max-age=3600",
          },
        }),
    },
  },
});
