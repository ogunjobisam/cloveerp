import { describe, expect, test } from "bun:test";

import { isConfigured, supabasePublishableKey, supabaseUrl } from "./erp";

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
});
