import { describe, expect, test } from "bun:test";

import { countPostingArgs } from "./modules";

describe("the count posting policy form (20260927300000)", () => {
  test("sends what was answered, the yes-or-no as a boolean, and leaves out the rest", () => {
    expect(
      countPostingArgs({
        p_entity_code: "UK",
        within_tolerance: "hold",
        self_post_within_tolerance: "",
      }),
    ).toEqual({ p_value: { within_tolerance: "hold" }, p_entity_code: "UK" });
  });

  test("the counter's own travels as false, not as the word", () => {
    expect(countPostingArgs({ self_post_within_tolerance: "false" })).toEqual({
      p_value: { self_post_within_tolerance: false },
    });
  });

  test("a site's proposal carries the site and the change it joins, and nothing else", () => {
    expect(
      countPostingArgs({
        p_site_code: "MAIN",
        within_tolerance: "post",
        self_post_within_tolerance: "true",
        p_change_set_id: "cs-1",
        scrap_pct: "5",
      }),
    ).toEqual({
      p_value: { within_tolerance: "post", self_post_within_tolerance: true },
      p_site_code: "MAIN",
      p_change_set_id: "cs-1",
    });
  });
});
