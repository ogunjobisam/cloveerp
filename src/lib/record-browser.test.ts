import { describe, expect, test } from "bun:test";

import { narrow, serverSearchTerm, type BrowserColumn } from "../components/erp/record-browser";

/**
 * The filter boxes are the one part of the list-and-record screen that can be
 * silently wrong.
 *
 * The doors take a single `p_search` and match it against code OR name, so
 * only one of the two boxes can be sent to the database. The rest narrows in
 * the browser. That split is only safe because the server's OR is always a
 * superset of what the client then narrows to — if it were not, the screen
 * would report "no matches" for a record that exists, which on a master-data
 * screen is somebody concluding a product has not been set up and setting it
 * up again.
 *
 * These cases are that argument, checked rather than asserted in a comment.
 */

type Row = { code: string; name: string };

const COLUMNS: BrowserColumn<Row>[] = [
  { key: "code", header: "Code", value: (r) => r.code, filter: true },
  { key: "name", header: "Name", value: (r) => r.name, filter: true },
];

/** What the door would return for a term: it matches code OR name. */
function asServerWould(rows: Row[], term: string): Row[] {
  if (term === "") return rows;
  const t = term.toLowerCase();
  return rows.filter((r) => r.code.toLowerCase().includes(t) || r.name.toLowerCase().includes(t));
}

const ROWS: Row[] = [
  { code: "FG-100", name: "Psyllium Husk Powder 100g" },
  { code: "FG-250", name: "Psyllium Husk Powder 250g" },
  { code: "RM-100", name: "Psyllium Husk, bulk" },
  { code: "PK-010", name: "Carton, 100 count" },
];

/** The whole pipeline: what the server returns, then what the client keeps. */
function screenShows(filters: Record<string, string>): Row[] {
  return narrow(asServerWould(ROWS, serverSearchTerm(COLUMNS, filters)), COLUMNS, filters);
}

describe("which box goes to the database", () => {
  test("none, when nothing is typed", () => {
    expect(serverSearchTerm(COLUMNS, {})).toBe("");
    expect(serverSearchTerm(COLUMNS, { code: "  ", name: "" })).toBe("");
  });

  test("the filled one", () => {
    expect(serverSearchTerm(COLUMNS, { name: "psyllium" })).toBe("psyllium");
  });

  test("the first filled one when both are, and it is trimmed", () => {
    expect(serverSearchTerm(COLUMNS, { code: " FG ", name: "husk" })).toBe("FG");
  });

  test("a column with no filter box is never sent, however it is filled", () => {
    const noBox: BrowserColumn<Row>[] = [
      { key: "code", header: "Code", value: (r) => r.code },
      { key: "name", header: "Name", value: (r) => r.name, filter: true },
    ];
    expect(serverSearchTerm(noBox, { code: "FG", name: "husk" })).toBe("husk");
  });
});

describe("what the screen ends up showing, server and client together", () => {
  test("a code filter keeps code matches, not the name matches the server also returned", () => {
    // "100" matches RM-100's code and PK-010's name, so the server hands back
    // three rows. Only two of them have it in the code.
    expect(asServerWould(ROWS, "100")).toHaveLength(3);
    expect(screenShows({ code: "100" }).map((r) => r.code)).toEqual(["FG-100", "RM-100"]);
  });

  test("a name filter keeps name matches, not the code matches", () => {
    // RM-100 has "100" in its code and not its name, so it comes back from the
    // door and is dropped here. FG-100 stays because "100g" is in its name.
    expect(screenShows({ name: "100" }).map((r) => r.code)).toEqual(["FG-100", "PK-010"]);
  });

  test("both boxes are an AND, and the server's narrower result still contains it", () => {
    expect(screenShows({ code: "FG", name: "250g" }).map((r) => r.code)).toEqual(["FG-250"]);
  });

  test("filtering is case-insensitive on both sides", () => {
    expect(screenShows({ name: "PSYLLIUM" })).toHaveLength(3);
  });

  test("nothing typed shows everything", () => {
    expect(screenShows({})).toHaveLength(4);
  });

  test("a term nothing matches shows nothing rather than everything", () => {
    // The failure worth guarding: an empty server result that the client then
    // treats as "no filter" and refills from the unfiltered list.
    expect(screenShows({ code: "ZZ" })).toEqual([]);
  });
});

describe("the client never keeps a row the server would have dropped", () => {
  // The property the whole split rests on. Checked over every pair of filters
  // the two columns can produce from the data, rather than the four cases
  // above — this is the one that would catch a future third filter box.
  const terms = ["", "FG", "100", "husk", "250g", "carton", "zz", "P"];

  test("every combination of filters is a subset of what the door returned", () => {
    for (const code of terms) {
      for (const name of terms) {
        const filters = { code, name };
        const fromServer = asServerWould(ROWS, serverSearchTerm(COLUMNS, filters));
        const shown = narrow(fromServer, COLUMNS, filters);

        // And it is exactly the rows that satisfy both boxes over the whole
        // table — never fewer, which is the silent failure.
        const ideal = narrow(ROWS, COLUMNS, filters);
        expect(shown).toEqual(ideal);
      }
    }
  });
});
