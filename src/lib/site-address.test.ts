import { describe, expect, test } from "bun:test";

import { siteAddressIsComplete, siteAddressLine } from "./site-address";

describe("a site's address", () => {
  const address = {
    line1: "1 Dock Road",
    line2: "Unit 4",
    city: "London",
    postcode: "E16 1AA",
    country_code: "GB",
  };

  test("reads on one line, in the order a label prints it", () => {
    expect(siteAddressLine(address)).toBe("1 Dock Road, Unit 4, London, E16 1AA, GB");
  });

  test("a site with none reads as none, and is not one a carrier can label from", () => {
    expect(siteAddressLine({})).toBeNull();
    expect(siteAddressLine(null)).toBeNull();
    expect(siteAddressIsComplete({})).toBe(false);
    expect(siteAddressIsComplete({ line1: "1 Dock Road", country_code: "GB" })).toBe(false);
    expect(siteAddressIsComplete(address)).toBe(true);
  });
});
