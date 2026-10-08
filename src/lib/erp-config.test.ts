import { describe, expect, test } from "bun:test";

import { cacheKey, cachedEntryJson, readCachedEntry } from "./deployment-directory";
import {
  deploymentCode,
  deploymentName,
  ensureBackend,
  isConfigured,
  supabasePublishableKey,
  supabaseUrl,
} from "./erp";

/**
 * A build with no environment is still a build that connects.
 *
 * This is the test for the failure that put "Not connected to a project" on
 * the live site: the two values lived only in a `.env` that left version
 * control, so every publish afterwards shipped an application whose first
 * screen asked the visitor to set environment variables. Nothing failed on the
 * way — typecheck, lint and build were all green on an artefact that could not
 * talk to anything.
 *
 * These run with no `VITE_*` set, which is the state CI builds in, and they
 * assert what the environment used to be the only source of.
 */
describe("the project a build talks to when the host names none", () => {
  test("the build is configured with nothing in the environment", () => {
    expect(isConfigured).toBe(true);
  });

  test("the URL is a Supabase project, not a placeholder", () => {
    expect(supabaseUrl).toMatch(/^https:\/\/[a-z0-9]+\.supabase\.co$/);
  });

  test("the publishable key is a key and belongs to the same project", () => {
    expect(supabasePublishableKey.length).toBeGreaterThan(40);

    // A Supabase publishable key is either the legacy anon JWT, whose payload
    // names the project ref and the anon role, or an opaque `sb_publishable_`
    // key. Both are public; neither is a service-role key, and this is where
    // that would be caught.
    expect(supabasePublishableKey).not.toContain("service_role");

    const ref = supabaseUrl.replace(/^https:\/\//, "").split(".")[0];
    if (supabasePublishableKey.startsWith("eyJ")) {
      const payload = JSON.parse(
        Buffer.from(supabasePublishableKey.split(".")[1] ?? "", "base64").toString("utf8"),
      ) as { ref?: string; role?: string };
      expect(payload.ref).toBe(ref);
      expect(payload.role).toBe("anon");
    }
  });

  test("with no page there is no client deployment, and the project is known at once", async () => {
    // Loaded where there is no window, as on the server: nothing at module
    // level may need one, and no directory is asked.
    expect(deploymentName).toBeNull();
    expect(deploymentCode).toBeNull();
    expect(await ensureBackend()).toBe("ready");
  });
});

/** How many pages have been opened: each loads its own copy of the module. */
let pages = 0;

/**
 * A page opened at a client's address, before it has asked the directory:
 * src/lib/erp.ts loaded afresh (a module decides its project as it loads)
 * under a window at `host` whose directory answers with `directory`, and
 * whose browser already keeps what `kept` holds. The window and fetch are put
 * back afterwards, whatever happens.
 */
async function pageAt<T>(
  host: string,
  directory: (url: string) => Promise<Response>,
  kept: Map<string, string>,
  look: (erp: typeof import("./erp"), asked: string[]) => Promise<T>,
): Promise<T> {
  const hadWindow = Reflect.has(globalThis, "window");
  const window = Reflect.get(globalThis, "window");
  const fetch = Reflect.get(globalThis, "fetch");
  const storage = {
    getItem: (k: string) => kept.get(k) ?? null,
    setItem: (k: string, v: string) => void kept.set(k, v),
    removeItem: (k: string) => void kept.delete(k),
  };
  const asked: string[] = [];
  Reflect.set(globalThis, "window", {
    location: { hostname: host, host, pathname: "/", search: "", hash: "" },
    localStorage: storage,
    sessionStorage: storage,
  });
  Reflect.set(globalThis, "fetch", (input: unknown) => {
    const url = String(input);
    asked.push(url);
    return directory(url);
  });
  try {
    pages += 1;
    const fresh = `./erp.ts?page=${pages}`;
    const erp = (await import(fresh)) as typeof import("./erp");
    return await look(erp, asked);
  } finally {
    if (hadWindow) Reflect.set(globalThis, "window", window);
    else Reflect.deleteProperty(globalThis, "window");
    Reflect.set(globalThis, "fetch", fetch);
  }
}

describe("a page at a client's address that is not served (ensureBackend)", () => {
  const HOST = "acme.cloveerp.com";
  const project = {
    code: "acme",
    client_name: "Acme Ltd",
    url: "https://abcdefghijklmnopqrst.supabase.co",
    key: "sb_publishable_x",
  };
  const answer = (body: unknown) => () => Promise.resolve(Response.json(body));

  test("suspended: says so, and boots nothing", async () => {
    const kept = new Map<string, string>();
    await pageAt(
      HOST,
      answer({ code: "acme", client_name: "Acme Ltd", suspended: true }),
      kept,
      async (erp, asked) => {
        expect(erp.supabase).toBeNull();
        expect(await erp.ensureBackend()).toBe("suspended");
        // No project: nothing a screen could talk to, and no address to move to.
        expect(erp.supabase).toBeNull();
        expect(erp.isConfigured).toBe(false);
        expect(erp.supabaseUrl).toBe("");
        expect(erp.supabasePublishableKey).toBe("");
        expect(erp.deploymentCode).toBeNull();
        expect(erp.deploymentMovedTo).toBeNull();
        expect(erp.deploymentName).toBe("Acme Ltd");
        // Asked once, on the page's own origin; asking again answers the same.
        expect(await erp.ensureBackend()).toBe("suspended");
        expect(asked).toEqual([`/api/directory/${HOST}`]);
      },
    );
    // The suspension is what the browser keeps for the host now.
    expect(readCachedEntry(kept.get(cacheKey(HOST)) ?? null, Date.now())).toEqual({
      code: "acme",
      client_name: "Acme Ltd",
      suspended: true,
    });
  });

  test("suspended after a project was kept: the kept project is not booted, and is replaced", async () => {
    const kept = new Map([[cacheKey(HOST), cachedEntryJson(project, Date.now())]]);
    await pageAt(HOST, answer({ ...project, suspended: true }), kept, async (erp) => {
      expect(await erp.ensureBackend()).toBe("suspended");
      expect(erp.supabase).toBeNull();
    });
    expect(readCachedEntry(kept.get(cacheKey(HOST)) ?? null, Date.now())).toEqual({
      code: "acme",
      client_name: "Acme Ltd",
      suspended: true,
    });
  });

  test("suspended and the directory away: the kept suspension stands, and nothing boots", async () => {
    const suspension = { code: "acme", client_name: "Acme Ltd", suspended: true as const };
    const kept = new Map([[cacheKey(HOST), cachedEntryJson(suspension, Date.now())]]);
    await pageAt(
      HOST,
      () => Promise.reject(new TypeError("network down")),
      kept,
      async (erp) => {
        expect(await erp.ensureBackend()).toBe("suspended");
        expect(erp.supabase).toBeNull();
      },
    );
  });

  test("moved: names where the client is now, and boots nothing", async () => {
    const kept = new Map<string, string>();
    await pageAt(
      HOST,
      answer({
        code: "acme",
        client_name: "Acme Group",
        moved_to: "https://acme-group.cloveerp.com",
      }),
      kept,
      async (erp, asked) => {
        expect(erp.deploymentMovedTo).toBeNull();
        expect(await erp.ensureBackend()).toBe("moved");
        expect(erp.deploymentMovedTo).toBe("https://acme-group.cloveerp.com");
        expect(erp.supabase).toBeNull();
        expect(erp.isConfigured).toBe(false);
        expect(erp.deploymentCode).toBeNull();
        expect(erp.deploymentName).toBe("Acme Group");
        expect(asked).toEqual([`/api/directory/${HOST}`]);
      },
    );
  });

  test("a move to anywhere but another client's address is not a move: nothing boots", async () => {
    await pageAt(
      HOST,
      answer({ ...project, moved_to: "https://evil.example.com" }),
      new Map(),
      async (erp) => {
        expect(await erp.ensureBackend()).toBe("unreachable");
        expect(erp.deploymentMovedTo).toBeNull();
        expect(erp.supabase).toBeNull();
      },
    );
  });
});
