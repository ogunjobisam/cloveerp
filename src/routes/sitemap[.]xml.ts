import { createFileRoute } from "@tanstack/react-router";
import type {} from "@tanstack/react-start";

import { APEX_ORIGIN } from "../lib/backend";
import { requestHost, sitemapRedirect } from "../lib/request-host";

const BASE_URL = APEX_ORIGIN;

interface SitemapEntry {
  path: string;
  changefreq?: "always" | "hourly" | "daily" | "weekly" | "monthly" | "yearly" | "never";
  priority?: string;
}

/**
 * Only the pages a visitor can reach without signing in belong here. Every
 * other route sits behind the tenant gate, so listing it would advertise a
 * sign-in screen rather than a page.
 *
 * `/` is not one of them, which is what this comment always claimed and the
 * list did not: the root is the desk for somebody signed in and a redirect to
 * the product page for everybody else, so listing it offered a crawler either
 * a sign-in screen or a second copy of a page already here.
 */
const entries: SitemapEntry[] = [
  { path: "/product", changefreq: "weekly", priority: "1.0" },
  { path: "/contact", changefreq: "monthly", priority: "0.7" },
];

/**
 * The apex's, and served only there. One Worker answers every host, so a
 * client's host, the demonstration and www would each have served the apex's
 * list as their own; a sitemap names pages on its own host only, so anywhere
 * else the answer is a permanent move to the apex's.
 */
export const Route = createFileRoute("/sitemap.xml")({
  server: {
    handlers: {
      GET: async ({ request }) => {
        const elsewhere = sitemapRedirect(requestHost(request) || null);
        if (elsewhere !== null) {
          return new Response(null, {
            status: 301,
            headers: { Location: elsewhere, "Cache-Control": "public, max-age=3600" },
          });
        }
        const urls = entries.map((e) =>
          [
            `  <url>`,
            `    <loc>${BASE_URL}${e.path}</loc>`,
            e.changefreq ? `    <changefreq>${e.changefreq}</changefreq>` : null,
            e.priority ? `    <priority>${e.priority}</priority>` : null,
            `  </url>`,
          ]
            .filter(Boolean)
            .join("\n"),
        );

        const xml = [
          `<?xml version="1.0" encoding="UTF-8"?>`,
          `<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">`,
          ...urls,
          `</urlset>`,
        ].join("\n");

        return new Response(xml, {
          headers: {
            "Content-Type": "application/xml",
            "Cache-Control": "public, max-age=3600",
          },
        });
      },
    },
  },
});
