import { createFileRoute } from "@tanstack/react-router";
import type {} from "@tanstack/react-start";

import { APEX_HOST } from "../../lib/backend";
import { relayTarget, stateHost } from "../../lib/hmrc-mtd";

/**
 * Where HMRC sends a person back after they connect a company (20261013070000).
 *
 * HMRC takes a handful of redirect addresses for an application, and every
 * client has an address of its own, so HMRC is given this one. It holds no
 * secret and trusts nothing: it reads which client address the state names
 * and sends the person there with HMRC's answer, to the VAT screen, whose
 * HMRC function verifies the state's signature before it uses the code. A
 * host that is not cloveerp.com or one label under it is refused, so this is
 * never an open redirect.
 */
function answer(request: Request): Response {
  const q = new URL(request.url).searchParams;
  const state = q.get("state");
  const host = relayTarget(stateHost(state ?? ""), APEX_HOST);
  if (!state || !host) {
    return new Response(
      "This link from HMRC is not one Clove ERP made. Connect again from the VAT screen.",
      {
        status: 400,
        headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" },
      },
    );
  }
  const back = new URL(`https://${host}/finance/vat`);
  back.searchParams.set("hmrc_state", state);
  const code = q.get("code");
  const error = q.get("error");
  if (code) back.searchParams.set("hmrc_code", code);
  if (error) back.searchParams.set("hmrc_error", error);
  return new Response(null, {
    status: 302,
    headers: {
      Location: back.toString(),
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
    },
  });
}

export const Route = createFileRoute("/hmrc/callback")({
  server: {
    handlers: {
      GET: async ({ request }) => answer(request),
    },
  },
});
