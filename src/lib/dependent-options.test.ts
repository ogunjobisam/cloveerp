import { describe, expect, test } from "bun:test";

import { clearDependentCells, dependentFields, optionArgs, optionList } from "./dependent-options";

const buckets = {
  args: { p_limit: 500 },
  argsFrom: { p_version_id: "p_version_id" },
};

const candidates = {
  argsFrom: { p_statement_id: "p_statement_id" },
  path: "lines",
  within: { field: "p_line_id", key: "line_id", path: "candidates" },
};

const statement = {
  statement_id: "s1",
  lines: [
    { line_id: "l1", candidates: [{ subledger_item_id: "i1" }, { subledger_item_id: "i2" }] },
    { line_id: "l2", candidates: [] },
    { line_id: "l3" },
  ],
};

describe("what a dependent picker asks with", () => {
  test("its own arguments and the choice it follows", () => {
    expect(optionArgs(buckets, { p_version_id: "v1" })).toEqual({
      p_limit: 500,
      p_version_id: "v1",
    });
  });

  test("nothing, while that choice is not made", () => {
    expect(optionArgs(buckets, {})).toBeNull();
    expect(optionArgs(buckets, { p_version_id: "" })).toBeNull();
    expect(optionArgs(candidates, { p_statement_id: "s1" })).toBeNull();
  });

  test("a picker that follows nothing asks as it always did", () => {
    expect(optionArgs({ args: { p_type_code: "delivery" } }, {})).toEqual({
      p_type_code: "delivery",
    });
    expect(optionArgs({}, {})).toEqual({});
  });
});

describe("what it offers", () => {
  test("the list at the path, or the answer itself", () => {
    expect(optionList({ path: "lines" }, statement, {})).toHaveLength(3);
    expect(optionList({}, [1, 2], {})).toEqual([1, 2]);
    expect(optionList({ path: "views" }, [1, 2], {})).toEqual([1, 2]);
  });

  test("the list inside the record chosen above", () => {
    expect(optionList(candidates, statement, { p_line_id: "l1" })).toEqual([
      { subledger_item_id: "i1" },
      { subledger_item_id: "i2" },
    ]);
  });

  test("nothing when that record has none, is not there, or is not chosen", () => {
    expect(optionList(candidates, statement, { p_line_id: "l2" })).toEqual([]);
    expect(optionList(candidates, statement, { p_line_id: "l3" })).toEqual([]);
    expect(optionList(candidates, statement, { p_line_id: "gone" })).toEqual([]);
    expect(optionList(candidates, statement, {})).toEqual([]);
    expect(optionList(candidates, null, { p_line_id: "l1" })).toEqual([]);
  });
});

describe("what changing a choice clears", () => {
  const fields = [
    { name: "p_statement_id", options: {} },
    {
      name: "p_line_id",
      options: { argsFrom: { p_statement_id: "p_statement_id" }, path: "lines" },
    },
    { name: "p_subledger_item_id", options: candidates },
    { name: "p_note" },
  ];

  test("every picker that reads it", () => {
    expect(dependentFields(fields, "p_statement_id")).toEqual(["p_line_id", "p_subledger_item_id"]);
    expect(dependentFields(fields, "p_line_id")).toEqual(["p_subledger_item_id"]);
  });

  test("nothing else", () => {
    expect(dependentFields(fields, "p_subledger_item_id")).toEqual([]);
    expect(dependentFields(fields, "p_note")).toEqual([]);
  });
});

describe("a line editor whose picker follows a choice", () => {
  const fields = [
    { name: "p_blanket_id" },
    {
      name: "p_lines",
      columns: [
        { name: "line_id", options: { argsFrom: { p_document_id: "p_blanket_id" } } },
        { name: "quantity" },
      ],
    },
  ];

  test("loses the lines of the old choice and keeps what was typed", () => {
    const rows = {
      p_lines: [
        { line_id: "a", quantity: "10" },
        { line_id: "b", quantity: "" },
      ],
    };
    expect(clearDependentCells(fields, rows, "p_blanket_id")).toEqual({
      p_lines: [
        { line_id: "", quantity: "10" },
        { line_id: "", quantity: "" },
      ],
    });
  });

  test("is left alone by a change to anything else", () => {
    const rows = { p_lines: [{ line_id: "a", quantity: "10" }] };
    expect(clearDependentCells(fields, rows, "p_note")).toBe(rows);
  });
});
