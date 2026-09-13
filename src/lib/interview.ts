/**
 * The onboarding interview, as the desk reads and writes it.
 *
 * Pure on purpose: no React, no fetch. The screen holds a draft per question
 * in the control's own shape (a picked option, a line of text, a list of
 * names, rows of two columns); this file is the one place that turns a draft
 * into the JSON erp_answer_interview stores and back, reads what the doors
 * return without trusting its shape, and writes the plain sentence a person
 * reads for each proposed change. The rules a person trips over — "1,000" is
 * a thousand, a half-filled row is a mistake rather than a silent drop, a
 * month may be typed as April — are tested here without a browser.
 *
 * Wording lives in this file only as literal calls to `ui`, a translator the
 * screen passes in, so the build's string harvest sees every sentence and a
 * tenant can rename it like any other screen string.
 */

export type AnswerShape =
  "boolean" | "choice" | "text" | "integer" | "money" | "text_list" | "text_pairs";

const SHAPES: readonly AnswerShape[] = [
  "boolean",
  "choice",
  "text",
  "integer",
  "money",
  "text_list",
  "text_pairs",
];

/**
 * One row of a two-column answer: company and currency, grouping and value.
 * `code` is carried only where a picked suggestion has one to land with.
 */
export type Pair = { left: string; right: string; code?: string };

/**
 * One entry of a list answer. A name a person typed has no code; a suggestion
 * picked from a starter pack carries the code it lands with (FIN, FG).
 */
export type ListEntry = { code: string | null; name: string };

/** What a control holds while it is being edited. */
export type Draft =
  | { kind: "scalar"; raw: string }
  | { kind: "list"; entries: ListEntry[] }
  | { kind: "pairs"; rows: Pair[] };

export type Invalid =
  | { reason: "not_a_number" }
  | { reason: "not_whole" }
  | { reason: "too_many_decimals"; max: number }
  | { reason: "out_of_range"; min: number | null; max: number | null }
  | { reason: "not_a_choice" }
  | { reason: "incomplete_rows"; rows: number[] };

/** The result of building an answer: send it, send nothing, or say what is wrong. */
export type Built =
  | { kind: "answer"; value: string | number | boolean | unknown[] }
  | { kind: "empty" }
  | ({ kind: "invalid" } & Invalid);

export type Bounds = { min?: number; max?: number; decimals?: number; choices?: string[] };

/** The translator the screen hands in: useT().ui, or the identity in a test. */
export type Translate = (text: string) => string;

// ── Reading what the doors return ─────────────────────────────────────────

type Obj = Record<string, unknown>;

function isObj(v: unknown): v is Obj {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

function str(o: Obj, key: string): string | null {
  const v = o[key];
  if (typeof v === "string") return v;
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  return null;
}

function num(o: Obj, key: string, fallback = 0): number {
  const v = o[key];
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim() !== "" && Number.isFinite(Number(v))) return Number(v);
  return fallback;
}

function bool(o: Obj, key: string, fallback: boolean): boolean {
  const v = o[key];
  return typeof v === "boolean" ? v : fallback;
}

function objects(v: unknown): Obj[] {
  return Array.isArray(v) ? v.filter(isObj) : [];
}

/** One option erp_interview_questions offers for a question. */
export type Suggestion = {
  value: string;
  code: string | null;
  label: string;
  note: string | null;
  axis: string | null;
  likely: boolean;
  available: boolean;
  unavailable_reason: string | null;
  present: boolean;
};

/** A left-hand thing a two-column answer can name: a company, a site, a grouping. */
export type LeftSuggestion = {
  value: string;
  label: string;
  note: string | null;
  present: boolean;
};

export type Question = {
  code: string;
  section: string;
  seq: number;
  prompt: string;
  help: string | null;
  answer_shape: AnswerShape;
  choices: string[];
  maps_to: string | null;
  is_required: boolean;
  applies: boolean;
  applies_when: string | null;
  answer: unknown;
  suggestions: Suggestion[];
  left_suggestions: LeftSuggestion[];
  likely: unknown;
  example: string | null;
};

function readSuggestion(o: Obj): Suggestion | null {
  const value = str(o, "value");
  if (value === null) return null;
  return {
    value,
    code: str(o, "code"),
    label: str(o, "label") ?? value,
    note: str(o, "note"),
    axis: str(o, "axis"),
    likely: bool(o, "likely", false),
    available: bool(o, "available", true),
    unavailable_reason: str(o, "unavailable_reason"),
    present: bool(o, "present", false),
  };
}

/**
 * The questions door, read defensively: a key the door does not send is an
 * empty list or null here rather than a crash three components down.
 */
export function readQuestions(raw: unknown): Question[] {
  return objects(raw)
    .map((o): Question | null => {
      const code = str(o, "code");
      const section = str(o, "section");
      if (code === null || section === null) return null;
      const shape = str(o, "answer_shape");
      return {
        code,
        section,
        seq: num(o, "seq"),
        prompt: str(o, "prompt") ?? code,
        help: str(o, "help"),
        answer_shape: SHAPES.find((s) => s === shape) ?? "text",
        choices: Array.isArray(o["choices"])
          ? o["choices"].filter((c): c is string => typeof c === "string")
          : [],
        maps_to: str(o, "maps_to"),
        is_required: bool(o, "is_required", false),
        applies: bool(o, "applies", true),
        applies_when: str(o, "applies_when"),
        answer: o["answer"] ?? null,
        suggestions: objects(o["suggestions"])
          .map(readSuggestion)
          .filter((s): s is Suggestion => s !== null),
        left_suggestions: objects(o["left_suggestions"])
          .map((l): LeftSuggestion | null => {
            const value = str(l, "value");
            if (value === null) return null;
            return {
              value,
              label: str(l, "label") ?? value,
              note: str(l, "note"),
              present: bool(l, "present", false),
            };
          })
          .filter((l): l is LeftSuggestion => l !== null),
        likely: o["likely"] ?? null,
        example: str(o, "example"),
      };
    })
    .filter((q): q is Question => q !== null)
    .sort((a, b) => a.seq - b.seq);
}

export type SectionCount = {
  section: string;
  questions: number;
  applicable: number;
  answered: number;
};

export type SessionProposal = {
  section: string;
  proposal_id: string;
  change_set_id: string | null;
  change_set_code: string | null;
  change_set_status: string | null;
  item_count: number;
};

export type InterviewSession = {
  session_id: string;
  code: string;
  status: string;
  started_at: string | null;
  proposed_at: string | null;
  sections: SectionCount[];
  proposals: SessionProposal[];
};

export type Sessions = { live: boolean; sessions: InterviewSession[] };

function sectionRank(section: string): number {
  const i = (SECTION_ORDER as readonly string[]).indexOf(section);
  return i < 0 ? SECTION_ORDER.length : i;
}

/** erp_interview_sessions(): open first, then newest, as the door orders them. */
export function readSessions(raw: unknown): Sessions {
  const o = isObj(raw) ? raw : {};
  return {
    live: bool(o, "live", false),
    sessions: objects(o["sessions"])
      .map((s): InterviewSession | null => {
        const id = str(s, "session_id");
        if (id === null) return null;
        return {
          session_id: id,
          code: str(s, "code") ?? id,
          status: str(s, "status") ?? "open",
          started_at: str(s, "started_at"),
          proposed_at: str(s, "proposed_at"),
          sections: objects(s["sections"]).map((c) => ({
            section: str(c, "section") ?? "",
            questions: num(c, "questions"),
            applicable: num(c, "applicable"),
            answered: num(c, "answered"),
          })),
          proposals: objects(s["proposals"])
            .map((p): SessionProposal | null => {
              const pid = str(p, "proposal_id");
              if (pid === null) return null;
              return {
                section: str(p, "section") ?? "",
                proposal_id: pid,
                change_set_id: str(p, "change_set_id"),
                change_set_code: str(p, "change_set_code"),
                change_set_status: str(p, "change_set_status"),
                item_count: num(p, "item_count"),
              };
            })
            .filter((p): p is SessionProposal => p !== null)
            .sort((a, b) => sectionRank(a.section) - sectionRank(b.section)),
        };
      })
      .filter((s): s is InterviewSession => s !== null),
  };
}

export type ChangeItem = {
  item_id: string;
  seq: number;
  object_kind: string;
  object_key: string;
  operation: string;
  payload: Record<string, unknown>;
  note: string | null;
};

/** erp_change_set_items(): already in the order the changes are applied. */
export function readItems(raw: unknown): ChangeItem[] {
  return objects(raw).map((o, i) => ({
    item_id: str(o, "item_id") ?? `item-${i}`,
    seq: num(o, "seq"),
    object_kind: str(o, "object_kind") ?? "",
    object_key: str(o, "object_key") ?? "",
    operation: str(o, "operation") ?? "upsert",
    payload: isObj(o["payload"]) ? o["payload"] : {},
    note: str(o, "note"),
  }));
}

export type Refusal = { code: string; message: string; detail: string | null; hint: string | null };

export type AcceptStep = {
  step: string;
  change_set_id: string | null;
  change_set_code: string | null;
  status_before: string | null;
  status: string | null;
  outcome: string;
  waits_for: string | null;
  refusal: Refusal | null;
};

export type AcceptResult = {
  interview: string;
  live: boolean;
  stops_at: string;
  steps: AcceptStep[];
  landed: number;
  waiting: number;
  refused: number;
};

/** erp_accept_interview(): one step per section, and the books between them. */
export function readAccept(raw: unknown): AcceptResult {
  const o = isObj(raw) ? raw : {};
  return {
    interview: str(o, "interview") ?? "",
    live: bool(o, "live", false),
    stops_at: str(o, "stops_at") ?? "promoted",
    steps: objects(o["steps"]).map((s) => {
      const r = isObj(s["refusal"]) ? s["refusal"] : null;
      return {
        step: str(s, "step") ?? "",
        change_set_id: str(s, "change_set_id"),
        change_set_code: str(s, "change_set_code"),
        status_before: str(s, "status_before"),
        status: str(s, "status"),
        outcome: str(s, "outcome") ?? "",
        waits_for: str(s, "waits_for"),
        refusal:
          r === null
            ? null
            : {
                code: str(r, "code") ?? "",
                message: str(r, "message") ?? "",
                detail: str(r, "detail"),
                hint: str(r, "hint"),
              },
      };
    }),
    landed: num(o, "landed"),
    waiting: num(o, "waiting"),
    refused: num(o, "refused"),
  };
}

// ── Statuses and outcomes, in words a person reads ────────────────────────

export type StatusKind =
  "proposed" | "waiting" | "approved" | "applying" | "in_force" | "not_applied";

export function statusKind(status: string | null): StatusKind {
  switch (status) {
    case "ready":
      return "waiting";
    case "approved":
      return "approved";
    case "promoting":
      return "applying";
    case "promoted":
      return "in_force";
    case "failed":
    case "rolled_back":
    case "cancelled":
      return "not_applied";
    default:
      return "proposed";
  }
}

export function statusText(status: string | null, ui: Translate): string {
  switch (statusKind(status)) {
    case "waiting":
      return ui("Waiting for approval");
    case "approved":
      return ui("Approved, not yet in force");
    case "applying":
      return ui("Being put in force");
    case "in_force":
      return ui("In force");
    case "not_applied":
      return ui("Not applied");
    default:
      return ui("Proposed");
  }
}

/**
 * The proposals accepting would still move. After go-live a set waiting for
 * approval is somebody else's to move, so pressing again would change nothing.
 */
export function pendingProposals(proposals: SessionProposal[], live: boolean): SessionProposal[] {
  return proposals.filter((p) => {
    const kind = statusKind(p.change_set_status);
    if (kind === "in_force" || kind === "not_applied" || kind === "applying") return false;
    return !(live && kind === "waiting");
  });
}

export type OutcomeKind =
  | "in_force"
  | "books_set_up"
  | "waiting_second"
  | "waiting_approval"
  | "needs_attention"
  | "waiting_section"
  | "not_needed"
  | "not_acceptable";

export function outcomeKind(step: Pick<AcceptStep, "outcome" | "waits_for">): OutcomeKind {
  switch (step.outcome) {
    case "promoted":
    case "already_promoted":
      return "in_force";
    case "set_up":
    case "already_set_up":
      return "books_set_up";
    case "ready":
      return "waiting_second";
    case "awaiting_approval":
      return "waiting_approval";
    case "refused":
      return "needs_attention";
    case "not_acceptable":
      return "not_acceptable";
    case "skipped":
      return step.waits_for ? "waiting_section" : "not_needed";
    default:
      return step.waits_for ? "waiting_section" : "not_needed";
  }
}

// ── Numbers ────────────────────────────────────────────────────────────────

const PLAIN = /^-?\d+(?:\.\d+)?$/;
const COMMA_GROUPS = /^-?\d{1,3}(?:,\d{3})+(?:\.\d+)?$/;
const SPACE_GROUPS = /^-?\d{1,3}(?: \d{3})+(?:\.\d+)?$/;

/**
 * A number as a person types it: "1000", "1,000", "1 000", "£1,000.50".
 *
 * A comma is accepted only as a thousands separator in groups of three, so
 * "1.000,50" is refused rather than read as one point nought nought nought
 * five. Null when the text is not a number.
 */
export function parseNumber(raw: string): number | null {
  const text = raw
    .trim()
    .replace(/^[£$€¥]\s*/, "")
    .replace(/[\u00a0\u202f]/g, " ");
  if (text === "") return null;
  let digits: string;
  if (PLAIN.test(text)) digits = text;
  else if (COMMA_GROUPS.test(text)) digits = text.replace(/,/g, "");
  else if (SPACE_GROUPS.test(text)) digits = text.replace(/ /g, "");
  else return null;
  const n = Number(digits);
  return Number.isFinite(n) ? n : null;
}

const MONTHS = [
  "january",
  "february",
  "march",
  "april",
  "may",
  "june",
  "july",
  "august",
  "september",
  "october",
  "november",
  "december",
];

/**
 * A month, 1 to 12, from "4", "04", "April" or "apr". English names only: the
 * control offers the months by name, and this exists for the typed fallback.
 */
export function parseMonth(raw: string): number | null {
  const text = raw.trim().toLowerCase().replace(/\.$/, "");
  if (text === "") return null;
  const n = parseNumber(text);
  if (n !== null) return Number.isInteger(n) && n >= 1 && n <= 12 ? n : null;
  if (text.length < 3) return null;
  const index = MONTHS.findIndex((m) => m.startsWith(text));
  return index < 0 ? null : index + 1;
}

/** A month's name in the reader's locale, from 1 to 12. */
export function monthName(month: number, locale: string): string {
  if (!Number.isInteger(month) || month < 1 || month > 12) return String(month);
  try {
    return new Intl.DateTimeFormat(locale, { month: "long", timeZone: "UTC" }).format(
      new Date(Date.UTC(2000, month - 1, 1)),
    );
  } catch {
    return String(month);
  }
}

/** The twelve months as choices, named in the reader's locale by the browser. */
export function monthChoices(locale: string): { value: string; label: string }[] {
  return MONTHS.map((_, i) => ({ value: String(i + 1), label: monthName(i + 1, locale) }));
}

// ── Lists and pairs ────────────────────────────────────────────────────────

/** A list answer as stored, whichever form each element took. */
export function listEntries(answer: unknown): ListEntry[] {
  if (!Array.isArray(answer)) return [];
  const out: ListEntry[] = [];
  for (const e of answer) {
    if (typeof e === "string") {
      if (e.trim() !== "") out.push({ code: null, name: e.trim() });
    } else if (isObj(e)) {
      const name = typeof e["name"] === "string" ? e["name"].trim() : "";
      const code =
        typeof e["code"] === "string" && e["code"].trim() !== "" ? e["code"].trim() : null;
      if (name !== "" || code !== null) out.push({ code, name: name || (code ?? "") });
    }
  }
  return out;
}

/** The same entry twice is one entry: by code where there is one, else by name. */
export function dedupeEntries(entries: ListEntry[]): ListEntry[] {
  const seen = new Set<string>();
  const out: ListEntry[] = [];
  for (const e of entries) {
    const key = (e.code ?? e.name).trim().toLowerCase();
    if (key === "" || seen.has(key)) continue;
    seen.add(key);
    out.push(e);
  }
  return out;
}

/**
 * A typed name, matched to a suggestion when it is one: "finance" typed by
 * hand lands as the starter pack's FIN rather than as a second department.
 */
export function entryFor(typed: string, suggestions: Suggestion[]): ListEntry | null {
  const name = typed.trim();
  if (name === "") return null;
  const lower = name.toLowerCase();
  const match = suggestions.find(
    (s) =>
      s.available &&
      (s.label.toLowerCase() === lower ||
        (s.code ?? s.value).toLowerCase() === lower ||
        s.value.toLowerCase() === lower),
  );
  return match ? { code: match.code ?? match.value, name: match.label } : { code: null, name };
}

/** Whether a list already holds an entry, by code where either has one, else by name. */
export function listHas(entries: ListEntry[], entry: ListEntry): boolean {
  const key = (entry.code ?? entry.name).toLowerCase();
  return entries.some(
    (e) =>
      (e.code ?? e.name).toLowerCase() === key ||
      (entry.code !== null && e.code === null && e.name.toLowerCase() === entry.name.toLowerCase()),
  );
}

/**
 * A pairs answer as stored. {left,right} is what the desk writes, with a code
 * where a picked value carries one; ["a","b"], {class,level} and {key,value}
 * are read too, because earlier answers were stored that way.
 */
export function pairsOf(answer: unknown): Pair[] {
  if (!Array.isArray(answer)) return [];
  const out: Pair[] = [];
  for (const e of answer) {
    let left: unknown;
    let right: unknown;
    let code: unknown;
    if (Array.isArray(e)) {
      left = e[0];
      right = e[1];
    } else if (isObj(e)) {
      left = e["left"] ?? e["class"] ?? e["key"];
      right = e["right"] ?? e["level"] ?? e["value"];
      code = e["code"];
    }
    if (typeof left === "string" && typeof right === "string") {
      const pair: Pair = { left: left.trim(), right: right.trim() };
      if (typeof code === "string" && code.trim() !== "") pair.code = code.trim();
      out.push(pair);
    }
  }
  return out;
}

/**
 * Lines pasted into a two-column editor. "/", a tab, "=" or the first comma
 * separates the columns; a line with no separator is returned in `unread`
 * rather than dropped.
 */
export function pairsFromText(text: string): { rows: Pair[]; unread: string[] } {
  const rows: Pair[] = [];
  const unread: string[] = [];
  for (const line of text.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed === "") continue;
    const m = /^(.+?)\s*(?:\t|\/|=|,)\s*(.+)$/.exec(trimmed);
    if (m && m[1] && m[2]) rows.push({ left: m[1].trim(), right: m[2].trim() });
    else unread.push(trimmed);
  }
  return { rows, unread };
}

/** One entry per line, for a list pasted rather than typed one at a time. */
export function entriesFromText(text: string): ListEntry[] {
  return text
    .split(/\r?\n/)
    .map((s) => s.trim())
    .filter((s) => s !== "")
    .map((name) => ({ code: null, name }));
}

// ── Draft ⇄ answer ─────────────────────────────────────────────────────────

export function emptyDraft(shape: AnswerShape): Draft {
  if (shape === "text_list") return { kind: "list", entries: [] };
  if (shape === "text_pairs") return { kind: "pairs", rows: [] };
  return { kind: "scalar", raw: "" };
}

/** An answer already given, as the control shows it. Nothing given is empty, not "No". */
export function fromAnswer(shape: AnswerShape, answer: unknown): Draft {
  if (answer === null || answer === undefined) return emptyDraft(shape);
  switch (shape) {
    case "text_list":
      return { kind: "list", entries: listEntries(answer) };
    case "text_pairs":
      return { kind: "pairs", rows: pairsOf(answer) };
    case "boolean":
      return {
        kind: "scalar",
        raw:
          answer === true || answer === "true"
            ? "true"
            : answer === false || answer === "false"
              ? "false"
              : "",
      };
    default:
      return {
        kind: "scalar",
        raw: typeof answer === "string" || typeof answer === "number" ? String(answer) : "",
      };
  }
}

function inRange(n: number, bounds: Bounds): boolean {
  return !(
    (bounds.min !== undefined && n < bounds.min) ||
    (bounds.max !== undefined && n > bounds.max)
  );
}

function range(bounds: Bounds): Invalid {
  return { reason: "out_of_range", min: bounds.min ?? null, max: bounds.max ?? null };
}

/** What erp_answer_interview is sent for a draft, or why nothing should be. */
export function toAnswer(shape: AnswerShape, draft: Draft, bounds: Bounds = {}): Built {
  if (shape === "text_list") {
    const entries = dedupeEntries(draft.kind === "list" ? draft.entries : []);
    if (entries.length === 0) return { kind: "empty" };
    return {
      kind: "answer",
      value: entries.map((e) => (e.code === null ? e.name : { code: e.code, name: e.name })),
    };
  }

  if (shape === "text_pairs") {
    const rows = draft.kind === "pairs" ? draft.rows : [];
    const incomplete: number[] = [];
    const filled: Pair[] = [];
    rows.forEach((r, i) => {
      const left = r.left.trim();
      const right = r.right.trim();
      if (left === "" && right === "") return;
      if (left === "" || right === "") incomplete.push(i);
      else filled.push(r.code ? { left, right, code: r.code } : { left, right });
    });
    if (incomplete.length > 0)
      return { kind: "invalid", reason: "incomplete_rows", rows: incomplete };
    return filled.length === 0 ? { kind: "empty" } : { kind: "answer", value: filled };
  }

  const raw = draft.kind === "scalar" ? draft.raw.trim() : "";
  if (raw === "") return { kind: "empty" };

  switch (shape) {
    case "boolean":
      return raw === "true" || raw === "false"
        ? { kind: "answer", value: raw === "true" }
        : { kind: "invalid", reason: "not_a_choice" };
    case "integer": {
      const n = parseNumber(raw);
      if (n === null) return { kind: "invalid", reason: "not_a_number" };
      if (!Number.isInteger(n)) return { kind: "invalid", reason: "not_whole" };
      return inRange(n, bounds)
        ? { kind: "answer", value: n }
        : { kind: "invalid", ...range(bounds) };
    }
    case "money": {
      const n = parseNumber(raw);
      if (n === null) return { kind: "invalid", reason: "not_a_number" };
      const max = bounds.decimals ?? 2;
      const places = /\.(\d+)$/.exec(String(n))?.[1]?.length ?? 0;
      if (places > max) return { kind: "invalid", reason: "too_many_decimals", max };
      return inRange(n, bounds)
        ? { kind: "answer", value: n }
        : { kind: "invalid", ...range(bounds) };
    }
    case "choice":
      return bounds.choices && bounds.choices.length > 0 && !bounds.choices.includes(raw)
        ? { kind: "invalid", reason: "not_a_choice" }
        : { kind: "answer", value: raw };
    default:
      return { kind: "answer", value: raw };
  }
}

/** A month question: the draft may be a number or a name; the answer is 1 to 12. */
export function monthAnswer(draft: Draft): Built {
  const raw = draft.kind === "scalar" ? draft.raw.trim() : "";
  if (raw === "") return { kind: "empty" };
  const m = parseMonth(raw);
  return m === null
    ? { kind: "invalid", reason: "out_of_range", min: 1, max: 12 }
    : { kind: "answer", value: m };
}

/** The limits a question's answer is held to before it is sent. */
export function boundsFor(q: Pick<Question, "code" | "answer_shape" | "choices">): Bounds {
  if (q.answer_shape === "choice") return { choices: q.choices };
  if (q.answer_shape === "money") return { min: 0 };
  switch (q.code) {
    case "org.fiscal_year_start":
      return { min: 1, max: 12 };
    case "code.digits":
      return { min: 1, max: 12 };
    case "release.ageing_hours":
      return { min: 1 };
    default:
      return q.answer_shape === "integer" ? { min: 0 } : {};
  }
}

/** A question's draft, built the way that question is built. */
export function buildAnswer(
  q: Pick<Question, "code" | "answer_shape" | "choices">,
  draft: Draft,
): Built {
  if (q.code === "org.fiscal_year_start") return monthAnswer(draft);
  return toAnswer(q.answer_shape, draft, boundsFor(q));
}

/** The value a built draft sends: the answer, or JSON null to clear it. */
export function wireValue(built: Built): string | number | boolean | unknown[] | null {
  return built.kind === "answer" ? built.value : null;
}

// ── Answers, gates and progress ────────────────────────────────────────────

/** Whether a stored answer is an answer at all — false is one, [] and "" are not. */
export function hasAnswer(answer: unknown): boolean {
  if (answer === null || answer === undefined) return false;
  if (Array.isArray(answer)) return answer.length > 0;
  if (typeof answer === "string") return answer.trim() !== "";
  return true;
}

/**
 * Whether an answer opens the questions gated on it, as erp.interview_questions
 * decides: true, a list with something in it, or any other non-empty value.
 * False does not open a gate.
 */
export function opensGate(answer: unknown): boolean {
  if (typeof answer === "boolean") return answer;
  if (Array.isArray(answer)) return answer.length > 0;
  if (answer === null || answer === undefined) return false;
  return String(answer) !== "";
}

/** Two answers are the same answer regardless of key order — the autosave's "changed?". */
export function sameAnswer(a: unknown, b: unknown): boolean {
  return canonical(a) === canonical(b);
}

function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  if (isObj(v)) {
    return `{${Object.keys(v)
      .sort()
      .map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`)
      .join(",")}}`;
  }
  return JSON.stringify(v ?? null);
}

/** Organisation first: it has to exist before anything below can name it. */
export const SECTION_ORDER = ["B.7", "B.1", "B.2", "B.3", "B.4", "B.5", "B.6"] as const;

export function orderSections(sections: string[]): string[] {
  const known: string[] = [...SECTION_ORDER];
  const unique = [...new Set(sections)];
  return [...known.filter((s) => unique.includes(s)), ...unique.filter((s) => !known.includes(s))];
}

export type QuestionLike = {
  section: string;
  applies: boolean;
  is_required: boolean;
  answer: unknown;
};

export type SectionProgress = {
  section: string;
  asked: number;
  answered: number;
  requiredMissing: number;
  complete: boolean;
};

/**
 * Per section, over the questions that apply now — the denominator moves as
 * gates open. Every section in the interview's order is listed, so the steps
 * on the screen do not come and go.
 */
export function sectionProgress(questions: QuestionLike[]): SectionProgress[] {
  return orderSections([...SECTION_ORDER, ...questions.map((q) => q.section)]).map((section) => {
    const asked = questions.filter((q) => q.section === section && q.applies);
    const answered = asked.filter((q) => hasAnswer(q.answer)).length;
    const requiredMissing = asked.filter((q) => q.is_required && !hasAnswer(q.answer)).length;
    return {
      section,
      asked: asked.length,
      answered,
      requiredMissing,
      complete: asked.length > 0 && answered === asked.length,
    };
  });
}

/** Where to pick up: the first section with a question that applies and has no answer. */
export function resumeSection(progress: SectionProgress[]): string | null {
  return (
    progress.find((p) => p.answered < p.asked)?.section ??
    progress.find((p) => p.asked > 0)?.section ??
    progress[0]?.section ??
    null
  );
}

/** Required questions that apply and are not answered, in section order. */
export function missingRequired<T extends QuestionLike & { seq: number }>(questions: T[]): T[] {
  return questions
    .filter((q) => q.applies && q.is_required && !hasAnswer(q.answer))
    .sort((a, b) => sectionRank(a.section) - sectionRank(b.section) || a.seq - b.seq);
}

// ── Plain sentences ────────────────────────────────────────────────────────

/** "{name} ({code})" with the values put in; a placeholder with no value is left out. */
export function fill(template: string, values: Record<string, string | number>): string {
  return template.replace(/\{([a-z_]+)\}/g, (whole, key: string) =>
    key in values ? String(values[key]) : whole,
  );
}

/**
 * Labels the questions already know, for the values a change names: a pack
 * code becomes "United Kingdom VAT", a currency code its name. Keyed
 * `list:value`.
 */
export type Names = Record<string, string>;

const NAME_SOURCES: { list: string; question: string; side: "right" | "left" }[] = [
  { list: "currency", question: "org.currencies", side: "right" },
  { list: "currency", question: "approval.currency", side: "right" },
  { list: "country", question: "org.countries", side: "right" },
  { list: "locale", question: "org.locales", side: "right" },
  { list: "pack", question: "org.legislation", side: "right" },
  { list: "role", question: "approval.role", side: "right" },
  { list: "account", question: "posting.receipt_account", side: "right" },
  { list: "department", question: "dept.list", side: "right" },
  { list: "axis", question: "classification.axes", side: "right" },
  { list: "company", question: "org.currencies", side: "left" },
  { list: "company", question: "org.legislation", side: "left" },
  { list: "site", question: "org.allocation_by_site", side: "left" },
];

export function namesFromQuestions(questions: Question[]): Names {
  const names: Names = {};
  for (const source of NAME_SOURCES) {
    const q = questions.find((x) => x.code === source.question);
    if (!q) continue;
    const rows = source.side === "left" ? q.left_suggestions : q.suggestions;
    for (const s of rows) {
      const key = `${source.list}:${"code" in s && s.code ? s.code : s.value}`;
      if (!(key in names)) names[key] = s.label;
      const byValue = `${source.list}:${s.value}`;
      if (!(byValue in names)) names[byValue] = s.label;
    }
  }
  for (const pair of pairsOf(questions.find((x) => x.code === "org.companies")?.answer)) {
    const key = `company:${pair.left}`;
    if (!(key in names)) names[key] = pair.right;
  }
  return names;
}

/** A value as a person reads it: its label and code, or the code alone. */
export function named(names: Names, list: string, value: string): string {
  const label =
    names[`${list}:${value}`] ??
    names[`${list}:${value.toUpperCase()}`] ??
    names[`${list}:${value.toLowerCase()}`];
  if (!label || label === value) return value;
  return label.includes(value) ? label : `${label} (${value})`;
}

function text(p: Record<string, unknown>, key: string): string {
  const v = p[key];
  if (typeof v === "string") return v.trim();
  if (typeof v === "number" || typeof v === "boolean") return String(v);
  return "";
}

function amount(minor: unknown, currency: string, locale: string): string {
  const n = typeof minor === "number" ? minor : typeof minor === "string" ? Number(minor) : NaN;
  if (!Number.isFinite(n)) return currency;
  try {
    const format = new Intl.NumberFormat(locale, { style: "currency", currency });
    const digits = format.resolvedOptions().maximumFractionDigits ?? 2;
    return format.format(n / 10 ** digits);
  } catch {
    return `${(n / 100).toFixed(2)} ${currency}`;
  }
}

function method(value: string, ui: Translate): string {
  switch (value) {
    case "fefo":
      return ui("earliest expiry first");
    case "fifo":
      return ui("oldest stock first");
    case "lifo":
      return ui("newest stock first");
    default:
      return value;
  }
}

function labelLevel(value: string, ui: Translate): string {
  switch (value) {
    case "none":
      return ui("no handling-unit labels; stock is known by product, batch and serial");
    case "unit":
      return ui("each unit");
    case "case":
      return ui("the case");
    case "carton":
      return ui("the carton");
    case "pallet":
      return ui("the pallet");
    case "master_pallet":
      return ui("the master pallet");
    default:
      return value;
  }
}

function approver(p: Record<string, unknown>, ui: Translate, names: Names): string {
  const role = text(p, "approver_role");
  const manager = p["use_line_manager"] === true || p["use_line_manager"] === "true";
  if (role && manager) {
    return fill(ui("{role}, and the manager of whoever raised it"), {
      role: named(names, "role", role),
    });
  }
  if (role) return named(names, "role", role);
  if (manager) return ui("the manager of whoever raised it");
  return ui("nobody named yet");
}

function codePattern(segments: unknown): { pattern: string; example: string } {
  let pattern = "";
  let example = "";
  for (const s of objects(segments)) {
    const kind = text(s, "kind");
    if (kind === "literal") {
      pattern += text(s, "value");
      example += text(s, "value");
    } else if (kind === "sequence") {
      const length = Math.max(1, Number(text(s, "length")) || 1);
      pattern += "#".repeat(length);
      example += `${"0".repeat(length - 1)}1`;
    } else if (kind === "axis") {
      const axis = text(s, "axis");
      const length = Math.max(1, Number(text(s, "length")) || 2);
      pattern += `[${axis}]`;
      example += axis.slice(0, length).toUpperCase();
    }
  }
  return { pattern, example };
}

/**
 * One proposed change as a sentence: "Add the department Finance (FIN)".
 *
 * Written from the change's own payload rather than from its key, because the
 * key is the database's handle (`item|FG`, `stock.allocation_policy|*|MAIN`)
 * and the payload is what will actually be put in force.
 */
export function describeItem(
  item: Pick<ChangeItem, "object_kind" | "object_key" | "operation" | "payload">,
  ui: Translate,
  options: { locale?: string; names?: Names } = {},
): string {
  const sentence = describe(item, ui, options.locale ?? "en", options.names ?? {});
  return item.operation === "remove"
    ? fill(ui("Remove: {change}"), { change: sentence })
    : sentence;
}

function describe(
  item: Pick<ChangeItem, "object_kind" | "object_key" | "payload">,
  ui: Translate,
  locale: string,
  names: Names,
): string {
  const p = item.payload;
  const code = text(p, "code") || item.object_key;
  const name = text(p, "name");

  switch (item.object_kind) {
    case "department":
      return name && name !== code
        ? fill(ui("Add the department {name} ({code})"), { name, code })
        : fill(ui("Add the department {code}"), { code });

    case "approval_band": {
      const values = {
        department: named(names, "department", text(p, "department")),
        amount: amount(p["lower_bound_minor"], text(p, "currency") || "GBP", locale),
        approver: approver(p, ui, names),
      };
      switch (text(p, "object_type")) {
        case "requisition":
          return fill(
            ui("A requisition from {department} above {amount} needs sign-off by {approver}"),
            values,
          );
        case "purchase_order":
          return fill(
            ui("A purchase order from {department} above {amount} needs sign-off by {approver}"),
            values,
          );
        case "purchase_invoice":
          return fill(
            ui("A purchase invoice for {department} above {amount} needs sign-off by {approver}"),
            values,
          );
        case "sales_order":
          return fill(
            ui("A sales order from {department} above {amount} needs sign-off by {approver}"),
            values,
          );
        default:
          return fill(
            ui("A {document} from {department} above {amount} needs sign-off by {approver}"),
            { ...values, document: text(p, "object_type").replace(/_/g, " ") },
          );
      }
    }

    case "posting_class": {
      const values = { name: name || code, code };
      return text(p, "kind") === "party"
        ? fill(ui("Add the accounting code {name} ({code}) for business partners"), values)
        : fill(ui("Add the accounting code {name} ({code}) for products"), values);
    }

    case "account_determination": {
      const account = text(p, "account");
      return text(p, "transaction_type") === "goods_receipt"
        ? fill(ui("Goods that arrive are added to nominal account {account}"), {
            account: named(names, "account", account),
          })
        : fill(ui("{event} uses nominal account {account}"), {
            event: text(p, "transaction_type").replace(/_/g, " "),
            account: named(names, "account", account),
          });
    }

    case "classification_axis": {
      const values = { name: name || code, code };
      return p["is_mandatory"] === true || p["is_mandatory"] === "true"
        ? fill(ui("Group products by {name} ({code}); every product needs a value"), values)
        : fill(ui("Group products by {name} ({code}); a value is optional"), values);
    }

    case "classification_value":
      return fill(ui("Add {name} ({code}) as a value of {axis}"), {
        name: name || code,
        code,
        axis: named(names, "axis", text(p, "axis")),
      });

    case "code_template": {
      const { pattern, example } = codePattern(p["segments"]);
      return pattern === ""
        ? fill(ui("Add the product code pattern {name}"), { name: name || code })
        : fill(ui("New product codes follow the pattern {pattern}, for example {example}"), {
            pattern,
            example,
          });
    }

    case "release_area": {
      const hours = text(p, "ageing_hours");
      const values = { name: name || code, code, hours };
      if (text(p, "replenishment_mode") === "push") {
        return hours
          ? fill(
              ui(
                "Add the marshalling area {name} ({code}), topped up when short; stock left more than {hours} hours goes back to storage",
              ),
              values,
            )
          : fill(ui("Add the marshalling area {name} ({code}), topped up when short"), values);
      }
      return hours
        ? fill(
            ui(
              "Add the marshalling area {name} ({code}), bringing in just what is short; stock left more than {hours} hours goes back to storage",
            ),
            values,
          )
        : fill(
            ui("Add the marshalling area {name} ({code}), bringing in just what is short"),
            values,
          );
    }

    case "entity": {
      const known = named(names, "company", code);
      const head =
        name && name !== code
          ? fill(ui("The company {name} ({code})"), { name, code })
          : known === code
            ? fill(ui("The company {code}"), { code })
            : known;
      const parts: string[] = [];
      const country = text(p, "country");
      const currency = text(p, "currency");
      const loc = text(p, "locale");
      const month = Number(text(p, "fiscal_year_start_month"));
      if (country)
        parts.push(fill(ui("in {country}"), { country: named(names, "country", country) }));
      if (currency) {
        parts.push(
          fill(ui("keeps its books in {currency}"), {
            currency: named(names, "currency", currency),
          }),
        );
      }
      if (loc)
        parts.push(fill(ui("writes in {language}"), { language: named(names, "locale", loc) }));
      if (Number.isInteger(month) && month >= 1 && month <= 12) {
        parts.push(fill(ui("starts its year in {month}"), { month: monthName(month, locale) }));
      }
      return parts.length === 0 ? head : `${head}: ${parts.join(", ")}`;
    }

    case "legislation_binding":
      return fill(ui("{company} follows {rules}"), {
        company: named(names, "company", text(p, "entity")),
        rules: named(names, "pack", text(p, "pack")),
      });

    case "costing_policy": {
      const how =
        text(p, "method") === "standard"
          ? ui("a standard cost you set")
          : text(p, "method") === "fifo"
            ? ui("first in, first out")
            : text(p, "method") === "average"
              ? ui("average cost")
              : text(p, "method");
      const variance = text(p, "variance_account");
      return variance
        ? fill(
            ui(
              "Stock is costed at {method}; differences from what you pay go to nominal account {account}",
            ),
            { method: how, account: named(names, "account", variance) },
          )
        : fill(ui("Stock is costed at {method}"), { method: how });
    }

    case "container_identity_policy": {
      const level = labelLevel(text(p, "identity_level"), ui);
      const kind = text(p, "item_class");
      return kind
        ? fill(ui("{kind} products are labelled at {level}"), { kind, level })
        : fill(ui("Stock is labelled at {level}"), { level });
    }

    case "config": {
      if (text(p, "config_type") === "stock.allocation_policy") {
        const value = isObj(p["value"]) ? p["value"] : {};
        const how = method(text(value, "default"), ui);
        const site = text(p, "site");
        return site
          ? fill(ui("At {site}, stock is picked {method}"), {
              site: named(names, "site", site),
              method: how,
            })
          : fill(ui("Stock is picked {method}"), { method: how });
      }
      return fill(ui("Change the setting {setting}"), {
        setting: text(p, "config_type") || item.object_key,
      });
    }

    case "capability": {
      const feature = text(p, "code") || item.object_key;
      const on = !(p["enabled"] === false || p["enabled"] === "false");
      if (feature === "statutory_chart_8_1") {
        return on
          ? ui("Number nominal accounts by statutory ranges")
          : ui("Stop numbering nominal accounts by statutory ranges");
      }
      return on
        ? fill(ui("Switch on the feature {feature}"), { feature })
        : fill(ui("Switch off the feature {feature}"), { feature });
    }

    default:
      return fill(ui("Another change: {kind} {key}"), {
        kind: item.object_kind.replace(/_/g, " "),
        key: item.object_key,
      });
  }
}

/**
 * An answer as a person reads it, for "Likely answer: …": the option's label
 * rather than its value, a month by name, rows as "left: right".
 */
export function answerText(
  q: Pick<Question, "code" | "answer_shape" | "suggestions" | "left_suggestions">,
  answer: unknown,
  ui: Translate,
  locale = "en",
): string {
  const labelOf = (value: string) => q.suggestions.find((s) => s.value === value)?.label ?? value;
  switch (q.answer_shape) {
    case "text_list":
      return listEntries(answer)
        .map((e) => e.name)
        .join(", ");
    case "text_pairs":
      return pairsOf(answer)
        .map((pair) => {
          const left = q.left_suggestions.find((l) => l.value === pair.left)?.label ?? pair.left;
          const right =
            q.suggestions.find(
              (s) => (pair.code && (s.code ?? s.value) === pair.code) || s.value === pair.right,
            )?.label ?? pair.right;
          return `${left}: ${right}`;
        })
        .join("; ");
    case "boolean":
      if (answer === true || answer === "true")
        return labelOf("true") === "true" ? ui("Yes") : labelOf("true");
      if (answer === false || answer === "false")
        return labelOf("false") === "false" ? ui("No") : labelOf("false");
      return "";
    default: {
      if (answer === null || answer === undefined) return "";
      const value = typeof answer === "string" || typeof answer === "number" ? String(answer) : "";
      if (q.code === "org.fiscal_year_start") {
        const m = parseMonth(value);
        return m === null ? value : monthName(m, locale);
      }
      const label = labelOf(value);
      return label === value ? value : `${label} (${value})`;
    }
  }
}
