import { describe, expect, test } from "bun:test";

import {
  actionsFor,
  groupBySheet,
  heldReason,
  inSite,
  normalise,
  pageSize,
  printed,
  splitWorklist,
  worklistOrder,
  type CountTaskRow,
} from "./count-worklist";

const row = (over: Partial<CountTaskRow> & { task_id: string }): CountTaskRow => ({
  ...normalise({ item: "P1", status: "open" }),
  ...over,
});

describe("a row of erp_count_tasks, whatever age the door is", () => {
  test("the keys 20260927400000 added read as null when the door does not return them", () => {
    const r = normalise({
      task_id: "t1",
      item: "P1",
      site: "MAIN",
      location: "A-01",
      expected: 10,
      counted: null,
      variance: null,
      within_tolerance: null,
      status: "open",
      counted_at: null,
      posted_at: null,
    });
    expect(r.document_id).toBeNull();
    expect(r.document_number).toBeNull();
    expect(r.sheet_line_no).toBeNull();
    expect(r.site_id).toBeNull();
    expect(r.post_held_reason).toBeNull();
    expect(r.posted_by_system).toBe(false);
    expect(r.counted_by_me).toBe(false);
    expect(r.expected).toBe(10);
  });

  test("a numeric sent as text is read as a number", () => {
    expect(normalise({ task_id: "t", expected: "12.5", sheet_line_no: 3 }).expected).toBe(12.5);
  });
});

describe("why a count waits", () => {
  test("nothing to wait for is null", () => {
    expect(heldReason(null)).toBeNull();
    expect(heldReason("  ")).toBeNull();
  });

  test("the policy's two say what they are and nothing more", () => {
    expect(
      heldReason(
        "held_by_policy: the site's count posting policy holds counts inside tolerance for somebody to post",
      ),
    ).toEqual({ code: "held_by_policy", detail: null });
    expect(
      heldReason(
        "held_own_count: the site's count posting policy holds the counter's own count for somebody else to post",
      ),
    ).toEqual({ code: "held_own_count", detail: null });
  });

  test("a cumulative hold keeps its arithmetic", () => {
    expect(
      heldReason(
        "held_cumulative: with 2 count(s) at this place posted by the system since 2026-09-01, the variance comes to -5",
      ),
    ).toEqual({
      code: "held_cumulative",
      detail:
        "with 2 count(s) at this place posted by the system since 2026-09-01, the variance comes to -5",
    });
  });

  test("a refused post keeps its SQLSTATE and the refusal's own words", () => {
    expect(
      heldReason("post_refused: 23502 CLOVEERP_COUNT_HAS_NO_PLACE: the count names no location"),
    ).toEqual({
      code: "post_refused",
      detail: "23502 CLOVEERP_COUNT_HAS_NO_PLACE: the count names no location",
    });
  });

  test("a code not known here arrives whole", () => {
    expect(heldReason("held_for_audit: somebody said so")).toEqual({
      code: "unknown",
      detail: "held_for_audit: somebody said so",
    });
  });
});

describe("the walk follows the paper", () => {
  const rows = [
    row({ task_id: "n2", location: "B-01", item: "Z" }),
    row({ task_id: "s8-2", document_number: "CNT-000008", document_id: "d8", sheet_line_no: 2 }),
    row({ task_id: "s7-2", document_number: "CNT-000007", document_id: "d7", sheet_line_no: 2 }),
    row({ task_id: "n1", location: "A-01", item: "Y" }),
    row({ task_id: "s7-10", document_number: "CNT-000007", document_id: "d7", sheet_line_no: 10 }),
    row({ task_id: "s7-1", document_number: "CNT-000007", document_id: "d7", sheet_line_no: 1 }),
  ];

  test("sheet by sheet, line by line, and the counts with no sheet last by place", () => {
    expect(worklistOrder(rows).map((r) => r.task_id)).toEqual([
      "s7-1",
      "s7-2",
      "s7-10",
      "s8-2",
      "n1",
      "n2",
    ]);
  });

  test("one group per sheet, in that order, and one for the counts with no sheet", () => {
    const groups = groupBySheet(rows);
    expect(groups.map((g) => [g.document_number, g.document_id, g.rows.length])).toEqual([
      ["CNT-000007", "d7", 3],
      ["CNT-000008", "d8", 1],
      [null, null, 2],
    ]);
  });

  test("with no sheet anywhere, the order is by place and then product", () => {
    expect(
      worklistOrder([
        row({ task_id: "c", location: "A-02", item: "A" }),
        row({ task_id: "b", location: "A-01", item: "B" }),
        row({ task_id: "a", location: "A-01", item: "A" }),
      ]).map((r) => r.task_id),
    ).toEqual(["a", "b", "c"]);
  });
});

describe("work, and what waits on somebody", () => {
  const all = [
    row({ task_id: "open", status: "open" }),
    row({ task_id: "held", status: "approved", post_held_reason: "held_by_policy: x" }),
    row({ task_id: "agreed", status: "approved" }),
    row({ task_id: "counted", status: "counted" }),
    row({ task_id: "rejected", status: "rejected" }),
    row({ task_id: "pending", status: "pending_approval" }),
    row({ task_id: "posted", status: "posted" }),
    row({ task_id: "cancelled", status: "cancelled" }),
  ];

  test("the worklist is the open counts; posted and cancelled are in neither table", () => {
    const { toCount, exceptions } = splitWorklist(all);
    expect(toCount.map((r) => r.task_id)).toEqual(["open"]);
    expect(exceptions.map((r) => r.task_id).sort()).toEqual(
      ["agreed", "counted", "held", "pending", "rejected"].sort(),
    );
  });

  test("a count recorded here stays on the worklist saying what became of it", () => {
    const { toCount } = splitWorklist(all, new Set(["posted", "held"]));
    expect(toCount.map((r) => r.task_id).sort()).toEqual(["held", "open", "posted"]);
  });

  test("the site chosen in the header narrows the list; none chosen does not", () => {
    const sited = [
      row({ task_id: "a", site_id: "s1" }),
      row({ task_id: "b", site_id: "s2" }),
      row({ task_id: "c" }),
    ];
    expect(inSite(sited, "").map((r) => r.task_id)).toEqual(["a", "b", "c"]);
    expect(inSite(sited, "s1").map((r) => r.task_id)).toEqual(["a", "c"]);
  });
});

describe("a row offers only what its door accepts, to somebody who may", () => {
  const everything = () => true;
  const counter = (code: string) => code === "inventory.count";
  const adjuster = (code: string) => code === "inventory.adjust";
  const nobody = () => false;

  test("open: Record and Cancel for a counter, nothing for somebody who may not count", () => {
    const r = row({ task_id: "t", status: "open" });
    expect(actionsFor(r, counter)).toEqual({
      record: true,
      post: false,
      postIsSomebodyElses: false,
      recount: false,
      cancel: "inventory.count",
    });
    expect(actionsFor(r, adjuster)).toEqual({
      record: false,
      post: false,
      postIsSomebodyElses: false,
      recount: false,
      cancel: null,
    });
  });

  test("counted outside tolerance, or refused: Count it again and Cancel, both inventory.adjust", () => {
    for (const status of ["counted", "rejected"]) {
      const r = row({ task_id: "t", status });
      expect(actionsFor(r, adjuster)).toEqual({
        record: false,
        post: false,
        postIsSomebodyElses: false,
        recount: true,
        cancel: "inventory.adjust",
      });
      expect(actionsFor(r, counter)).toEqual({
        record: false,
        post: false,
        postIsSomebodyElses: false,
        recount: false,
        cancel: null,
      });
    }
  });

  test("approved: Post for somebody who may adjust stock", () => {
    expect(actionsFor(row({ task_id: "t", status: "approved" }), adjuster).post).toBe(true);
    expect(actionsFor(row({ task_id: "t", status: "approved" }), counter).post).toBe(false);
    expect(
      actionsFor(
        row({ task_id: "t", status: "approved", post_held_reason: "held_by_policy: x" }),
        adjuster,
      ).post,
    ).toBe(true);
  });

  test("a count the door would refuse the reader, for having counted it, is not theirs to post", () => {
    // Whatever held it: the door refuses the counter's own post of a
    // difference once the organisation is live, and says so as
    // post_refused_to_me.
    for (const reason of [
      "held_own_count: somebody else posts it",
      "held_by_policy: the site's policy holds it",
      null,
    ]) {
      const own = row({
        task_id: "t",
        status: "approved",
        counted_by_me: true,
        post_refused_to_me: true,
        post_held_reason: reason,
      });
      expect(actionsFor(own, everything).post).toBe(false);
      expect(actionsFor(own, everything).postIsSomebodyElses).toBe(true);
      expect(actionsFor(own, counter).postIsSomebodyElses).toBe(false);
    }
  });

  test("a held_by_policy count the reader counted is theirs to post while the door would take it", () => {
    // Before go-live, or with no difference to post, counting it is no bar.
    const mine = row({
      task_id: "t",
      status: "approved",
      counted_by_me: true,
      post_refused_to_me: false,
      post_held_reason: "held_by_policy: the site's policy holds it",
    });
    expect(actionsFor(mine, adjuster).post).toBe(true);
    expect(actionsFor(mine, adjuster).postIsSomebodyElses).toBe(false);
  });

  test("with its approver, posted or cancelled: nothing", () => {
    for (const status of ["pending_approval", "posted", "cancelled"]) {
      expect(actionsFor(row({ task_id: "t", status }), everything)).toEqual({
        record: false,
        post: false,
        postIsSomebodyElses: false,
        recount: false,
        cancel: null,
      });
    }
    expect(actionsFor(row({ task_id: "t", status: "open" }), nobody).cancel).toBeNull();
  });
});

describe("a rendered value on paper", () => {
  test("an address or a list is its parts one to a line, never JSON", () => {
    expect(printed({ line1: "1 High Street", line2: null, city: "Leeds" })).toBe(
      "1 High Street\nLeeds",
    );
    expect(printed(["A", 2])).toBe("A\n2");
  });

  test("the sheet's paper size, or A4 when it names none or names something odd", () => {
    expect(pageSize("A5")).toBe("A5");
    expect(pageSize("letter landscape")).toBe("letter landscape");
    expect(pageSize(undefined)).toBe("A4");
    expect(pageSize("A4; } body { color: red")).toBe("A4");
  });

  test("a missing or null value is a blank, anything else is its text", () => {
    expect(printed(undefined)).toBe("");
    expect(printed(null)).toBe("");
    expect(printed(12)).toBe("12");
    expect(printed("A-01")).toBe("A-01");
  });
});
