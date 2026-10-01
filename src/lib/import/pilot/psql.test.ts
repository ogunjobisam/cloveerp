import { describe, expect, test } from "bun:test";
import { callSql } from "./psql";

describe("a door call as SQL", () => {
  test("arguments go by name, as literals the parameter types resolve", () => {
    expect(
      callSql("erp_stage_import", {
        p_object_type: "party_profile",
        p_rows: [{ name: "O'Brien & Co" }],
        p_code: null,
      }),
    ).toBe(
      `select coalesce(to_jsonb(public.erp_stage_import(p_object_type => $q$party_profile$q$, p_rows => $q$[{"name":"O'Brien & Co"}]$q$, p_code => null))::text, 'null');`,
    );
  });

  test("a value holding the quote's own tag is quoted with a longer one", () => {
    expect(callSql("erp_x", { p_a: "a$q$b" })).toContain("$qq$a$q$b$qq$");
  });

  test("only a public door and named parameters are called", () => {
    expect(() => callSql("pg_sleep", {})).toThrow();
    expect(() => callSql("erp_x", { "p_a); drop": 1 })).toThrow();
  });
});
