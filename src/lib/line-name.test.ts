import { describe, expect, test } from "bun:test";

import { lineName } from "./line-name";

describe("a line's product is named the same on every panel (J-157)", () => {
  test("by its code and name, with a typed-over description beside them", () => {
    expect(lineName("ZCOAT", "Wool coat", "JT-A added line")).toEqual({
      product: "ZCOAT Wool coat",
      typed: "JT-A added line",
    });
  });

  test("a description that only repeats the name is not said twice", () => {
    expect(lineName("ZCOAT", "Wool coat", "Wool coat")).toEqual({
      product: "ZCOAT Wool coat",
      typed: null,
    });
    expect(lineName("ZCOAT", "Wool coat", null)).toEqual({
      product: "ZCOAT Wool coat",
      typed: null,
    });
  });

  test("a code with no name still names the product", () => {
    expect(lineName("ZCOAT", null, "Coat")).toEqual({ product: "ZCOAT", typed: "Coat" });
  });

  test("a line with no product reads its description", () => {
    expect(lineName(null, null, "Carriage")).toEqual({ product: "Carriage", typed: null });
    expect(lineName(undefined, "  ", "")).toEqual({ product: "", typed: null });
  });
});
