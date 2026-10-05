import type { LineName } from "../../lib/line-name";

/**
 * A line's product as every panel of a document names it (J-157): its code
 * and name, and what was typed over its description beside them, quieter.
 */
export function LineProduct({ name }: { name: LineName }) {
  return (
    <span className="min-w-0">
      {name.product === "" ? "—" : name.product}
      {name.typed !== null ? (
        <span className="ml-2 text-xs text-muted-foreground">{name.typed}</span>
      ) : null}
    </span>
  );
}
