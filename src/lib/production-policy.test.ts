import { describe, expect, test } from "bun:test";

import { productionPolicyArgs } from "./modules";

describe("the production policy form (20260924500000)", () => {
  test("sends the percentages given as numbers, and leaves out what was not given", () => {
    expect(
      productionPolicyArgs({ p_entity_code: "UK", over_completion_pct: "5", scrap_pct: "" }),
    ).toEqual({ p_value: { over_completion_pct: 5 }, p_entity_code: "UK" });
  });

  test("all four percentages travel, and nothing else does", () => {
    expect(
      productionPolicyArgs({
        over_completion_pct: "0",
        short_completion_pct: " 2 ",
        scrap_pct: "10",
        release_shortage_pct: "1.5",
        over_ship_pct: "9",
      }),
    ).toEqual({
      p_value: {
        over_completion_pct: 0,
        short_completion_pct: 2,
        scrap_pct: 10,
        release_shortage_pct: 1.5,
      },
    });
  });

  test("a site's proposal carries the site and the change it joins", () => {
    expect(
      productionPolicyArgs({
        p_site_code: "MAIN",
        release_shortage_pct: "5",
        p_change_set_id: "cs-1",
      }),
    ).toEqual({
      p_value: { release_shortage_pct: 5 },
      p_site_code: "MAIN",
      p_change_set_id: "cs-1",
    });
  });
});
