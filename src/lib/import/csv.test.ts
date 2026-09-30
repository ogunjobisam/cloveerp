import { describe, expect, test } from "bun:test";

import { parseCsv } from "./csv";

describe("a CSV file as legacy systems write it", () => {
  test("plain rows", () => {
    expect(parseCsv("a,b\n1,2\n").records).toEqual([
      { line: 1, fields: ["a", "b"] },
      { line: 2, fields: ["1", "2"] },
    ]);
  });

  test("Excel's byte-order mark is not part of the first heading", () => {
    expect(parseCsv("﻿Code,Name\r\n").records[0]?.fields).toEqual(["Code", "Name"]);
  });

  test("CRLF and LF read the same", () => {
    expect(parseCsv("a,b\r\n1,2\r\n").records).toEqual(parseCsv("a,b\n1,2\n").records);
  });

  test("a quoted comma is a comma, a doubled quote is a quote", () => {
    expect(parseCsv('"Unit 4, Mill Lane","Say ""hi"""\n').records[0]?.fields).toEqual([
      "Unit 4, Mill Lane",
      'Say "hi"',
    ]);
  });

  test("a line break inside quotes stays in the field, and line numbers still count it", () => {
    const { records } = parseCsv('a,b\n"one\r\ntwo",x\nlast,y\n');
    expect(records[1]).toEqual({ line: 2, fields: ["one\r\ntwo", "x"] });
    expect(records[2]).toEqual({ line: 4, fields: ["last", "y"] });
  });

  test("blank lines are not records, but a line of empty fields is", () => {
    const { records } = parseCsv("a,b\n\n,\n\n");
    expect(records).toEqual([
      { line: 1, fields: ["a", "b"] },
      { line: 3, fields: ["", ""] },
    ]);
  });

  test("no trailing newline", () => {
    expect(parseCsv("a,b\n1,2").records[1]?.fields).toEqual(["1", "2"]);
  });

  test("an empty quoted field is a field", () => {
    expect(parseCsv('""\n').records).toEqual([{ line: 1, fields: [""] }]);
  });

  test("an unclosed quote is reported where it opened", () => {
    expect(parseCsv('a,b\n1,"never closed\n2,3\n').unterminatedAt).toBe(2);
  });
});
