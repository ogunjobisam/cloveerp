/**
 * What the assurance run actually says, separated from how it is drawn.
 *
 * `erp_platform_assurance()` returns a row for every structural check in
 * `erp_meta.diagnostic_check` — a hundred and some of them, the whole-database
 * reconciliation among them — and the screen drew all of them as a table of
 * check names with a pill each. A person watching a demonstration does not
 * need to read a hundred check names. They need to know whether everything
 * reconciles, and, if it does not, which one did not and what to do about it.
 *
 * So the rows are read into three groups before anything is drawn, and the
 * screen says the verdict first. The groups are the door's own three answers:
 * `ok` true, false, and null — null being a tenant-scoped check run by a
 * session that is not inside an organisation, which is neither a pass nor a
 * failure and must never be counted as either.
 */

/** One row of `erp_platform_assurance()`, as much of it as the screen reads. */
export type AssuranceCheck = {
  /** `schema.function`, which is the row's identity and its fallback name. */
  check: string;
  /** The registered code, which is what a person quotes when reporting one. */
  code?: string;
  title?: string;
  blurb?: string;
  /** True held, false violated, null not run for want of an organisation. */
  ok: boolean | null;
  summary?: string | null;
  detail: string | null;
};

export type AssuranceReading = {
  /**
   * The one thing the screen says.
   *
   * `holds` only when every check that ran held and none was skipped;
   * `partial` when everything that ran held but some could not run, because
   * "everything reconciles" would be a claim about checks nobody made; and
   * `violated` the moment one check fails, whatever the rest did.
   */
  state: "holds" | "partial" | "violated";
  /** The failing checks, in the order the register runs them. */
  failed: AssuranceCheck[];
  held: number;
  /** Checks that need an organisation and were run without one. */
  skipped: number;
  total: number;
};

export function readAssurance(rows: readonly AssuranceCheck[]): AssuranceReading {
  const failed = rows.filter((r) => r.ok === false);
  const skipped = rows.filter((r) => r.ok === null).length;
  const held = rows.filter((r) => r.ok === true).length;
  return {
    state: failed.length > 0 ? "violated" : skipped > 0 ? "partial" : "holds",
    failed,
    held,
    skipped,
    total: rows.length,
  };
}

/**
 * What a failing check is called, when it is called anything.
 *
 * The register carries a title for every check it holds; `check` is the
 * schema-qualified function, which is what a check registered without one has
 * and is still enough to identify it.
 */
export function checkName(check: AssuranceCheck): string {
  return check.title ?? check.check;
}

/**
 * What the check found, in its own words.
 *
 * `summary` is the assertion's own return value and `detail` the refusal it
 * raised; a failing check has the second and rarely the first. An em dash
 * rather than an empty cell, because a failure with nothing said about it is
 * still a failure and the row must not read as blank.
 */
export function checkFinding(check: AssuranceCheck): string {
  return check.summary ?? check.detail ?? "—";
}
