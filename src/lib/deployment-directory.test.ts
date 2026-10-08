import { describe, expect, test } from "bun:test";

import {
  DIRECTORY_CACHE_TTL_MS,
  cacheKey,
  cachedEntryJson,
  directoryHost,
  directoryOutcome,
  keptCopyAfter,
  movedHref,
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

describe("a suspended client, and one that has moved", () => {
  const named = { code: "acme", client_name: "Acme Ltd" };

  test("a suspended answer names the client and nothing to talk to", () => {
    expect(readDirectoryEntry({ ...named, suspended: true })).toEqual({
      ...named,
      suspended: true,
    });
  });

  test("suspended wins over whatever else the answer carries, and drops it", () => {
    const both = {
      ...named,
      suspended: true,
      url: "https://abcdefghijklmnopqrst.supabase.co",
      key: "sb_publishable_x",
      moved_to: "https://acme-group.cloveerp.com",
    };
    expect(readDirectoryEntry(both)).toEqual({ ...named, suspended: true });
  });

  test("suspension said any way but true or false is no answer, never a project", () => {
    const project = { url: "https://abcdefghijklmnopqrst.supabase.co", key: "sb_publishable_x" };
    for (const odd of ["true", 1, "yes", {}]) {
      expect(readDirectoryEntry({ ...named, ...project, suspended: odd })).toBeNull();
    }
    // Saying it is not suspended is the ordinary answer.
    expect(readDirectoryEntry({ ...named, ...project, suspended: false })).toEqual({
      ...named,
      ...project,
    });
    expect(readDirectoryEntry({ ...named, ...project, suspended: null })).toEqual({
      ...named,
      ...project,
    });
  });

  test("a moved answer names the new origin under the apex", () => {
    expect(readDirectoryEntry({ ...named, moved_to: "https://acme-group.cloveerp.com" })).toEqual({
      ...named,
      moved_to: "https://acme-group.cloveerp.com",
    });
  });

  test("a move anywhere but another client's address is no answer, never a project", () => {
    const project = { url: "https://abcdefghijklmnopqrst.supabase.co", key: "sb_publishable_x" };
    for (const to of [
      "http://acme-group.cloveerp.com",
      "https://acme-group.cloveerp.com/",
      "https://acme-group.cloveerp.com/signin",
      "https://acme-group.cloveerp.com:8443",
      "https://evil.example.com",
      "https://cloveerp.com.evil.example.com",
      "https://cloveerp.com",
      "https://www.cloveerp.com",
      "https://demo.cloveerp.com",
      "//acme-group.cloveerp.com",
      "",
      42,
    ]) {
      expect(readDirectoryEntry({ ...named, ...project, moved_to: to })).toBeNull();
    }
  });

  test("a kept suspension or move is read back like a project", () => {
    const at = 1_700_000_000_000;
    const suspended = { ...named, suspended: true as const };
    const moved = { ...named, moved_to: "https://acme-group.cloveerp.com" };
    expect(readCachedEntry(cachedEntryJson(suspended, at), at + 1)).toEqual(suspended);
    expect(readCachedEntry(cachedEntryJson(moved, at), at + 1)).toEqual(moved);
  });
});

describe("where a page at a moved address goes", () => {
  const here = {
    host: "acme.cloveerp.com",
    pathname: "/sales/orders",
    search: "?id=SO-2026-000042",
    hash: "#lines",
  };

  test("the same path, query and fragment at the new address", () => {
    expect(movedHref("https://acme-group.cloveerp.com", here)).toBe(
      "https://acme-group.cloveerp.com/sales/orders?id=SO-2026-000042#lines",
    );
    expect(
      movedHref("https://acme-group.cloveerp.com", {
        ...here,
        pathname: "/",
        search: "",
        hash: "",
      }),
    ).toBe("https://acme-group.cloveerp.com/");
  });

  test("a path that looks like another host stays a path on the new address", () => {
    expect(
      movedHref("https://acme-group.cloveerp.com", { ...here, pathname: "//evil.example.com" }),
    ).toBe("https://acme-group.cloveerp.com//evil.example.com?id=SO-2026-000042#lines");
  });

  test("nowhere new is nowhere: the same address, not https, or not an origin", () => {
    expect(movedHref("https://acme.cloveerp.com", here)).toBeNull();
    expect(
      movedHref("https://ACME.cloveerp.com", { ...here, host: "Acme.CloveERP.com." }),
    ).toBeNull();
    expect(movedHref("http://acme-group.cloveerp.com", here)).toBeNull();
    expect(movedHref("acme-group", here)).toBeNull();
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

  const suspended = { code: "acme", client_name: "Acme Ltd", suspended: true as const };
  const moved = {
    code: "acme",
    client_name: "Acme Ltd",
    moved_to: "https://acme-group.cloveerp.com",
  };

  test("a suspended client is suspended, never found, whatever was kept", () => {
    expect(directoryOutcome({ status: 200, body: suspended }, null)).toEqual({
      kind: "suspended",
      entry: suspended,
      fresh: true,
    });
    // A project kept from before the suspension is not used: the answer wins.
    expect(directoryOutcome({ status: 200, body: suspended }, entry)).toEqual({
      kind: "suspended",
      entry: suspended,
      fresh: true,
    });
  });

  test("a moved address is moved, and the copy kept for it is the move", () => {
    expect(directoryOutcome({ status: 200, body: moved }, entry)).toEqual({
      kind: "moved",
      entry: moved,
      fresh: true,
    });
  });

  test("while it cannot answer, a kept suspension or move still stands", () => {
    expect(directoryOutcome({ status: 503, body: null }, suspended)).toEqual({
      kind: "suspended",
      entry: suspended,
      fresh: false,
    });
    expect(directoryOutcome(null, moved)).toEqual({ kind: "moved", entry: moved, fresh: false });
  });

  test("nobody here forgets a kept suspension or move too", () => {
    expect(directoryOutcome({ status: 404, body: null }, suspended)).toEqual({ kind: "none" });
    expect(directoryOutcome({ status: 404, body: null }, moved)).toEqual({ kind: "none" });
  });
});

describe("what the browser keeps for a host after an answer", () => {
  const project = {
    code: "acme",
    client_name: "Acme Ltd",
    url: "https://abcdefghijklmnopqrst.supabase.co",
    key: "sb_publishable_x",
  };
  const suspended = { code: "acme", client_name: "Acme Ltd", suspended: true as const };
  const moved = {
    code: "acme",
    client_name: "Acme Ltd",
    moved_to: "https://acme-group.cloveerp.com",
  };

  test("the directory's own answer is kept, whichever of the three it is", () => {
    for (const body of [project, suspended, moved]) {
      expect(keptCopyAfter(directoryOutcome({ status: 200, body }, project))).toEqual(body);
    }
  });

  test("a suspension replaces a project kept from before, so an outage cannot serve it", () => {
    const after = keptCopyAfter(directoryOutcome({ status: 200, body: suspended }, project));
    expect(after).toEqual(suspended);
    // Read back while the directory is away, the copy is the suspension.
    const raw = cachedEntryJson(suspended, 1_700_000_000_000);
    expect(
      directoryOutcome({ status: 503, body: null }, readCachedEntry(raw, 1_700_000_000_001)),
    ).toEqual({ kind: "suspended", entry: suspended, fresh: false });
  });

  test("nobody here forgets the copy; a copy only used is left as it is; nothing is nothing", () => {
    expect(keptCopyAfter(directoryOutcome({ status: 404, body: null }, project))).toBe("forget");
    expect(keptCopyAfter(directoryOutcome({ status: 503, body: null }, project))).toBeNull();
    expect(keptCopyAfter(directoryOutcome(null, suspended))).toBeNull();
    expect(keptCopyAfter(directoryOutcome(null, null))).toBeNull();
  });
});
