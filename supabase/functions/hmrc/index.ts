/**
 * Making Tax Digital for VAT: a company connected to HMRC, its obligations
 * read, and its finalised return submitted (20261013070000).
 *
 * HMRC is called from here and nowhere else: this function holds HMRC's client
 * id and secret (HMRC_CLIENT_ID, HMRC_CLIENT_SECRET) as function secrets, and
 * its own project's service key. The browser never sees a token; the
 * application's Worker never sees one either. Sandbox unless HMRC_ENVIRONMENT
 * says production.
 *
 * Every action starts with the person's own call to erp_hmrc_open_ticket, made
 * with their session, so the database decides whether they may connect, read
 * or submit (finance.close_period). Everything after it is done under that
 * single-use ticket through doors only service_role may execute. What is said
 * to HMRC and how its answers are read is src/lib/hmrc-mtd.ts, shared with the
 * browser and tested against HMRC's own examples.
 *
 *   connect      opens a ticket and answers HMRC's sign-in address. HMRC sends
 *                the person back to https://<apex>/hmrc/callback, a relay that
 *                returns them to their own address with HMRC's code.
 *   exchange     trades the code for tokens, kept in the client's Vault.
 *   obligations  reads the obligations HMRC holds and records them.
 *   submit       submits one finalised return, with the declaration the
 *                person agreed, against HMRC's obligation for its dates, and
 *                records HMRC's receipt.
 *
 * verify_jwt is false in supabase/config.toml: the function asks Supabase Auth
 * who the bearer is itself, as document_output does.
 */
import { createClient, type SupabaseClient } from "@supabase/supabase-js";

import {
  ACCEPT,
  CALLBACK_PATH,
  apiBase,
  authoriseUrl,
  clientIp,
  environmentOf,
  fraudHeaders,
  hmrcProblem,
  obligationToFile,
  readObligations,
  readReceipt,
  returnBody,
  signState,
  verifyState,
  type ClientFacts,
  type HmrcEnvironment,
  type Obligation,
} from "../../../src/lib/hmrc-mtd.ts";
import {
  bearerOf,
  cors,
  env,
  failure,
  jsonBody,
  project,
  refuse,
  reply,
  signedIn,
} from "../_shared/caller.ts";

// deno-lint-ignore no-explicit-any
const Deno = (globalThis as any).Deno;

type Rpc = (name: string, args?: Record<string, unknown>) => Promise<unknown>;

function rpcOf(client: SupabaseClient): Rpc {
  return async (name, args) => {
    const { data, error } = await (
      client.rpc as unknown as (
        n: string,
        a?: Record<string, unknown>,
      ) => Promise<{ data: unknown; error: { message: string } | null }>
    ).call(client, name, args);
    if (error) refuse(error.message);
    return data;
  };
}

type Ticket = {
  ticket: string;
  purpose: "connect" | "obligations" | "submit";
  vrn: string;
  auth_user_id: string | null;
  user_email: string | null;
  return_host: string | null;
  document_id: string | null;
  body: Record<string, unknown> | null;
  period_start: string | null;
  period_end: string | null;
  environment: HmrcEnvironment | null;
  access_token: string | null;
  refresh_token: string | null;
  access_expires_at: string | null;
};

type Config = {
  clientId: string;
  clientSecret: string;
  environment: HmrcEnvironment;
  redirectUri: string;
};

function config(): Config {
  const clientId = env("HMRC_CLIENT_ID");
  const clientSecret = env("HMRC_CLIENT_SECRET");
  if (!clientId || !clientSecret) {
    throw new Error(
      "CLOVEERP_HMRC_NOT_CONFIGURED: this deployment is not registered with HMRC yet, so nothing can be filed from here. Ask whoever runs Clove ERP for this organisation.",
    );
  }
  const apex = env("CLOVEERP_APEX") ?? "cloveerp.com";
  return {
    clientId,
    clientSecret,
    environment: environmentOf(env("HMRC_ENVIRONMENT")),
    redirectUri: `https://${apex}${CALLBACK_PATH}`,
  };
}

function asClientFacts(raw: unknown): ClientFacts {
  const x = (raw ?? {}) as Record<string, unknown>;
  const screens = Array.isArray(x["screens"]) ? (x["screens"] as Record<string, unknown>[]) : [];
  const win = (x["window"] ?? {}) as Record<string, unknown>;
  const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
  const deviceId = typeof x["deviceId"] === "string" ? x["deviceId"] : "";
  const userAgent = typeof x["userAgent"] === "string" ? x["userAgent"] : "";
  if (!/^[0-9a-f-]{36}$/i.test(deviceId) || !userAgent || screens.length === 0) {
    throw new Error(
      "CLOVEERP_HMRC_DEVICE_FACTS_MISSING: HMRC requires facts about the device a return is filed from, and the page sent none",
    );
  }
  return {
    deviceId,
    userAgent,
    screens: screens.map((s) => ({
      width: num(s["width"]),
      height: num(s["height"]),
      scalingFactor: num(s["scalingFactor"]) || 1,
      colourDepth: num(s["colourDepth"]) || 24,
    })),
    window: { width: num(win["width"]), height: num(win["height"]) },
    utcOffsetMinutes: num(x["utcOffsetMinutes"]),
  };
}

async function tokenRequest(
  cfg: Config,
  form: Record<string, string>,
): Promise<Record<string, unknown>> {
  const response = await fetch(`${apiBase(cfg.environment)}/oauth/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: cfg.clientId,
      client_secret: cfg.clientSecret,
      ...form,
    }).toString(),
  });
  const json = (await response.json().catch(() => null)) as Record<string, unknown> | null;
  if (!response.ok || !json || typeof json["access_token"] !== "string") {
    const problem = hmrcProblem(response.status, json);
    throw new Error(`CLOVEERP_HMRC_REFUSED: ${problem.words}`);
  }
  return json;
}

/** A live access token for the ticket's company, refreshed and kept if it is about to expire. */
async function accessToken(cfg: Config, admin: Rpc, t: Ticket): Promise<string> {
  const fresh =
    t.access_token && t.access_expires_at && Date.parse(t.access_expires_at) - Date.now() > 60_000;
  if (fresh && t.access_token) return t.access_token;
  if (!t.refresh_token) {
    throw new Error(
      "CLOVEERP_HMRC_REFUSED: The connection to HMRC has expired. Connect the company to HMRC again.",
    );
  }
  const json = await tokenRequest(cfg, {
    grant_type: "refresh_token",
    refresh_token: t.refresh_token,
  });
  await admin("erp_hmrc_store_tokens", {
    p_ticket: t.ticket,
    p_access_token: json["access_token"],
    p_refresh_token: json["refresh_token"],
    p_expires_in: json["expires_in"] ?? null,
    p_refresh_expires_in: null,
    p_scope: json["scope"] ?? null,
    p_environment: cfg.environment,
  });
  return json["access_token"] as string;
}

async function callHmrc(
  cfg: Config,
  token: string,
  headers: Record<string, string>,
  path: string,
  init?: { method: string; body: unknown },
): Promise<{ status: number; json: unknown; headers: Headers }> {
  const response = await fetch(`${apiBase(cfg.environment)}${path}`, {
    method: init?.method ?? "GET",
    headers: {
      accept: ACCEPT,
      authorization: `Bearer ${token}`,
      ...(init ? { "content-type": "application/json" } : {}),
      ...headers,
    },
    ...(init ? { body: JSON.stringify(init.body) } : {}),
  });
  const json = await response.json().catch(() => null);
  return { status: response.status, json, headers: response.headers };
}

function isoDay(d: Date): string {
  return d.toISOString().slice(0, 10);
}

async function readAndRecordObligations(
  cfg: Config,
  admin: Rpc,
  t: Ticket,
  token: string,
  headers: Record<string, string>,
  from: string,
  to: string,
): Promise<Obligation[]> {
  const q = new URLSearchParams({ from, to });
  const r = await callHmrc(cfg, token, headers, `/organisations/vat/${t.vrn}/obligations?${q}`);
  if (r.status === 404) {
    // HMRC holds nothing for these dates: nothing to record, and a ticket
    // only for reading is done with.
    if (t.purpose === "obligations") await admin("erp_hmrc_close_ticket", { p_ticket: t.ticket });
    return [];
  }
  if (r.status !== 200) {
    throw new Error(`CLOVEERP_HMRC_REFUSED: ${hmrcProblem(r.status, r.json).words}`);
  }
  const list = readObligations(r.json);
  await admin("erp_hmrc_record_obligations", { p_ticket: t.ticket, p_obligations: list });
  return list;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(req) });
  if (req.method !== "POST") return reply(req, 405, { error: "POST only" });
  try {
    const { url, anonKey, serviceKey } = project();
    const bearer = bearerOf(req);
    const userId = bearer ? await signedIn(url, anonKey, bearer) : null;
    if (!bearer || !userId) return reply(req, 401, { error: "Sign in first." });

    const input = ((await jsonBody(req)) ?? {}) as Record<string, unknown>;
    const action = input["action"];
    const cfg = config();

    // The person's own session on the door that opens a ticket, so the
    // database decides as them; the service key only acts within a ticket.
    const caller = rpcOf(
      createClient(url, anonKey, {
        auth: { persistSession: false, autoRefreshToken: false },
        global: { headers: { authorization: `Bearer ${bearer}` } },
      }),
    );
    const admin = rpcOf(
      createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } }),
    );
    const ticketOf = async (id: string): Promise<Ticket> => {
      const t = (await admin("erp_hmrc_ticket", { p_ticket: id })) as Ticket;
      if (t.auth_user_id !== userId) {
        throw new Error(
          "CLOVEERP_HMRC_TICKET_NOT_IN_FORCE: this request to HMRC was opened by somebody else",
        );
      }
      return t;
    };
    const factsFor = (t: Ticket) =>
      fraudHeaders(asClientFacts(input["client"]), {
        clientPublicIp: clientIp(req.headers.get("x-forwarded-for")),
        clientPublicIpAt: new Date(),
        vendorPublicIp: null,
        userIds: { "clove-erp": t.user_email ?? userId },
        productName: "Clove ERP",
        versions: { "clove-erp": env("CLOVEERP_VERSION") ?? "1" },
      });

    if (action === "connect") {
      const host =
        typeof input["return_host"] === "string" ? input["return_host"].toLowerCase() : null;
      const ticket = (await caller("erp_hmrc_open_ticket", {
        p_purpose: "connect",
        p_entity_id: input["entity_id"],
        p_return_host: host,
      })) as string;
      const state = await signState(cfg.clientSecret, ticket, host ?? "");
      return reply(req, 200, {
        url: authoriseUrl({
          environment: cfg.environment,
          clientId: cfg.clientId,
          redirectUri: cfg.redirectUri,
          state,
        }),
      });
    }

    if (action === "exchange") {
      const verified = await verifyState(cfg.clientSecret, String(input["state"] ?? ""));
      if (!verified) {
        throw new Error(
          "CLOVEERP_HMRC_TICKET_NOT_IN_FORCE: HMRC's answer did not come from a request made here",
        );
      }
      const t = await ticketOf(verified.ticket);
      if (t.purpose !== "connect") {
        throw new Error(
          "CLOVEERP_HMRC_TICKET_NOT_IN_FORCE: HMRC's answer is not to a request to connect",
        );
      }
      const json = await tokenRequest(cfg, {
        grant_type: "authorization_code",
        code: String(input["code"] ?? ""),
        redirect_uri: cfg.redirectUri,
      });
      const done = await admin("erp_hmrc_store_tokens", {
        p_ticket: t.ticket,
        p_access_token: json["access_token"],
        p_refresh_token: json["refresh_token"],
        p_expires_in: json["expires_in"] ?? null,
        // A refresh token lasts eighteen months and HMRC does not say so in the answer.
        p_refresh_expires_in: 47_304_000,
        p_scope: json["scope"] ?? null,
        p_environment: cfg.environment,
      });
      return reply(req, 200, done);
    }

    if (action === "obligations") {
      const ticket = (await caller("erp_hmrc_open_ticket", {
        p_purpose: "obligations",
        p_entity_id: input["entity_id"],
      })) as string;
      const t = await ticketOf(ticket);
      const token = await accessToken(cfg, admin, t);
      const today = new Date();
      const from = new Date(today.getTime() - 365 * 86_400_000);
      const list = await readAndRecordObligations(
        cfg,
        admin,
        t,
        token,
        factsFor(t),
        isoDay(from),
        isoDay(today),
      );
      return reply(req, 200, { obligations: list });
    }

    if (action === "submit") {
      const ticket = (await caller("erp_hmrc_open_ticket", {
        p_purpose: "submit",
        p_document_id: input["document_id"],
        p_declaration: input["declaration"] === true,
      })) as string;
      const t = await ticketOf(ticket);
      if (!t.body || !t.period_start || !t.period_end) {
        throw new Error("CLOVEERP_HMRC_SUBMISSION_INVALID: the return carries no body to submit");
      }
      const headers = factsFor(t);
      const token = await accessToken(cfg, admin, t);
      const list = await readAndRecordObligations(
        cfg,
        admin,
        t,
        token,
        headers,
        t.period_start,
        t.period_end,
      );
      const chosen = obligationToFile(list, t.period_start, t.period_end, cfg.environment);
      const open = chosen?.obligation ?? null;
      // In HMRC's sandbox only: the test period stood in for the return's own.
      const standIn = chosen?.standIn
        ? { start: open?.start, end: open?.end, period_key: open?.periodKey }
        : null;
      if (!open) {
        throw new Error(
          `CLOVEERP_HMRC_NO_OPEN_OBLIGATION: HMRC holds no open return for ${t.period_start} to ${t.period_end}. Read the obligations from HMRC and check the company's VAT periods match HMRC's.`,
        );
      }
      const body = returnBody(t.body, open.periodKey);
      const r = await callHmrc(cfg, token, headers, `/organisations/vat/${t.vrn}/returns`, {
        method: "POST",
        body,
      });
      if (r.status === 201 || r.status === 200) {
        const receipt = readReceipt(r.json, r.headers);
        const recorded = await admin("erp_hmrc_record_submission", {
          p_ticket: t.ticket,
          p_period_key: open.periodKey,
          p_body: body,
          p_receipt: receipt,
          p_outcome: "accepted",
        });
        return reply(req, 200, { receipt, recorded, sandbox_period: standIn });
      }
      const problem = hmrcProblem(r.status, r.json);
      if (problem.code === "DUPLICATE_SUBMISSION") {
        // HMRC holds a return for the period already: recorded as held, so
        // the screen stops offering to submit it.
        const recorded = await admin("erp_hmrc_record_submission", {
          p_ticket: t.ticket,
          p_period_key: open.periodKey,
          p_body: body,
          p_receipt: { correlationId: r.headers.get("X-CorrelationId") },
          p_outcome: "already_held",
        });
        return reply(req, 200, { already_held: true, recorded, sandbox_period: standIn });
      }
      throw new Error(`CLOVEERP_HMRC_REFUSED: ${problem.words}`);
    }

    return reply(req, 400, { error: "The request is not understood." });
  } catch (error) {
    return failure(req, error);
  }
});
