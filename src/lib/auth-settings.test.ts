import { describe, expect, test } from "bun:test";

import { authSettingsUrl, readGoogleEnabled } from "./auth-settings";

/**
 * Google is offered only where the project's Auth says it is on. The shape is
 * what GET /auth/v1/settings answers (checked read-only against production,
 * which has Google, and the demonstration, which does not).
 */
describe("whether a project offers Google", () => {
  const settings = (google: unknown) => ({
    external: { anonymous_users: false, email: true, google, phone: false },
    disable_signup: true,
    mailer_autoconfirm: false,
    saml_enabled: false,
  });

  test("only when Auth says google is a literal true", () => {
    expect(readGoogleEnabled(settings(true))).toBe(true);
  });

  test("a project without it, or an answer of any other shape, offers none", () => {
    for (const answer of [
      settings(false),
      settings("true"),
      settings(1),
      settings(null),
      settings(undefined),
      { external: { email: true } },
      { external: null },
      { external: [true] },
      { google: true },
      { external: "google" },
      [],
      null,
      undefined,
      "true",
      true,
    ]) {
      expect(readGoogleEnabled(answer)).toBe(false);
    }
  });

  test("is asked of the project's own Auth", () => {
    expect(authSettingsUrl("https://abcdefghijklmnopqrst.supabase.co")).toBe(
      "https://abcdefghijklmnopqrst.supabase.co/auth/v1/settings",
    );
    expect(authSettingsUrl("http://127.0.0.1:54321/")).toBe(
      "http://127.0.0.1:54321/auth/v1/settings",
    );
  });
});
