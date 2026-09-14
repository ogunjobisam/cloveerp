import { describe, expect, test } from "bun:test";

import { normaliseSender, senderProblem } from "../src/core/resend.ts";

describe("a sender address", () => {
  test("the shapes Resend accepts pass", () => {
    expect(senderProblem("hello@cloveerp.com")).toBeNull();
    expect(senderProblem("Clove ERP <hello@cloveerp.com>")).toBeNull();
    expect(senderProblem("Clove ERP Enquiries <leads+web@cloveerp.co.uk>")).toBeNull();
    expect(senderProblem("Siobhan O'Brien <siobhan@cloveerp.com>")).toBeNull();
    expect(senderProblem('"Clove ERP, Sales" <sales@cloveerp.com>')).toBeNull();
  });

  test("the value that failed on 4 September is refused before a request, and named", () => {
    const problem = senderProblem("'Clove ERP <hello@cloveerp.com>");
    expect(problem).toContain("neither");
    expect(senderProblem("Clove ERP hello@cloveerp.com")).not.toBeNull();
    expect(senderProblem("<hello@cloveerp.com")).not.toBeNull();
    expect(senderProblem("hello@cloveerp")).not.toBeNull();
    expect(senderProblem("   ")).toBe("no sender address is set");
  });

  test("a dashboard-pasted value loses its quotes and spaces, and nothing else", () => {
    expect(normaliseSender(" 'Clove ERP <hello@cloveerp.com>' ")).toBe("Clove ERP <hello@cloveerp.com>");
    expect(normaliseSender('"hello@cloveerp.com"')).toBe("hello@cloveerp.com");
    expect(normaliseSender("'unbalanced <a@b.co>")).toBe("'unbalanced <a@b.co>");
    expect(senderProblem(normaliseSender("'Clove ERP <hello@cloveerp.com>'"))).toBeNull();
  });
});
