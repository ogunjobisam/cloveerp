import { describe, expect, test } from "bun:test";

import {
  detectLayout,
  doorLines,
  isOfx,
  mapIsComplete,
  ofxDate,
  readCsvStatement,
  readOfxStatement,
  type ColumnMap,
} from "./bank-statement";
import { parseCsv } from "./import/csv";

/**
 * Bank statement files as the owner's chosen banks export them (bank
 * reconciliation, pull request 2). Each sample is small and made up, in the
 * bank's own layout: the point is the columns, the sign of money out, the
 * order the bank lists lines in, and the balances.
 */

function read(text: string) {
  const records = parseCsv(text).records;
  const found = detectLayout(records[0]?.fields ?? []);
  if (!found) throw new Error("no layout matched");
  return { layout: found.layout.id, statement: readCsvStatement(text, found.map, found.layout) };
}

describe("a bank's CSV is recognised by its headings", () => {
  test("Barclays: one signed amount, the memo as description", () => {
    const { layout, statement } = read(
      [
        "Number,Date,Account,Amount,Subcategory,Memo",
        ",01/10/2026,20-00-00 12345678,-12.50,DIRECTDEBIT,HSBC CHARGES",
        ",02/10/2026,20-00-00 12345678,1500.00,CREDIT,ACME LTD INV-000412",
      ].join("\n"),
    );
    expect(layout).toBe("barclays");
    expect(statement.lines.map((l) => l.amountMinor)).toEqual([-1250, 150000]);
    expect(statement.lines[1]?.description).toBe("ACME LTD INV-000412");
    expect(statement.startsOn).toBe("2026-10-01");
    expect(statement.openingMinor).toBeNull();
  });

  test("Lloyds: debit and credit columns, newest first, with a running balance", () => {
    const { layout, statement } = read(
      [
        "Transaction Date,Transaction Type,Sort Code,Account Number,Transaction Description,Debit Amount,Credit Amount,Balance",
        "03/10/2026,DEB,'30-00-00,12345678,CARD PAYMENT STAPLES,45.00,,1455.00",
        "02/10/2026,FPI,'30-00-00,12345678,ACME LTD,,500.00,1500.00",
      ].join("\n"),
    );
    expect(layout).toBe("lloyds");
    // Oldest first, whatever order the bank printed.
    expect(statement.lines.map((l) => l.bookedOn)).toEqual(["2026-10-02", "2026-10-03"]);
    expect(statement.lines.map((l) => l.amountMinor)).toEqual([50000, -4500]);
    expect(statement.openingMinor).toBe(100000);
    expect(statement.closingMinor).toBe(145500);
    expect(statement.findings).toEqual([]);
  });

  test("NatWest: a signed value and a balance", () => {
    const { layout, statement } = read(
      [
        "Date, Type, Description, Value, Balance, Account Name, Account Number",
        "01/10/2026,BAC,ACME LTD,250.00,1250.00,BUSINESS,'1234",
        "02/10/2026,D/D,BT GROUP,-60.00,1190.00,BUSINESS,'1234",
      ].join("\n"),
    );
    expect(layout).toBe("natwest");
    expect(statement.openingMinor).toBe(100000);
    expect(statement.closingMinor).toBe(119000);
  });

  test("HSBC, Starling, Monzo and Tide each read their own columns", () => {
    expect(
      read("Date,Description,Amount\n01/10/2026,RENT,-900.00").statement.lines[0]?.amountMinor,
    ).toBe(-90000);
    const starling = read(
      "Date,Counter Party,Reference,Type,Amount (GBP),Balance (GBP),Spending Category,Notes\n01/10/2026,Acme Ltd,INV-000412,FASTER PAYMENT,120.00,620.00,INCOME,",
    );
    expect(starling.layout).toBe("starling");
    expect(starling.statement.lines[0]?.reference).toBe("INV-000412");
    expect(starling.statement.openingMinor).toBe(50000);
    const monzo = read(
      "Transaction ID,Date,Time,Type,Name,Emoji,Category,Amount,Currency,Local amount,Local currency,Notes and #tags,Address,Receipt,Description\ntx_1,01/10/2026,09:00,Faster payment,Acme Ltd,,Income,75.25,GBP,75.25,GBP,INV-9,,,ACME",
    );
    expect(monzo.layout).toBe("monzo");
    expect(monzo.statement.lines[0]?.amountMinor).toBe(7525);
    const tide = read(
      "Date,Transaction ID,Transaction description,Reference,Paid in,Paid out,Transaction type\n01/10/2026,1,Office rent,OCT,,900.00,Payment",
    );
    expect(tide.layout).toBe("tide");
    expect(tide.statement.lines[0]?.amountMinor).toBe(-90000);
  });

  test("a file no layout knows needs a mapping, and a mapping needs money", () => {
    expect(detectLayout(["When", "What", "How much"])).toBeNull();
    const map: ColumnMap = {
      date: 0,
      description: 1,
      amount: null,
      paidIn: null,
      paidOut: null,
      balance: null,
      reference: null,
    };
    expect(mapIsComplete(map)).toBe(false);
    expect(mapIsComplete({ ...map, amount: 2 })).toBe(true);
    const s = readCsvStatement(
      "When,What,How much\n05/10/2026,Interest,1.23",
      { ...map, amount: 2 },
      { id: "mapped", label: "Mapped" },
    );
    expect(s.lines[0]).toMatchObject({
      bookedOn: "2026-10-05",
      amountMinor: 123,
      description: "Interest",
    });
  });

  test("a line that is not a date is a finding, and blank lines are passed over", () => {
    const { statement } = read("Date,Description,Amount\nnot a date,X,1.00\n\n01/10/2026,Y,2.00");
    expect(statement.lines).toHaveLength(1);
    expect(statement.findings[0]?.message).toContain("not a date");
  });

  test("lines that do not add up from opening to closing are said", () => {
    const { statement } = read(
      "Date, Type, Description, Value, Balance, Account Name, Account Number\n01/10/2026,BAC,A,100.00,1100.00,B,1\n02/10/2026,BAC,B,100.00,1250.00,B,1",
    );
    expect(statement.findings.some((f) => f.message.includes("do not add up"))).toBe(true);
  });
});

describe("OFX", () => {
  const OFX = `OFXHEADER:100
DATA:OFXSGML
<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><CURDEF>GBP
<BANKACCTFROM><BANKID>400000<ACCTID>12345678<ACCTTYPE>CHECKING</BANKACCTFROM>
<BANKTRANLIST><DTSTART>20261001<DTEND>20261007
<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20261003120000<TRNAMT>-45.00<FITID>F2<NAME>STAPLES<MEMO>CARD</STMTTRN>
<STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20261002<TRNAMT>500.00<FITID>F1<NAME>ACME LTD &amp; CO</STMTTRN>
</BANKTRANLIST><LEDGERBAL><BALAMT>1455.00<DTASOF>20261007</LEDGERBAL></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>`;

  test("is recognised, read oldest first, with its ids, account and balances", () => {
    expect(isOfx(OFX)).toBe(true);
    expect(isOfx("Date,Description,Amount")).toBe(false);
    const s = readOfxStatement(OFX);
    expect(s.lines.map((l) => [l.bookedOn, l.amountMinor, l.fitid])).toEqual([
      ["2026-10-02", 50000, "F1"],
      ["2026-10-03", -4500, "F2"],
    ]);
    expect(s.lines[0]?.description).toBe("ACME LTD & CO");
    expect(s.closingMinor).toBe(145500);
    expect(s.openingMinor).toBe(100000);
    expect(s.startsOn).toBe("2026-10-01");
    expect(s.endsOn).toBe("2026-10-07");
    expect(s.accountLast4).toBe("5678");
    expect(ofxDate("20261013120000[0:GMT]")).toBe("2026-10-13");
  });

  test("goes to the door as snake-case lines", () => {
    expect(doorLines(readOfxStatement(OFX).lines)[0]).toEqual({
      booked_on: "2026-10-02",
      amount_minor: 50000,
      description: "ACME LTD & CO",
      reference: null,
      fitid: "F1",
      balance_minor: null,
    });
  });
});
