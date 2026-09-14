import { describe, expect, test } from "bun:test";

import {
  ACT_STORAGE_KEY,
  actView,
  clearStoredAction,
  explain,
  outcomeWords,
  plausibleActionToken,
  readActArrival,
  readStoredAction,
  refusalCode,
  storeAction,
  summaryRows,
  viewForRefusal,
  type ActView,
  type EmailActionPeek,
} from "./email-action";
import { actionLink } from "./email/notification-email";
import { INTERNAL_WORDING } from "./plain-words";
import { ErpError } from "./erp";

const TOKEN = "0f".repeat(32);

const PEEK: EmailActionPeek = {
  tenant_id: "t-1",
  tenant_name: "Clove Foods",
  in_active_organisation: true,
  state: "usable",
  decision: null,
  expires_at: "2026-09-21T09:00:00Z",
  task_id: "task-1",
  document_id: "doc-1",
  summary: {
    object_type: "document",
    document_type: "Purchase order",
    document_number: "PO-000123",
    partner: "Harrow Packaging Ltd",
    value_minor: 420000,
    currency: "GBP",
    minor_units: 2,
    step: "Finance review",
    requested_by: "Ada Lovelace",
    requested_at: "2026-09-14T09:05:00Z",
  },
};

describe("arriving from the email", () => {
  test("reads the token and the decision the email's link carries", () => {
    for (const decision of ["approve", "reject"] as const) {
      const link = actionLink("https://cloveerp.com", TOKEN, decision);
      const url = new URL(link);
      expect(url.pathname).toBe("/act");
      expect(url.search).toBe("");
      expect(readActArrival(url.hash)).toEqual({ token: TOKEN, decision });
    }
  });

  test("keeps rubbish out rather than holding it as a token", () => {
    expect(readActArrival("#t=short&d=approve")).toEqual({ token: null, decision: "approve" });
    expect(readActArrival(`#t=${TOKEN.toUpperCase()}`).token).toBeNull();
    expect(readActArrival(`#t=${TOKEN}%3Cscript%3E`).token).toBeNull();
    expect(readActArrival(`#t=${TOKEN}&d=delete`)).toEqual({ token: TOKEN, decision: null });
    expect(readActArrival("")).toEqual({ token: null, decision: null });
    expect(plausibleActionToken(42)).toBe(false);
  });
});

describe("held for the tab, across signing in", () => {
  test("stores, reads back and clears, and never holds a token that does not look like one", () => {
    const store = new Map<string, string>();
    const fake = {
      getItem: (k: string) => store.get(k) ?? null,
      setItem: (k: string, v: string) => void store.set(k, v),
      removeItem: (k: string) => void store.delete(k),
    };
    const g = globalThis as unknown as { window?: { sessionStorage: typeof fake } | undefined };
    const before = g.window;
    g.window = { sessionStorage: fake };
    try {
      storeAction({ token: TOKEN, decision: "reject" });
      expect(readStoredAction()).toEqual({ token: TOKEN, decision: "reject" });
      store.set(ACT_STORAGE_KEY, JSON.stringify({ token: "nope", decision: "approve" }));
      expect(readStoredAction()).toEqual({ token: null, decision: null });
      store.set(ACT_STORAGE_KEY, "{not json");
      expect(readStoredAction()).toEqual({ token: null, decision: null });
      storeAction({ token: TOKEN, decision: null });
      clearStoredAction();
      expect(store.has(ACT_STORAGE_KEY)).toBe(false);
    } finally {
      g.window = before;
    }
  });

  test("without a window, nothing is held and nothing throws", () => {
    expect(readStoredAction()).toEqual({ token: null, decision: null });
    expect(() => storeAction({ token: TOKEN, decision: "approve" })).not.toThrow();
    expect(() => clearStoredAction()).not.toThrow();
  });
});

describe("which state the page shows", () => {
  const base = {
    token: TOKEN,
    peek: PEEK,
    peekError: null,
    pending: false,
    sessionTenantId: "t-1",
  };

  test("a usable link in the organisation the person is working in asks for the decision", () => {
    expect(actView(base)).toBe("usable");
  });

  test("in another organisation, it offers the switch first", () => {
    expect(actView({ ...base, sessionTenantId: "t-2" })).toBe("wrong_organisation");
  });

  test("the link's own state wins over the organisation", () => {
    for (const state of ["expired", "used", "superseded"] as const) {
      expect(actView({ ...base, peek: { ...PEEK, state }, sessionTenantId: "t-2" })).toBe(state);
    }
  });

  test("nothing to go on, still asking, the wrong person, or an error", () => {
    expect(actView({ ...base, token: null })).toBe("nothing");
    expect(actView({ ...base, peek: undefined, pending: true })).toBe("checking");
    expect(
      actView({
        ...base,
        peek: undefined,
        peekError: new ErpError(
          "CLOVEERP_EMAIL_ACTION_NOT_FOR_YOU: this link is not for the account signed in",
          {
            code: "42501",
          },
        ),
      }),
    ).toBe("not_for_you");
    expect(actView({ ...base, peek: undefined, peekError: new Error("network") })).toBe(
      "unavailable",
    );
  });

  test("a refusal from pressing the button moves the page to what it says", () => {
    const cases: [string, ActView | null][] = [
      ["CLOVEERP_EMAIL_ACTION_USED: this link has already been used", "used"],
      ["CLOVEERP_EMAIL_ACTION_EXPIRED: this link has run out", "expired"],
      ["CLOVEERP_EMAIL_ACTION_SUPERSEDED: the request has changed", "superseded"],
      ["CLOVEERP_EMAIL_ACTION_WRONG_ORGANISATION: another", "wrong_organisation"],
      ["CLOVEERP_EMAIL_ACTION_NOT_FOR_YOU: no", "not_for_you"],
      ["CLOVEERP_DOCUMENT_SELF_APPROVAL: you asked for this approval", null],
      ["CLOVEERP_EMAIL_ACTION_REASON_REQUIRED: a rejection needs a reason", null],
    ];
    for (const [message, view] of cases) {
      expect(viewForRefusal(new ErpError(message, {}))).toBe(view);
    }
    expect(refusalCode("plain words")).toBeNull();
  });
});

describe("what the page says", () => {
  const views: ActView[] = [
    "nothing",
    "checking",
    "not_for_you",
    "unavailable",
    "wrong_organisation",
    "expired",
    "used",
    "superseded",
  ];

  test("every state has a heading and a sentence, in words a customer reads", () => {
    for (const view of views) {
      const words = explain(view, "Clove Foods");
      expect(words.heading.length).toBeGreaterThan(5);
      expect(words.body.length).toBeGreaterThan(10);
      for (const pattern of INTERNAL_WORDING) {
        expect(pattern.test(words.heading)).toBe(false);
        expect(pattern.test(words.body)).toBe(false);
      }
    }
    expect(explain("wrong_organisation", "Clove Foods").heading).toBe(
      "This request belongs to Clove Foods",
    );
  });

  test("the outcome says what happened next", () => {
    expect(outcomeWords("approve", "approved")).toContain("Nothing else is waiting");
    expect(outcomeWords("approve", "pending")).toContain("next approver");
    expect(outcomeWords("reject", "rejected")).toContain("with your reason");
  });

  test("the request's details, as rows, with money read as money", () => {
    const rows = summaryRows(PEEK, (iso) => iso.slice(0, 10));
    expect(rows).toContainEqual({ label: "Number", value: "PO-000123" });
    expect(rows).toContainEqual({ label: "Requested", value: "2026-09-14" });
    expect(rows.find((r) => r.label === "Value")?.value).toContain("4,200.00");
    expect(rows.find((r) => r.label === "Decision due by")).toBeUndefined();
    const plain = summaryRows({ ...PEEK, summary: { step: "Review" } });
    expect(plain.map((r) => r.label)).toEqual(["Organisation", "Approval step"]);
  });
});
