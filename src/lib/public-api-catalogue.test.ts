import { describe, expect, test } from "vitest";

import { createPublicApiSpec, publicApiOperations } from "./public-api-catalogue";

describe("public API catalogue", () => {
  test("has unique stable operations and governed doors", () => {
    expect(new Set(publicApiOperations.map((entry) => entry.operationId)).size).toBe(
      publicApiOperations.length,
    );
    expect(publicApiOperations.every((entry) => entry.door.startsWith("erp_"))).toBe(true);
    expect(publicApiOperations.every((entry) => entry.permission.includes("."))).toBe(true);
  });

  test("requires idempotency keys on every write", () => {
    const spec = createPublicApiSpec();
    for (const entry of publicApiOperations.filter((operation) => operation.write)) {
      const operation = spec.paths[`/api/public/v1${entry.path}`]?.[
        entry.method.toLowerCase()
      ] as { parameters?: Array<{ name?: string; required?: boolean }> };
      expect(operation.parameters).toContainEqual(
        expect.objectContaining({ name: "Idempotency-Key", required: true }),
      );
    }
  });
});