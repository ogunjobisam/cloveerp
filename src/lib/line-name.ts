/**
 * A line's product, named the same on every panel of a document (J-157,
 * 20261007051000): its code and its name, and what was typed over its
 * description beside them where that says something else.
 *
 * The Lines card showed the code alone, and Supplier confirmation and
 * Shipping notices showed only the description, so a line typed over no
 * longer said which product it was.
 */
export type LineName = {
  /** "CODE Name"; the description, for a line with no product. */
  product: string;
  /** What was typed over the product's description, or null. */
  typed: string | null;
};

const words = (v: string | null | undefined): string | null =>
  typeof v === "string" && v.trim() !== "" ? v.trim() : null;

export function lineName(
  code: string | null | undefined,
  name: string | null | undefined,
  description: string | null | undefined,
): LineName {
  const c = words(code);
  const n = words(name);
  const d = words(description);
  const product = [c, n].filter((x) => x !== null).join(" ");
  if (product === "") return { product: d ?? "", typed: null };
  return { product, typed: d !== null && d !== n && d !== product ? d : null };
}
