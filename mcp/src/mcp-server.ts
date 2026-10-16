// The MCP endpoint: Stage 1 read/prepare tools, served statelessly.
//
// createMcpHandler(factory, options) (agents/mcp/server) wraps an MCP server
// into a Worker fetch handler over Streamable HTTP. The authenticated user
// reaches each tool via getMcpAuthContext(), whose props were stored by
// completeAuthorization() in src/auth.ts. Each tool calls a public.erp_* door
// as that user (src/erp.ts).
//
// TODO(live): the factory/handler typing against agents@0.28.1 (its bundled
// @modelcontextprotocol/server only partly ships types) should be confirmed
// against Cloudflare's mcp-worker example / a running Worker. Tools are
// registered schemaless (args validated in-callback) to keep the server simple
// and avoid the SDK's deep zod type instantiation.
import { createMcpHandler, getMcpAuthContext } from "agents/mcp/server";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

import { callDoor, type ConnectorEnv, type UserProps } from "./erp";

/** The props carried on the validated token, as stored at authorization. */
function requireUser(): UserProps {
  const ctx = getMcpAuthContext();
  const props = ctx?.props as UserProps | undefined;
  if (!props?.accessToken) {
    throw new Error("Not authenticated: no CloveERP session on this request.");
  }
  return props;
}

function text(value: unknown) {
  return { content: [{ type: "text" as const, text: JSON.stringify(value, null, 2) }] };
}

function requireDocumentId(args: Record<string, unknown> | undefined): string {
  const id = args?.["document_id"];
  if (typeof id !== "string" || id.length === 0) {
    throw new Error("document_id (the vat_return document id) is required.");
  }
  return id;
}

/** Build the MCP server and register the Stage 1 read/prepare tools. */
function buildServer(env: ConnectorEnv): McpServer {
  const server = new McpServer({ name: "clove-erp", version: "0.1.0" });

  server.tool(
    "vat_obligations",
    "List the VAT obligations (periods due) for the signed-in user's organisation.",
    async () => text(await callDoor(env, requireUser(), "erp_vat_obligations", {})),
  );

  server.tool(
    "vat_boxes",
    "Show the computed VAT box figures for a VAT return document. Args: { document_id }.",
    async (args: Record<string, unknown>) =>
      text(
        await callDoor(env, requireUser(), "erp_vat_boxes", {
          p_document_id: requireDocumentId(args),
        }),
      ),
  );

  server.tool(
    "vat_return_export",
    "Return the MTD submission body for a VAT return (read-only; does not file). Args: { document_id }.",
    async (args: Record<string, unknown>) =>
      text(
        await callDoor(env, requireUser(), "erp_vat_return_export", {
          p_document_id: requireDocumentId(args),
          p_format: "json",
        }),
      ),
  );

  // Stage 2 (submit) is deliberately NOT registered here — it requires HMRC
  // production approval, a human-made declaration, and its own fraud-prevention
  // headers. See mcp/README.md and memory/mcp-connector-build.md.

  return server;
}

/** The MCP fetch handler mounted at /mcp by the OAuth provider (src/index.ts). */
export function mcpHandler(env: ConnectorEnv) {
  // Boundary cast (WIP): the classic @modelcontextprotocol/sdk McpServer and the
  // one agents@0.28.1 expects (@modelcontextprotocol/server) differ by a few
  // internal fields. TODO(live): reconcile against Cloudflare's mcp-worker
  // example — either register tools on the server package's McpServer, or keep
  // this single boundary cast once the flow is proven to run.
  const factory = (() => buildServer(env)) as unknown as Parameters<typeof createMcpHandler>[0];
  return createMcpHandler(factory, { route: "/mcp" });
}
