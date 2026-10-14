import { parseGs1, type ApplicationIdentifier } from "./gs1";

/**
 * A barcode read by a phone's camera, as the scanner screen reads a hardware
 * scanner's (theme 4, "phones and scanners").
 *
 * A camera decoder says what it read in its own words: a format (code_128,
 * data_matrix, ean_13 …) and the raw text. The scanner screen speaks the
 * product's symbologies (erp_symbologies: gs1_128, gs1_datamatrix, ean_13,
 * upc_a, code_128, code_39), and GS1-128 and plain Code 128 are the same
 * format to a camera. What tells them apart is the content: data that parses
 * as GS1 application identifiers is GS1. A decoder that reports the
 * symbology identifier (]C1, ]d2, ]Q3, ]E0 …) is believed, and the prefix is
 * not part of the barcode.
 */

/** The formats a camera is asked to look for. */
export const CAMERA_FORMATS = [
  "code_128",
  "data_matrix",
  "ean_13",
  "upc_a",
  "code_39",
  "qr_code",
] as const;

export type CameraRead = { format: string; rawValue: string };

export type CameraScan =
  { raw: string; symbology: string } | { raw: string; symbology: null; why: string };

const IDENTIFIER = /^\][A-Za-z][0-9A-Za-z]/;

function isGs1(raw: string, register: ApplicationIdentifier[]): boolean {
  if (register.length === 0) return false;
  try {
    return Object.keys(parseGs1(raw, register)).length > 0;
  } catch {
    return false;
  }
}

/**
 * The symbology a camera's read is, among those the product reads, and the
 * barcode with any symbology identifier taken off.
 */
export function cameraScan(
  read: CameraRead,
  register: ApplicationIdentifier[],
  known: readonly string[],
): CameraScan {
  let raw = read.rawValue;
  let said: string | null = null;
  if (IDENTIFIER.test(raw)) {
    said = raw.slice(0, 3);
    raw = raw.slice(3);
  }

  let symbology: string | null;
  switch (read.format) {
    case "code_128":
      symbology = said === "]C1" || isGs1(raw, register) ? "gs1_128" : "code_128";
      break;
    case "data_matrix":
      // The product reads DataMatrix as GS1 only: its one two-dimensional
      // symbology is GS1 DataMatrix.
      symbology = "gs1_datamatrix";
      break;
    case "ean_13":
    case "upc_a":
    case "code_39":
      symbology = read.format;
      break;
    default:
      symbology = null;
  }

  if (symbology === null || !known.includes(symbology)) {
    return {
      raw,
      symbology: null,
      why: `a ${read.format.replace(/_/g, " ")} barcode, which this product does not read`,
    };
  }
  return { raw, symbology };
}
