/**
 * A CSV file, read as RFC 4180 says and as Xero and Unleashed actually write it.
 *
 * Hand-rolled rather than a dependency: the whole of the format is quoting, and
 * the cases that matter are the ones a legacy export produces — a byte-order
 * mark from Excel's "CSV UTF-8", CRLF line ends, an address with a line break
 * inside quotes, a doubled quote in a product description, a trailing blank
 * line. A row with a different number of fields from the heading is reported,
 * not thrown: the person fixes the file, or the profile ignores the column.
 *
 * Every record keeps the line it started on, so a finding can say where to look.
 */

export type CsvRecord = { line: number; fields: string[] };

export type CsvParse = {
  records: CsvRecord[];
  /** A quote opened and never closed: the rest of the file was one field. */
  unterminatedAt: number | null;
};

export function parseCsv(text: string): CsvParse {
  const src = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  const records: CsvRecord[] = [];
  let fields: string[] = [];
  let field = "";
  let quoted = false;
  let line = 1;
  let recordLine = 1;
  let quoteOpenedAt = 0;
  let touched = false;

  const endField = () => {
    fields.push(field);
    field = "";
  };
  const endRecord = () => {
    endField();
    // A blank line is not a record of one empty field.
    if (!(fields.length === 1 && fields[0] === "" && !touched)) {
      records.push({ line: recordLine, fields });
    }
    fields = [];
    touched = false;
  };

  for (let i = 0; i < src.length; i++) {
    const ch = src[i];
    if (quoted) {
      if (ch === '"') {
        if (src[i + 1] === '"') {
          field += '"';
          i++;
        } else {
          quoted = false;
        }
      } else {
        if (ch === "\n") line++;
        field += ch;
      }
      continue;
    }
    if (ch === '"') {
      quoted = true;
      touched = true;
      quoteOpenedAt = line;
    } else if (ch === ",") {
      touched = true;
      endField();
    } else if (ch === "\r") {
      if (src[i + 1] === "\n") i++;
      endRecord();
      line++;
      recordLine = line;
    } else if (ch === "\n") {
      endRecord();
      line++;
      recordLine = line;
    } else {
      if (ch !== undefined) field += ch;
      touched = true;
    }
  }
  if (quoted) {
    endRecord();
    return { records, unterminatedAt: quoteOpenedAt };
  }
  if (field !== "" || fields.length > 0 || touched) endRecord();
  return { records, unterminatedAt: null };
}
