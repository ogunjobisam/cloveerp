import { describe, expect, test } from "bun:test";

import { outcomeFor } from "../routes/contact";

/**
 * The contact form has two successes and they are not the same success.
 *
 * The enquiry function stores the enquiry and then emails the platform owners,
 * and either of those can happen without the other. The page must never show
 * "that has reached us" for an enquiry nobody was told about: the sender would
 * stop chasing, which is the one outcome worse than the form being down.
 *
 * These are the cases that decide it.
 */
describe("what the page shows for what the function said", () => {
  test("stored and emailed is the only state that claims somebody was told", () => {
    expect(outcomeFor(true, { notified: true })).toEqual({ kind: "answered" });
  });

  test("stored and not emailed says so rather than thanking them", () => {
    expect(outcomeFor(true, { notified: false })).toEqual({ kind: "recorded_only" });
  });

  test("a missing notified flag is not permission to claim a delivery", () => {
    // The function always sends the field. If a future version stops, or a
    // proxy mangles the body, the page must fall to the honest side rather
    // than to the reassuring one.
    expect(outcomeFor(true, {})).toEqual({ kind: "recorded_only" });

    // And what actually arrives over the wire, which the type cannot describe:
    // a body carrying null rather than a boolean.
    const overTheWire = JSON.parse('{"notified": null}') as { notified?: boolean };
    expect(outcomeFor(true, overTheWire)).toEqual({ kind: "recorded_only" });
  });

  test("a refusal keeps the wording the database chose, and the field it names", () => {
    // erp.record_enquiry() writes its refusals to be read by the person who
    // tripped them, so the page passes them through rather than inventing
    // something vaguer.
    expect(
      outcomeFor(false, {
        error: "that does not look like an email address",
        field: "email",
      }),
    ).toEqual({
      kind: "refused",
      field: "email",
      message: "that does not look like an email address",
    });
  });

  test("and a refusal with nothing to say still says something", () => {
    expect(outcomeFor(false, {})).toEqual({
      kind: "refused",
      field: null,
      message: "That could not be sent. Please try again.",
    });
  });
});
