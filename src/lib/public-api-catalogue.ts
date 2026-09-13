export type PublicApiOperation = {
  method: "GET" | "POST";
  path: string;
  operationId: string;
  summary: string;
  description: string;
  permission: string;
  door: string;
  write: boolean;
};

export const PUBLIC_API_VERSION = "v1" as const;

export const publicApiOperations: readonly PublicApiOperation[] = [
  {
    method: "GET",
    path: "/capabilities",
    operationId: "listCapabilities",
    summary: "List enabled capabilities",
    description: "Returns the capabilities available to the service principal's organisation.",
    permission: "administration.read",
    door: "erp_capabilities",
    write: false,
  },
  {
    method: "GET",
    path: "/products",
    operationId: "listProducts",
    summary: "List products",
    description: "Returns the organisation's product directory in code order.",
    permission: "master_data.read",
    door: "erp_items",
    write: false,
  },
  {
    method: "GET",
    path: "/documents",
    operationId: "listDocuments",
    summary: "List documents",
    description: "Returns business documents visible to the service principal.",
    permission: "administration.read",
    door: "erp_documents",
    write: false,
  },
  {
    method: "POST",
    path: "/commands",
    operationId: "submitCommand",
    summary: "Submit an integration command",
    description: "Queues an existing governed integration operation. Requires Idempotency-Key.",
    permission: "administration.integrate",
    door: "erp_submit_command",
    write: true,
  },
] as const;

export function createPublicApiSpec() {
  const paths: Record<string, Record<string, unknown>> = {};
  for (const operation of publicApiOperations) {
    paths[`/api/public/${PUBLIC_API_VERSION}${operation.path}`] = {
      [operation.method.toLowerCase()]: {
        operationId: operation.operationId,
        summary: operation.summary,
        description: operation.description,
        security: [{ apiKey: [] }],
        parameters: operation.write
          ? [
              {
                name: "Idempotency-Key",
                in: "header",
                required: true,
                schema: { type: "string", minLength: 8, maxLength: 200 },
              },
            ]
          : [],
        responses: {
          "200": { description: "Successful response" },
          "400": { description: "Invalid request" },
          "401": { description: "Missing, invalid or revoked API key" },
          "403": { description: `The service principal lacks ${operation.permission}` },
          "409": { description: "Idempotency key was reused with different input" },
        },
        "x-clove-door": operation.door,
        "x-clove-permission": operation.permission,
      },
    };
  }

  return {
    openapi: "3.1.0",
    info: {
      title: "Clove ERP REST API",
      version: "1.0.0",
      description:
        "A versioned, allow-listed REST view of Clove ERP's governed public doors. API keys belong to service principals and use existing permission codes.",
    },
    servers: [{ url: "/" }],
    paths,
    components: {
      securitySchemes: {
        apiKey: { type: "http", scheme: "bearer", bearerFormat: "Clove API key" },
      },
    },
  };
}
