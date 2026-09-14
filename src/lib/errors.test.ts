import { describe, expect, test } from "bun:test";
import {
  FunctionsFetchError,
  FunctionsHttpError,
  FunctionsRelayError,
} from "@supabase/supabase-js";

import { ErpError, inviteFailure, InviteNotRun, InviteOutcomeUnknown } from "./erp";
import { friendlyError, setRefusalResources } from "./errors";

/**
 * D34: a refusal names the next action.
 *
 * The register lives in erp_ref.refusal and arrives through the resource
 * dictionary, so these tests hand friendlyError() the same shape the
 * ResourceProvider does and check that a refusal resolves through it — with
 * the organisation's own wording where it has overridden the product's, and
 * the engine's hint winning over the register when the raise carried one.
 */

const dictionary = {
  "refusal.cloveerp_quote_not_accepted.refused":
    "Creating a contract, or renewing, from a quote the customer has not accepted.",
  "refusal.cloveerp_quote_not_accepted.why":
    "A contract records what was agreed; a quote not yet accepted has not been.",
  "refusal.cloveerp_quote_not_accepted.next_action":
    "Record the customer's acceptance on the quote first.",
  "refusal.cloveerp_quote_is_.refused": "An action on a quote whose state does not permit it.",
  "refusal.cloveerp_quote_is_.why": "The action asked for belongs to a different state.",
  "refusal.cloveerp_quote_is_.next_action": "Read the quote's state and the transitions it offers.",
};

function refusal(message: string, hint?: string) {
  return new ErpError(message, { code: "23514", hint });
}

describe("D34: a registered refusal names the next action", () => {
  test("an exact token resolves what was refused, why, and the next action", () => {
    setRefusalResources(dictionary);
    const f = friendlyError(refusal("CLOVEERP_QUOTE_NOT_ACCEPTED: the quote is issued"));
    expect(f.title).toBe(
      "Creating a contract, or renewing, from a quote the customer has not accepted.",
    );
    expect(f.body).toBe(
      "A contract records what was agreed; a quote not yet accepted has not been.",
    );
    expect(f.hint).toBe("Record the customer's acceptance on the quote first.");
    expect(f.technical).toContain("CLOVEERP_QUOTE_NOT_ACCEPTED");
  });

  test("a family token matches by its registered prefix", () => {
    setRefusalResources(dictionary);
    const f = friendlyError(
      refusal("CLOVEERP_QUOTE_IS_ACCEPTED: an accepted quote is not revised"),
    );
    expect(f.title).toBe("An action on a quote whose state does not permit it.");
    expect(f.hint).toBe("Read the quote's state and the transitions it offers.");
  });

  test("the engine's own hint wins over the register's next action", () => {
    setRefusalResources(dictionary);
    const f = friendlyError(
      refusal(
        "CLOVEERP_QUOTE_NOT_ACCEPTED: the quote is issued",
        "Ask the customer to accept CQ-1.",
      ),
    );
    expect(f.hint).toBe("Ask the customer to accept CQ-1.");
  });

  test("an organisation's override is what the person reads", () => {
    setRefusalResources({
      ...dictionary,
      "refusal.cloveerp_quote_not_accepted.next_action": "Ring the account manager.",
    });
    const f = friendlyError(refusal("CLOVEERP_QUOTE_NOT_ACCEPTED: the quote is issued"));
    expect(f.hint).toBe("Ring the account manager.");
  });

  test("an unregistered token still shows the engine's own words, as a sentence, never a blank", () => {
    setRefusalResources(dictionary);
    const f = friendlyError(refusal("CLOVEERP_SOMETHING_ELSE: the thing is not allowed here"));
    expect(f.title).toBe("This is not allowed right now.");
    expect(f.body).toBe("The thing is not allowed here.");
  });
});

/**
 * 14 September, on the live desk: invoicing a delivery you despatched yourself
 * showed "This is not allowed right now. you despatched DN-000255 and cannot
 * also invoice it B1 has carried sales.despatch and sales.invoice as separate
 * permissions since it was written; …". A sentence from the database starts
 * with a capital letter, and a note written for the engine's maintainers never
 * reaches the person who was refused.
 */
describe("a refusal speaks to the person who was refused", () => {
  const selfInvoice = () =>
    new ErpError(
      "CLOVEERP_SEGREGATION_OF_DUTIES: you despatched DN-000255 and cannot also invoice it",
      {
        code: "42501",
        hint: "B1 has carried sales.despatch and sales.invoice as separate permissions since it was written; this is the first thing to require that they be held by different people.",
      },
    );

  test("unregistered, the engine's sentence is capitalised and its internal hint is dropped", () => {
    setRefusalResources({});
    const f = friendlyError(selfInvoice());
    expect(f.title).toBe("This is not allowed right now.");
    expect(f.body).toBe("You despatched DN-000255 and cannot also invoice it.");
    expect(f.hint).toBeNull();
    // Kept, folded away, for whoever supports the customer.
    expect(f.technical).toContain("you despatched DN-000255");
  });

  test("registered, the register's next action stands in for the hint it dropped", () => {
    setRefusalResources({
      "refusal.cloveerp_segregation_of_duties.refused":
        "Doing both halves of a job the organisation keeps for two people.",
      "refusal.cloveerp_segregation_of_duties.why": "The organisation keeps the two steps apart.",
      "refusal.cloveerp_segregation_of_duties.next_action":
        "Ask a colleague who may do this step to do it.",
    });
    const f = friendlyError(selfInvoice());
    expect(f.title).toBe("Doing both halves of a job the organisation keeps for two people.");
    expect(f.body).toBe("The organisation keeps the two steps apart.");
    expect(f.hint).toBe("Ask a colleague who may do this step to do it.");
  });

  test("an engine sentence that is all identifiers is not shown; the technical detail keeps it", () => {
    setRefusalResources({});
    const f = friendlyError(refusal("CLOVEERP_SOMETHING_ELSE: p_transition_code is null"));
    expect(f.body).toBe(
      "A rule in this organisation stopped it. The technical detail below names the rule.",
    );
    expect(f.technical).toContain("p_transition_code");
  });

  test("a register row an organisation wrote in lower case is still a sentence", () => {
    setRefusalResources({
      ...dictionary,
      "refusal.cloveerp_quote_not_accepted.next_action": "ring the account manager",
    });
    const f = friendlyError(refusal("CLOVEERP_QUOTE_NOT_ACCEPTED: the quote is issued"));
    expect(f.hint).toBe("Ring the account manager.");
  });

  test("a denied object is never named on the screen", () => {
    setRefusalResources({});
    const f = friendlyError(
      new ErpError("permission denied for schema erp_meta", { code: "42501" }),
    );
    expect(f.title).toBe("You do not have permission to do this.");
    expect(f.body).toBe(
      "An administrator can grant the missing permission under People and permissions.",
    );
  });

  test("an unrecognised failure shows its words only when they are words", () => {
    setRefusalResources({});
    expect(friendlyError(new Error("the printer is out of paper")).body).toBe(
      "The printer is out of paper.",
    );
    expect(friendlyError(new Error('column "is_committed" does not exist')).body).toBe(
      "The technical detail below says what went wrong.",
    );
  });
});

/**
 * The transition window, and why it is tested rather than trusted.
 *
 * 20260904980000 moved every refusal from ERPWARE_ to CLOVEERP_. The database
 * and this site are deployed separately and by hand, so between the two
 * carries one side is ahead of the other in whichever direction the deploys
 * happened to run. Both directions resolve, and both are pinned here — the
 * shim is deliberate and dated, and deleting it should break a test rather
 * than quietly degrade a refusal into raw database text.
 *
 * Delete this block, the constants it exercises, and the ERPWARE_ half of
 * erp.ts's token regex once both sides have been carried.
 */
describe("the retired prefix, for one release", () => {
  test("a token still raised under ERPWARE_ resolves against the new dictionary", () => {
    setRefusalResources(dictionary);
    const f = friendlyError(refusal("ERPWARE_QUOTE_NOT_ACCEPTED: the quote is issued"));
    expect(f.title).toBe(
      "Creating a contract, or renewing, from a quote the customer has not accepted.",
    );
    expect(f.hint).toBe("Record the customer's acceptance on the quote first.");
  });

  test("a token raised under CLOVEERP_ resolves against a dictionary not yet renamed", () => {
    setRefusalResources({
      "refusal.erpware_quote_not_accepted.refused": "The quote has not been accepted.",
      "refusal.erpware_quote_not_accepted.why": "A contract records what was agreed.",
      "refusal.erpware_quote_not_accepted.next_action": "Record the acceptance first.",
    });
    const f = friendlyError(refusal("CLOVEERP_QUOTE_NOT_ACCEPTED: the quote is issued"));
    expect(f.title).toBe("The quote has not been accepted.");
    expect(f.hint).toBe("Record the acceptance first.");
  });

  test("a family registered under the retired prefix still matches by prefix", () => {
    setRefusalResources({
      "refusal.erpware_quote_is_.refused": "An action on a quote whose state does not permit it.",
      "refusal.erpware_quote_is_.next_action": "Read the quote's state.",
    });
    const f = friendlyError(
      refusal("CLOVEERP_QUOTE_IS_ACCEPTED: an accepted quote is not revised"),
    );
    expect(f.title).toBe("An action on a quote whose state does not permit it.");
  });

  test("the built-in wording is found under either spelling", () => {
    setRefusalResources({});
    for (const token of ["CLOVEERP_PERIOD_CLOSED", "ERPWARE_PERIOD_CLOSED"]) {
      const f = friendlyError(refusal(`${token}: 2026-08 is closed`));
      expect(f.title).toBe("That accounting period is closed.");
    }
  });

  test("a token carrying a digit is matched whole, not truncated at the digit", () => {
    setRefusalResources({});
    const f = friendlyError(refusal("CLOVEERP_C1_SUITE_FAILED: 2 of 40 cases"));
    // Truncating at the C left "1_SUITE_FAILED: 2 of 40 cases" on the screen.
    expect(f.title).toBe("This is not allowed right now.");
    expect(f.body).toBe("2 of 40 cases.");
  });
});

/**
 * An invitation is never made twice by accident.
 *
 * A second erp_invite_principal call supersedes the token the first one
 * emailed, and a second erp_platform_onboard_company call is refused because
 * the organisation exists. So the desk calls the door itself only when the
 * invite function certainly did not run, and a failure that could have
 * happened after it ran says so instead of advising another try.
 */
describe("what a failed call to the invite function means", () => {
  const json = (status: number, body: unknown) =>
    new FunctionsHttpError(
      new Response(JSON.stringify(body), {
        status,
        headers: { "Content-Type": "application/json" },
      }),
    );

  test("a network or relay failure may have run the function, so the outcome is unknown", async () => {
    expect(
      await inviteFailure(new FunctionsFetchError(new TypeError("Failed to fetch"))),
    ).toBeInstanceOf(InviteOutcomeUnknown);
    expect(
      await inviteFailure(new FunctionsRelayError(new Response(null, { status: 502 }))),
    ).toBeInstanceOf(InviteOutcomeUnknown);
  });

  test("only the platform's own 404 or 503 proves nothing ran", async () => {
    expect(
      await inviteFailure(json(404, { message: "Requested function was not found" })),
    ).toBeInstanceOf(InviteNotRun);
    expect(
      await inviteFailure(
        new FunctionsHttpError(new Response("Service Unavailable", { status: 503 })),
      ),
    ).toBeInstanceOf(InviteNotRun);
  });

  test("anything the function said is a refusal in its words, never a reason to retry", async () => {
    const said = await inviteFailure(
      json(400, { error: "CLOVEERP_TENANT_EXISTS: acme", code: "23505", hint: null }),
    );
    expect(said).toBeInstanceOf(ErpError);
    expect((said as ErpError).erpCode).toBe("CLOVEERP_TENANT_EXISTS");
    expect(
      await inviteFailure(json(503, { error: "the invitation could not be sent just now" })),
    ).toBeInstanceOf(ErpError);
    expect(
      await inviteFailure(json(500, { error: "the invitation could not be sent just now" })),
    ).toBeInstanceOf(ErpError);
  });

  test("an unknown outcome tells the person to check the list, not to try again", () => {
    const f = friendlyError(
      new InviteOutcomeUnknown("Failed to send a request to the Edge Function"),
    );
    expect(f.title).toBe("Could not reach the invitation service.");
    expect(f.body).toBe(
      "The invitation may already have been created and emailed, so check the list before trying again.",
    );
    expect(f.technical).toBe("Failed to send a request to the Edge Function");
  });
});
