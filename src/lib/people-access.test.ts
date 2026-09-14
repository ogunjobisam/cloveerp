import { describe, expect, test } from "bun:test";
import {
  accessLabel,
  accessState,
  accessWord,
  actionsFor,
  CANNOT_REMOVE_YOURSELF,
  LAST_USER_MANAGER,
  NO_EMAIL_ADDRESS,
  removalOutcome,
  restoreOutcome,
  userManagersOtherThan,
  withdrawalOutcome,
  type DirectoryPrincipal,
} from "./people-access";

function principal(over: Partial<DirectoryPrincipal> & { id: string }): DirectoryPrincipal {
  return {
    display_name: over.id,
    email: `${over.id}@example.test`,
    kind: "person",
    status: "active",
    created_at: "2026-09-01T09:00:00Z",
    ...over,
  };
}

const alone = { selfId: "me", managersRemaining: 1 };

describe("where somebody stands", () => {
  test("an active principal is active", () => {
    expect(accessState(principal({ id: "a" }))).toBe("active");
  });

  test("an invited person with a pending invitation is invited", () => {
    expect(
      accessState(principal({ id: "a", status: "invited", invitation_state: "pending" })),
    ).toBe("invited");
  });

  test("an invited person whose invitation expired says so", () => {
    expect(
      accessState(principal({ id: "a", status: "invited", invitation_state: "expired" })),
    ).toBe("invitation_expired");
  });

  test("an invited person with no invitation open has no link that works", () => {
    expect(accessState(principal({ id: "a", status: "invited", invitation_state: "none" }))).toBe(
      "invitation_expired",
    );
  });

  test("an invited person is invited when the directory does not yet say more", () => {
    expect(accessState(principal({ id: "a", status: "invited" }))).toBe("invited");
  });

  test("a disabled principal is removed", () => {
    expect(accessState(principal({ id: "a", status: "disabled" }))).toBe("removed");
  });

  test("a suspended principal is suspended", () => {
    expect(accessState(principal({ id: "a", status: "suspended" }))).toBe("suspended");
  });

  test("a status this screen does not know never reads as access", () => {
    expect(accessState(principal({ id: "a", status: "archived" }))).toBe("removed");
  });
});

describe("the status pill", () => {
  test("an open invitation names the day its link expires", () => {
    expect(
      accessLabel(
        principal({
          id: "a",
          status: "invited",
          invitation_state: "pending",
          invitation_expires_at: "2026-09-21T10:00:00Z",
        }),
      ),
    ).toBe("Invited · link expires 21 September 2026");
  });

  test("an open invitation with no expiry on file says only invited", () => {
    expect(
      accessLabel(principal({ id: "a", status: "invited", invitation_state: "pending" })),
    ).toBe("Invited");
  });

  test("each other state has its word", () => {
    expect(
      accessLabel(principal({ id: "a", status: "invited", invitation_state: "expired" })),
    ).toBe("Invitation expired");
    expect(accessLabel(principal({ id: "a" }))).toBe("Active");
    expect(accessLabel(principal({ id: "a", status: "disabled" }))).toBe("Removed");
    expect(accessLabel(principal({ id: "a", status: "suspended" }))).toBe("Suspended");
  });

  test("a picker gets the state as one lower-case phrase", () => {
    expect(accessWord(principal({ id: "a", status: "disabled" }))).toBe("removed");
    expect(accessWord(principal({ id: "a", status: "invited", invitation_state: "expired" }))).toBe(
      "invitation expired",
    );
  });
});

describe("who can still manage users", () => {
  const directory = [
    principal({ id: "me", manages_users: true }),
    principal({ id: "other", manages_users: true }),
    principal({ id: "clerk", manages_users: false }),
    principal({ id: "gone", status: "disabled", manages_users: true }),
    principal({ id: "invitee", status: "invited", manages_users: true }),
    principal({ id: "support", manages_users: true, is_support: true }),
    principal({ id: "robot", kind: "service", manages_users: true }),
  ];

  test("counts only active people outside platform support who hold administration.users", () => {
    expect(userManagersOtherThan(directory, "me")).toBe(1);
    expect(userManagersOtherThan(directory, "other")).toBe(1);
    expect(userManagersOtherThan(directory, "clerk")).toBe(2);
  });

  test("counts nobody when the directory does not yet say who manages users", () => {
    expect(userManagersOtherThan([principal({ id: "a" }), principal({ id: "b" })], "a")).toBe(0);
  });
});

describe("what a row offers", () => {
  test("an invitation can be sent again or withdrawn", () => {
    expect(
      actionsFor(principal({ id: "a", status: "invited", invitation_state: "pending" }), alone),
    ).toEqual([
      { action: "send_invitation_again", disabledReason: null },
      { action: "withdraw_invitation", disabledReason: null },
    ]);
  });

  test("an expired invitation offers the same two", () => {
    expect(
      actionsFor(principal({ id: "a", status: "invited", invitation_state: "expired" }), alone).map(
        (o) => o.action,
      ),
    ).toEqual(["send_invitation_again", "withdraw_invitation"]);
  });

  test("an invitation with no address cannot be sent again, but can be withdrawn", () => {
    expect(actionsFor(principal({ id: "a", status: "invited", email: null }), alone)).toEqual([
      { action: "send_invitation_again", disabledReason: NO_EMAIL_ADDRESS },
      { action: "withdraw_invitation", disabledReason: null },
    ]);
  });

  test("an active person can be removed", () => {
    expect(actionsFor(principal({ id: "a", manages_users: false }), alone)).toEqual([
      { action: "remove_access", disabledReason: null },
    ]);
  });

  test("you cannot remove yourself, and are told why", () => {
    expect(actionsFor(principal({ id: "me", manages_users: true }), alone)).toEqual([
      { action: "remove_access", disabledReason: CANNOT_REMOVE_YOURSELF },
    ]);
  });

  test("the last person who can manage users cannot be removed, and the row says why", () => {
    expect(
      actionsFor(principal({ id: "a", manages_users: true }), {
        selfId: "me",
        managersRemaining: 0,
      }),
    ).toEqual([{ action: "remove_access", disabledReason: LAST_USER_MANAGER }]);
  });

  test("a user manager with another beside them can be removed", () => {
    expect(
      actionsFor(principal({ id: "a", manages_users: true }), {
        selfId: "me",
        managersRemaining: 1,
      }),
    ).toEqual([{ action: "remove_access", disabledReason: null }]);
  });

  test("somebody who does not manage users is never the last one", () => {
    expect(
      actionsFor(principal({ id: "a", manages_users: false }), {
        selfId: "me",
        managersRemaining: 0,
      }),
    ).toEqual([{ action: "remove_access", disabledReason: null }]);
  });

  test("a removed person who had joined can be restored", () => {
    expect(
      actionsFor(principal({ id: "a", status: "disabled", has_signed_in: true }), alone),
    ).toEqual([{ action: "restore_access", disabledReason: null }]);
  });

  test("a removed person who never joined is invited again instead", () => {
    expect(
      actionsFor(principal({ id: "a", status: "disabled", has_signed_in: false }), alone),
    ).toEqual([{ action: "invite_again", disabledReason: null }]);
  });

  test("a withdrawn invitation with no address cannot be sent again", () => {
    expect(
      actionsFor(
        principal({ id: "a", status: "disabled", has_signed_in: false, email: " " }),
        alone,
      ),
    ).toEqual([{ action: "invite_again", disabledReason: NO_EMAIL_ADDRESS }]);
  });

  test("a suspended person is restored or invited again by the same rule", () => {
    expect(
      actionsFor(principal({ id: "a", status: "suspended", has_signed_in: true }), alone),
    ).toEqual([{ action: "restore_access", disabledReason: null }]);
    expect(
      actionsFor(principal({ id: "a", status: "suspended", has_signed_in: false }), alone),
    ).toEqual([{ action: "invite_again", disabledReason: null }]);
  });

  test("platform support is shown with nothing to press, whatever its state", () => {
    for (const status of ["active", "disabled", "invited", "suspended"]) {
      expect(
        actionsFor(principal({ id: "s", status, is_support: true, has_signed_in: true }), alone),
      ).toEqual([]);
    }
  });

  test("a service user can only be removed, and only while active", () => {
    expect(actionsFor(principal({ id: "robot", kind: "service", email: null }), alone)).toEqual([
      { action: "remove_access", disabledReason: null },
    ]);
    expect(
      actionsFor(principal({ id: "robot", kind: "service", status: "disabled" }), alone),
    ).toEqual([]);
  });

  test("a service user is never the last user manager on the desk", () => {
    expect(
      actionsFor(principal({ id: "robot", kind: "service", manages_users: true }), {
        selfId: "me",
        managersRemaining: 0,
      }),
    ).toEqual([{ action: "remove_access", disabledReason: null }]);
  });
});

describe("what the doors said", () => {
  test("a removal counts the roles and invitations it ended", () => {
    expect(
      removalOutcome("Sam", {
        app_user_id: "a",
        status: "disabled",
        already_removed: false,
        grants_ended: 2,
        invitations_withdrawn: 0,
      }),
    ).toBe("Sam no longer has access. 2 roles ended.");
    expect(removalOutcome("Sam", { grants_ended: 1, invitations_withdrawn: 1 })).toBe(
      "Sam no longer has access. 1 role ended. Their open invitation was withdrawn.",
    );
  });

  test("removing somebody already removed says nothing changed", () => {
    expect(removalOutcome("Sam", { already_removed: true, grants_ended: 0 })).toBe(
      "Sam had already been removed, so nothing changed.",
    );
  });

  test("a removal whose answer is not the expected shape still says access ended", () => {
    expect(removalOutcome("Sam", { removed: "a" })).toBe("Sam no longer has access.");
    expect(removalOutcome("Sam", null)).toBe("Sam no longer has access.");
  });

  test("a withdrawal says the link no longer works", () => {
    expect(withdrawalOutcome("Sam", { invitations_withdrawn: 1 })).toBe(
      "The invitation to Sam was withdrawn. Its link no longer works.",
    );
    expect(withdrawalOutcome("Sam", { invitations_withdrawn: 0 })).toBe(
      "Sam is no longer invited.",
    );
  });

  test("a restore says no roles came back", () => {
    expect(restoreOutcome("Sam")).toBe(
      "Sam can sign in again. They hold no roles yet, so give them the roles they need below.",
    );
  });
});
