import { describe, expect, test } from "bun:test";

import { salesPolicyArgs } from "./modules";

describe("the sales policy form (20260924000000)", () => {
  test("sends the percentages given as numbers, and leaves out what was not given", () => {
    expect(
      salesPolicyArgs({ p_entity_code: "UK", over_ship_pct: "10", short_close_pct: "" }),
    ).toEqual({ p_value: { over_ship_pct: 10 }, p_entity_code: "UK" });
  });

  test("an organisation-wide proposal names no company, site or change", () => {
    expect(salesPolicyArgs({ over_ship_pct: "0", short_close_pct: " 2 " })).toEqual({
      p_value: { over_ship_pct: 0, short_close_pct: 2 },
    });
  });

  test("a site's proposal carries the site and the change it joins", () => {
    expect(
      salesPolicyArgs({ p_site_code: "MAIN", short_close_pct: "1.5", p_change_set_id: "cs-1" }),
    ).toEqual({ p_value: { short_close_pct: 1.5 }, p_site_code: "MAIN", p_change_set_id: "cs-1" });
  });
});
