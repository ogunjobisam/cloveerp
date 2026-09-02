import { describe, expect, test } from "bun:test";

import { ErpError } from "./erp";
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
  "refusal.erpware_quote_not_accepted.refused":
    "Creating a contract, or renewing, from a quote the customer has not accepted.",
  "refusal.erpware_quote_not_accepted.why":
    "A contract records what was agreed; a quote not yet accepted has not been.",
  "refusal.erpware_quote_not_accepted.next_action":
    "Record the customer's acceptance on the quote first.",
  "refusal.erpware_quote_is_.refused": "An action on a quote whose state does not permit it.",
  "refusal.erpware_quote_is_.why": "The action asked for belongs to a different state.",
  "refusal.erpware_quote_is_.next_action": "Read the quote's state and the transitions it offers.",
};

function refusal(message: string, hint?: string) {
  return new ErpError(message, { code: "23514", hint });
}

describe("D34: a registered refusal names the next action", () => {
  test("an exact token resolves what was refused, why, and the next action", () => {
    setRefusalResources(dictionary);
    const f = friendlyError(refusal("ERPWARE_QUOTE_NOT_ACCEPTED: the quote is issued"));
    expect(f.title).toBe(
      "Creating a contract, or renewing, from a quote the customer has not accepted.",
    );
    expect(f.body).toBe(
      "A contract records what was agreed; a quote not yet accepted has not been.",
    );
    expect(f.hint).toBe("Record the customer's acceptance on the quote first.");
    expect(f.technical).toContain("ERPWARE_QUOTE_NOT_ACCEPTED");
  });

  test("a family token matches by its registered prefix", () => {
    setRefusalResources(dictionary);
    const f = friendlyError(refusal("ERPWARE_QUOTE_IS_ACCEPTED: an accepted quote is not revised"));
    expect(f.title).toBe("An action on a quote whose state does not permit it.");
    expect(f.hint).toBe("Read the quote's state and the transitions it offers.");
  });

  test("the engine's own hint wins over the register's next action", () => {
    setRefusalResources(dictionary);
    const f = friendlyError(
      refusal(
        "ERPWARE_QUOTE_NOT_ACCEPTED: the quote is issued",
        "Ask the customer to accept CQ-1.",
      ),
    );
    expect(f.hint).toBe("Ask the customer to accept CQ-1.");
  });

  test("an organisation's override is what the person reads", () => {
    setRefusalResources({
      ...dictionary,
      "refusal.erpware_quote_not_accepted.next_action": "Ring the account manager.",
    });
    const f = friendlyError(refusal("ERPWARE_QUOTE_NOT_ACCEPTED: the quote is issued"));
    expect(f.hint).toBe("Ring the account manager.");
  });

  test("an unregistered token still shows the engine's own words, never a blank", () => {
    setRefusalResources(dictionary);
    const f = friendlyError(refusal("ERPWARE_SOMETHING_ELSE: the thing is not allowed here"));
    expect(f.title).toBe("This is not allowed right now.");
    expect(f.body).toBe("the thing is not allowed here");
  });
});
