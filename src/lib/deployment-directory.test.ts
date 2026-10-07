import { describe, expect, test } from "bun:test";

import { directoryHost, readDirectoryEntry } from "./deployment-directory";

describe("a host the directory is asked about", () => {
  test("is lower-cased, loses its port, and keeps its dots", () => {
    expect(directoryHost("Acme.CloveERP.com:443")).toBe("acme.cloveerp.com");
    expect(directoryHost("  demo.cloveerp.com ")).toBe("demo.cloveerp.com");
  });

  test("anything not shaped like a DNS name is nobody's", () => {
    expect(directoryHost("")).toBeNull();
    expect(directoryHost("localhost")).toBeNull();
    expect(directoryHost("acme..cloveerp.com")).toBeNull();
    expect(directoryHost("-acme.cloveerp.com")).toBeNull();
    expect(directoryHost("acme.cloveerp.com/x")).toBeNull();
    expect(directoryHost(`${"a".repeat(250)}.cloveerp.com`)).toBeNull();
    expect(directoryHost(null)).toBeNull();
  });
});

describe("what the register answered", () => {
  test("a whole answer is read", () => {
    expect(
      readDirectoryEntry({
        code: "acme",
        client_name: "Acme Ltd",
        url: "https://abcdefghijklmnopqrst.supabase.co",
        key: "sb_publishable_x",
      }),
    ).toEqual({
      code: "acme",
      client_name: "Acme Ltd",
      url: "https://abcdefghijklmnopqrst.supabase.co",
      key: "sb_publishable_x",
    });
  });

  test("a half answer, a plain-http URL or nothing is no answer", () => {
    expect(readDirectoryEntry(null)).toBeNull();
    expect(readDirectoryEntry({ code: "acme" })).toBeNull();
    expect(
      readDirectoryEntry({
        code: "acme",
        client_name: "Acme",
        url: "http://x.supabase.co",
        key: "k",
      }),
    ).toBeNull();
    expect(
      readDirectoryEntry({
        code: "acme",
        client_name: "Acme",
        url: "https://x.supabase.co",
        key: "",
      }),
    ).toBeNull();
  });
});
