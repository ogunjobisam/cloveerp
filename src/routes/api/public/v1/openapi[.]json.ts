import { createFileRoute } from "@tanstack/react-router";

import { createPublicApiSpec } from "../../../../lib/public-api-catalogue";

export const Route = createFileRoute("/api/public/v1/openapi.json")({
  server: {
    handlers: {
      GET: async () =>
        Response.json(createPublicApiSpec(), {
          headers: {
            "cache-control": "public, max-age=300",
            "access-control-allow-origin": "*",
          },
        }),
      OPTIONS: async () =>
        new Response(null, {
          status: 204,
          headers: { "access-control-allow-origin": "*", "access-control-allow-methods": "GET" },
        }),
    },
  },
});