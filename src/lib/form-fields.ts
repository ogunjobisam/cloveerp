/**
 * Which of a form's fields this session is asked.
 *
 * Most forms ask everybody who may submit them the same questions. A few carry
 * a question only some of them may answer: invoicing a delivery you despatched
 * yourself is an exception that only somebody who may promote configuration
 * can make once the organisation is live, so the choice and its reason are not
 * put to anybody else. A field that names a permission is asked only of a
 * session holding it; the rest are asked of everybody. The database still
 * decides what is allowed.
 *
 * Pure, so the choice can be tested without a browser.
 */
export function fieldsFor<T extends { permission?: string }>(
  fields: readonly T[],
  holds: (code: string) => boolean,
): T[] {
  return fields.filter((f) => f.permission === undefined || holds(f.permission));
}
