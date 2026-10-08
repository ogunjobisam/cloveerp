import { describe, expect, test } from "bun:test";

import {
  DIRECTORY_CACHE_TTL_MS,
  cacheKey,
  cachedEntryJson,
  directoryHost,
  directoryOutcome,
  readCachedEntry,
  readDirectoryEntry,
} from "./deployment-directory";

describe("the answer a browser keeps", () => {
  const entry = {
    code: "acme",
    client_name: "Acme Ltd",
    url: "https://abcdefghijklmnopqrst.supabase.co",
    key: "sb_publishable_x",
  };
  const kept = 1_700_000_000_000;

  test("is read back while it is fresh, and not after a day", () => {
    const raw = cachedEntryJson(entry, kept);
    expect(readCachedEntry(raw, kept + 1000)).toEqual(entry);
    expect(readCachedEntry(raw, kept + DIRECTORY_CACHE_TTL_MS)).toEqual(entry);
    expect(readCachedEntry(raw, kept + DIRECTORY_CACHE_TTL_MS + 1)).toBeNull();
  });

  test("a kept answer from the future, a broken one or none is no answer", () => {
    expect(readCachedEntry(cachedEntryJson(entry, kept), kept - 1)).toBeNull();
    expect(readCachedEntry("{not json", kept)).toBeNull();
    expect(readCachedEntry(JSON.stringify({ ...entry, at: "yesterday" }), kept)).toBeNull();
    expect(readCachedEntry(null, kept)).toBeNull();
  });

  test("is kept under the host it answers", () => {
    expect(cacheKey("acme.cloveerp.com")).toBe("cloveerp.backend:acme.cloveerp.com");
  });
});

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

describe("what the browser concludes about a host", () => {
  const entry = {
    code: "acme",
    client_name: "Acme Ltd",
    url: "https://abcdefghijklmnopqrst.supabase.co",
    key: "sb_publishable_x",
  };
  const older = { ...entry, client_name: "Acme Limited" };

  test("an answer naming the project is found, and kept again", () => {
    expect(directoryOutcome({ status: 200, body: entry }, null)).toEqual({
      kind: "found",
      entry,
      fresh: true,
    });
    // The directory's own answer wins over a copy kept from before.
    expect(directoryOutcome({ status: 200, body: entry }, older)).toEqual({
      kind: "found",
      entry,
      fresh: true,
    });
  });

  test("nobody here is nobody here, whatever was kept", () => {
    expect(directoryOutcome({ status: 404, body: null }, null)).toEqual({ kind: "none" });
    expect(directoryOutcome({ status: 404, body: null }, entry)).toEqual({ kind: "none" });
    expect(directoryOutcome({ status: 400, body: null }, entry)).toEqual({ kind: "none" });
  });

  test("a directory that cannot answer is not one that says nobody is here", () => {
    for (const response of [
      null,
      { status: 503, body: null },
      { status: 500, body: null },
      { status: 429, body: null },
      { status: 200, body: { code: "acme" } },
      { status: 200, body: null },
    ]) {
      expect(directoryOutcome(response, null)).toEqual({ kind: "unreachable" });
    }
  });

  test("while it cannot answer, a fresh copy kept from before is used, and not kept again", () => {
    for (const response of [null, { status: 503, body: null }, { status: 200, body: "x" }]) {
      expect(directoryOutcome(response, entry)).toEqual({ kind: "found", entry, fresh: false });
    }
  });
});
