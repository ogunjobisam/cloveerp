/**
 * Names people recognise, in place of the database's own.
 *
 * A routine is called `erp_complete_warehouse_task` and a column
 * `quantity_done`; neither is how anyone would say it. These turn the stored
 * name into a readable phrase, so screens never show a raw one.
 *
 * This file deliberately imports nothing from the module definitions: those
 * import the table and form components, which in turn use these helpers.
 */

/** Turn `erp_complete_warehouse_task` into `Complete warehouse task`. */
export function prettifyRoutine(name: string): string {
  const words = name
    .replace(/^(public\.)?erp_?/, "")
    .replace(/_/g, " ")
    .trim();
  if (words === "") return name;
  return words.charAt(0).toUpperCase() + words.slice(1);
}

/** Turn a column or state such as `quantity_done` into `Quantity done`. */
export function prettifyField(name: string): string {
  const words = name.replace(/_/g, " ").trim();
  if (words === "") return name;
  return words.charAt(0).toUpperCase() + words.slice(1);
}
