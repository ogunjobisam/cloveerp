import { prettifyField } from "./friendly";
import { formatMinor } from "./money";
import { quantityWords } from "./samples";

/**
 * Words a customer reads, made from words the database wrote.
 *
 * Walking the live desk on 14 September, a refusal read "This is not allowed
 * right now. you despatched DN-000255 and cannot also invoice it B1 has carried
 * sales.despatch and sales.invoice as separate permissions since it was
 * written; …" — a sentence starting in lower case, then a note written for
 * whoever maintains the engine. A new requisition said "New requisition —
 * done." without its number, a document page's breadcrumb was a UUID, and the
 * Close step opened on December next year.
 *
 * Everything here is a plain function over what a door returned, so what a
 * customer reads can be tested without a screen or a database.
 */

type Row = Record<string, unknown>;

// ─────────────────────────────────────────────────────────────────────────────
// Sentences from the database
// ─────────────────────────────────────────────────────────────────────────────

/**
 * The modules a permission code is written under: `sales.despatch`,
 * `master_data.write`. A code is how the engine names a permission and is
 * never how a person does — the People and permissions screen has the name.
 */
const PERMISSION_MODULES =
  "administration|commercial|documents?|finance|governance|inventory|logistics|master_data|operations|planning|platform|procurement|production|quality|reporting|sales";

const PERMISSION_CODE = `\\b(?:${PERMISSION_MODULES})\\.[a-z][a-z_]*\\b`;

/**
 * Wording that belongs to the people who build the product, not the people
 * who use it. supabase/migrations/20260914075500 holds the same patterns over
 * the refusal register, so a registered refusal cannot say what a screen
 * would hide.
 */
export const INTERNAL_WORDING: readonly RegExp[] = [
  // A section of the specification: §17.6, B1, D34, Part 5, v1.5.
  /§/,
  /\b[BD]\d{1,2}\b/,
  /\bPart \d{1,2}\b/,
  /\bv\d+\.\d+\b/,
  // A permission code.
  new RegExp(PERMISSION_CODE),
  // A function, table or schema: erp.invoice_from_delivery, erp_ref.refusal.
  /\b(?:erp|erp_meta|erp_ref|erp_test|erp_ai|public|pg_catalog)\.[a-z_]+/,
  /\berp_[a-z0-9_]+/,
  // Any other identifier written the way the database writes one.
  /\b[a-z][a-z0-9]*_[a-z0-9_]+\b/,
  // A refusal token inside the sentence.
  /\b(?:CLOVEERP|ERPWARE)_[A-Z0-9_]+/,
  // The history of the code rather than the rule.
  /since it was written/i,
  /\brow[- ]level security\b/i,
  /\b(?:SQLSTATE|jsonb|uuid)\b/i,
];

/** Whether a sentence is written for the people who build the product. */
export function soundsInternal(text: string): boolean {
  return INTERNAL_WORDING.some((pattern) => pattern.test(text));
}

/**
 * The first letter in upper case.
 *
 * Only when the sentence starts with a letter, after any opening quote or
 * bracket: "2 of 40 cases" stays as it is rather than becoming "2 Of 40".
 */
/**
 * "a" or "an", for a noun a screen is about to name.
 *
 * Quality control's step panel said "Choose a event on the left" because the
 * sentence was built from the step's own noun and the article was a letter in
 * a template. Sound, not spelling, decides the word, so the exceptions are
 * listed rather than guessed: a "u" that says "you" takes "a", and an "h" that
 * is not spoken takes "an".
 */
const SOUNDED_CONSONANT = /^(?:uni|use|user|uk|one|euro)/i;
const SILENT_H = /^(?:hour|honest|honour)/i;

export function article(noun: string): "a" | "an" {
  const word = noun.trim().toLowerCase();
  if (word === "") return "a";
  if (SILENT_H.test(word)) return "an";
  if (SOUNDED_CONSONANT.test(word)) return "a";
  return /^[aeiou]/.test(word) ? "an" : "a";
}

export function capitalise(text: string): string {
  return text
    .trim()
    .replace(
      /^([\s"'“‘([]*)(\p{Ll})/u,
      (_, lead: string, first: string) => `${lead}${first.toUpperCase()}`,
    );
}

/** A sentence as a sentence: capitalised, and ending in a stop. */
export function asSentence(text: string): string {
  const out = capitalise(text);
  if (out === "") return out;
  return /[.!?…]["'”’)\]]*$/.test(out) ? out : `${out}.`;
}

/**
 * A sentence the database wrote, fit to show a customer — or null.
 *
 * Null when there is nothing to say, and when what there is to say is written
 * for the people who maintain the engine. The verbatim text is still kept, in
 * the folded technical detail, for whoever supports the customer.
 */
export function plainSentence(text: string | null | undefined): string | null {
  const t = (text ?? "").trim();
  if (t === "" || soundsInternal(t)) return null;
  return asSentence(t);
}

/**
 * The engine's hint, fit to show the person it refused — or null.
 *
 * As plainSentence(), except that a hint may name the permission to ask for.
 * "Ask an administrator to grant inventory.read." is the next thing to do, and
 * the administrator finds the permission by that code; e2e/desk.spec.ts holds
 * the screen to showing it. Everything else written for the people who
 * maintain the engine is still kept out, so the hint shown on 14 September —
 * a section of the specification and the history of the code — still is.
 * The refusal register's own wording stays stricter: 20260914075500 refuses a
 * permission code there, where the product writes the words.
 */
export function plainHint(text: string | null | undefined): string | null {
  const t = (text ?? "").trim();
  if (t === "" || soundsInternal(t.replace(new RegExp(PERMISSION_CODE, "g"), "permission")))
    return null;
  return asSentence(t);
}

// ─────────────────────────────────────────────────────────────────────────────
// What an action made
// ─────────────────────────────────────────────────────────────────────────────

function asRecord(value: unknown): Row | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Row)
    : null;
}

function text(row: Row, key: string): string | null {
  const v = row[key];
  if (typeof v === "string" && v.trim() !== "") return v.trim();
  if (typeof v === "number" && Number.isFinite(v)) return String(v);
  return null;
}

/**
 * What a document became when it was moved on, by the move's code.
 *
 * "Create and move on" returns the transition it performed, not the state it
 * reached. These are the moves out of draft the product's lifecycles offer
 * (20260914060000), and the few that follow them; anything else "moved on".
 */
const MOVED_TO: Readonly<Record<string, string>> = {
  submit: "submitted",
  approve: "approved",
  post: "posted",
  register: "registered",
  issue: "issued",
  send: "sent",
  confirm: "confirmed",
  release: "released",
  complete: "completed",
  order: "ordered",
  book: "booked",
  close: "closed",
  accept: "accepted",
  // An order converted from its requisition unchanged (20260922380000).
  inherit_approval: "approved",
};

export function movedOnWord(code: string | null | undefined): string | null {
  if (!code) return null;
  return MOVED_TO[code] ?? "moved on";
}

/**
 * "REQ-000047 created and submitted." — when a door made a document and says
 * which. A door that answers with a document's id and number made it; one it
 * came from rides along as the source (a requisition an order was converted
 * from, the order a delivery was raised from).
 */
export function documentOutcome(result: unknown): string | null {
  const r = asRecord(result);
  if (!r) return null;
  const number = text(r, "document_number");
  if (!number || typeof r["document_id"] !== "string") return null;
  const from = text(r, "source_document_number") ?? text(r, "order_document_number");
  const moved = movedOnWord(text(r, "moved_on"));
  return `${number} created${from ? ` from ${from}` : ""}${moved ? ` and ${moved}` : ""}.`;
}

/**
 * The document a door made, from its answer: what the screen opens next.
 * Converting a quotation answers with the order it raised.
 */
export function madeDocumentId(result: unknown): string | null {
  const id = asRecord(result)?.["document_id"];
  return typeof id === "string" && id !== "" ? id : null;
}

const plural = (n: number, one: string, many: string) => (n === 1 ? one : many);

/**
 * What a door did to a document that was already there, by the door (J-83).
 *
 * Despatching and receiving a transfer, and posting a stock adjustment, answer
 * with the document's id and number, which documentOutcome() reads as a
 * document made: both ends of a transfer said "TRF-000026 created.".
 */
const MOVED_BY_FN: Readonly<Record<string, string>> = {
  erp_despatch_transfer: "despatched",
  erp_receive_transfer: "received",
  erp_post_stock_adjustment: "posted",
};

/** "TRF-000026 despatched." — or null for a door that makes what it names. */
export function movedDocumentOutcome(fn: string | undefined, result: unknown): string | null {
  const word = fn ? MOVED_BY_FN[fn] : undefined;
  const r = asRecord(result);
  if (!word || !r) return null;
  const number = text(r, "document_number");
  return number ? `${number} ${word}.` : null;
}

/** Who brings an order's goods, as the form offered it (20261004955000). */
const FREIGHT_TERMS: Readonly<Record<string, string>> = {
  supplier_delivers: "the supplier delivers the goods",
  we_collect: "we collect the goods",
};

/** "PO-000143: we collect the goods." from erp_set_freight_terms (J-124). */
export function freightTermsOutcome(result: unknown): string | null {
  const r = asRecord(result);
  if (!r) return null;
  const number = text(r, "order_number");
  const terms = FREIGHT_TERMS[text(r, "freight_terms") ?? ""];
  return number && terms ? `${number}: ${terms}.` : null;
}

/**
 * What settling a sample did, from erp_settle_samples (J-124): how many went
 * which way, the receipt they came in on, and how many are still held.
 * "GRN-000012: 3 returned to the supplier, 2 still held."
 */
export function samplesOutcome(result: unknown): string | null {
  const r = asRecord(result);
  if (!r) return null;
  const receipt = text(r, "receipt_number");
  const quantity = Number(r["quantity"]);
  const held = Number(r["held"]);
  if (!receipt || !Number.isFinite(quantity)) return null;
  const price = Number(r["price_minor"]);
  const outcome = text(r, "outcome");
  const done =
    outcome === "return"
      ? "returned to the supplier"
      : outcome === "keep"
        ? "kept free"
        : outcome === "buy"
          ? Number.isFinite(price)
            ? `bought at ${formatMinor(price, text(r, "currency") ?? "GBP")} each`
            : "bought"
          : null;
  if (!done) return null;
  const left = Number.isFinite(held)
    ? held > 0
      ? `, ${quantityWords(held)} still held`
      : ", none still held"
    : "";
  return `${receipt}: ${quantityWords(quantity)} ${done}${left}.`;
}

/**
 * A sentence a door's own answer makes, naming the record it acted on — or
 * null. A toast that names its record needs no second line saying what the
 * form acted on: that line was written before the press and said what was
 * held before it (J-124).
 */
export function namedOutcome(fn: string | undefined, result: unknown): string | null {
  if (fn === "erp_set_freight_terms") return freightTermsOutcome(result);
  if (fn === "erp_settle_samples") return samplesOutcome(result);
  return movedDocumentOutcome(fn, result);
}

/**
 * A problem reported, by its reference, from its row in erp_quality_events
 * (J-124): the door answers with the event's id alone.
 */
export function qualityEventOutcome(row: unknown): string | null {
  const r = asRecord(row);
  const reference = r ? text(r, "reference") : null;
  return reference ? `${reference} reported.` : null;
}

/**
 * A journal reversal is raised and submitted for somebody else to approve, and
 * answers with the journal's state, not a document (J-151). "Reverse the
 * journal — done." said nothing of the approval it waits for.
 */
function journalOutcome(fn: string | undefined, result: unknown): string | null {
  if (fn !== "erp_reverse_journal") return null;
  const r = asRecord(result);
  return r && text(r, "state") === "submitted" ? "Submitted for approval." : null;
}

/**
 * What a move on a document's page did to it, from the state the door answers
 * (J-122): "PO-000143 is now approved." Null when the answer has no state.
 */
export function transitionOutcome(
  number: string | null | undefined,
  result: unknown,
): string | null {
  const r = asRecord(result);
  const state = r ? text(r, "state") : null;
  if (!state) return null;
  return `${number && number.trim() !== "" ? number.trim() : "This document"} is now ${prettifyField(state).toLowerCase()}.`;
}

/**
 * What a press on the counter's worklist did (J-122), by its door and what it
 * answered: a count recorded says whether it posted or what it waits for.
 */
export function countOutcome(place: string, fn: string, result: unknown): string {
  const at = place.trim() !== "" ? place.trim() : "The count";
  if (fn === "erp_post_count") return `${at}: posted.`;
  if (fn === "erp_recount_task") return `${at}: to be counted again.`;
  switch (result) {
    case "posted":
      return `${at}: counted and posted.`;
    case "approved":
      return `${at}: counted and approved.`;
    case "pending_approval":
      return `${at}: counted, and waiting for approval.`;
    case "counted":
      return `${at}: counted, and waiting to be posted.`;
    default:
      return `${at}: counted.`;
  }
}

/**
 * A lookup's answer, in a sentence.
 *
 * "Find a price" and "Promise a date" ask a question and change nothing. The
 * count rule below read their answers as work done: a price found as "1 record
 * created", none as "nothing was raised", and a date as "done", so the answer
 * itself was never shown (found walking the live product, 4 October 2026).
 * Null for any other routine, and for an answer in a shape this does not know.
 */
export function lookupOutcome(
  fn: string | undefined,
  label: string,
  result: unknown,
): string | null {
  if (fn === "erp_promise_date") {
    return typeof result === "string" && result !== ""
      ? `${label}: that quantity can be promised for ${result}.`
      : `${label}: no date can be promised for that quantity from that site.`;
  }
  if (fn === "erp_resolve_price" || fn === "erp_resolve_purchase_price") {
    const row = asRecord(Array.isArray(result) ? result[0] : result);
    const amount = row ? Number(row["amount_minor"]) : NaN;
    const source = row ? text(row, "source") : null;
    if (!row || row["amount_minor"] === null || !Number.isFinite(amount)) {
      return fn === "erp_resolve_price"
        ? `${label}: nothing prices this product for this customer today. Type a price on the line, or add one to their price list.`
        : `${label}: ${source ?? "no price is on record for this supplier and product"}. Type a price on the line, or add one to the supplier's price list.`;
    }
    const list = text(row, "price_list_code");
    const currency = text(row, "currency") ?? "GBP";
    return `${label}: ${formatMinor(amount, currency)} each, from ${source ?? "the price list"}${list ? ` (${list})` : ""}.`;
  }
  return null;
}

/**
 * What a count means, for the routines whose rows are not "records created".
 * Applying cash returns a row per open item it settled, not anything new.
 */
const COUNTED: Readonly<Record<string, (n: number) => string>> = {
  erp_apply_cash: (n) => `Cash applied to ${n} open ${plural(n, "item", "items")}.`,
  erp_raise_putaway_tasks: (n) => `${n} putaway ${plural(n, "task", "tasks")} raised.`,
  erp_raise_replenishment_tasks: (n) => `${n} replenishment ${plural(n, "task", "tasks")} raised.`,
  erp_raise_count_tasks: (n) => `${n} count ${plural(n, "task", "tasks")} raised.`,
  erp_generate_count_tasks: (n) => `${n} count ${plural(n, "task", "tasks")} raised.`,
};

/**
 * What just happened, in a sentence.
 *
 * Several routines answer with a count of the rows they raised, and a count of
 * nought is the commonest confusion in the product: the form closes, nothing
 * appears in the next step, and it looks broken when in fact there was nothing
 * standing there to move. So say so. A document made says its number.
 */
export function actionOutcome(
  label: string,
  result: unknown,
  emptyNote?: string,
  fn?: string,
): string {
  // A door that acted on a record it names says what it did to it, before an
  // answer holding a document's number is read as a document made.
  const named = namedOutcome(fn, result) ?? journalOutcome(fn, result);
  if (named) return named;

  const made = documentOutcome(result);
  if (made) return made;

  const answer = lookupOutcome(fn, label, result);
  if (answer) return answer;

  const record = asRecord(result);
  const count =
    typeof result === "number"
      ? result
      : Array.isArray(result)
        ? result.length
        : record && typeof record["created"] === "number"
          ? record["created"]
          : null;

  if (count === 0)
    return emptyNote
      ? `${label}: nothing was raised — ${emptyNote} Change the site or the dates and try again.`
      : `${label}: nothing was raised — there was no work waiting to be moved on. Check the step, the site and the dates you chose.`;
  if (count !== null && count > 0) {
    const counted = fn ? COUNTED[fn] : undefined;
    if (counted) return counted(count);
    return `${label}: ${count} ${plural(count, "record", "records")} created.`;
  }
  return `${label} — done.`;
}

/**
 * What a receipt did, from the rows erp_apply_cash answers (20260929400000).
 *
 * A row for each invoice the cash reached, and one with no item for what was
 * left over after all of them. The settlement tolerance decides the rest
 * (20260929300000): a short on the last invoice within it is written off, and
 * a remainder is written off within it or kept on the customer's account
 * beyond it. "Cash applied to 2 open items" said none of that, and counted the
 * remainder as an item. A database older than 20260929400000 does not say what
 * it wrote off or kept, and only the leftover is named.
 */
export function cashOutcome(result: unknown, currency: string): string | null {
  if (!Array.isArray(result)) return null;
  const rows = result.map(asRecord).filter((r): r is Row => r !== null);
  const minor = (r: Row, key: string) => {
    const n = Number(r[key]);
    return Number.isFinite(n) ? n : 0;
  };
  const items = rows.filter((r) => typeof r["subledger_item_id"] === "string");
  const rest = rows.find(
    (r) => r["subledger_item_id"] === null || r["subledger_item_id"] === undefined,
  );
  const money = (n: number) => formatMinor(n, currency);

  const applied = items.reduce((sum, r) => sum + minor(r, "applied_minor"), 0);
  const writtenOff = rows.reduce((sum, r) => sum + minor(r, "written_off_minor"), 0);
  const onAccount = rows.reduce((sum, r) => sum + minor(r, "on_account_minor"), 0);
  const leftOver = rest ? minor(rest, "remaining_minor") : 0;
  const says = rows.some((r) => "on_account_minor" in r || "written_off_minor" in r);

  const parts = [
    `${money(applied)} applied to ${items.length} open ${plural(items.length, "invoice", "invoices")}`,
  ];
  if (writtenOff > 0) parts.push(`${money(writtenOff)} written off within the tolerance`);
  if (onAccount > 0) parts.push(`${money(onAccount)} on account`);
  if (!says && leftOver > 0) parts.push(`${money(leftOver)} left over`);
  const last = parts.pop() ?? "";
  return `${parts.length > 0 ? `${parts.join(", ")} and ${last}` : last}.`;
}

/** A document an outcome names, and the way to it. */
export type OutcomeDocument = { documentId: string; number: string };

/** A sentence saying what happened, and the documents it names, in its order. */
export type Outcome = { message: string; documents: OutcomeDocument[] };

/**
 * How long an outcome worth reading stays: one that names a document to follow,
 * or a lookup's answer. Longer than the five seconds every other toast gets.
 * It was twenty, and since most outcomes name a document, three of them stacked
 * over the record's heading for a minute (J-125).
 */
export const OUTCOME_LINGER_MS = 8_000;

/**
 * The receipts Apply cash opened, from its rows, in the order the rows name
 * them (20260930000000). Usually one; one per company where the cash reached
 * invoices of two (PR13 D5); none where the organisation is on receivables
 * version 1, whose rows name no document.
 */
export function receiptIds(result: unknown): string[] {
  if (!Array.isArray(result)) return [];
  const ids: string[] = [];
  for (const row of result.map(asRecord)) {
    const id = row?.["document_id"];
    if (typeof id === "string" && id !== "" && !ids.includes(id)) ids.push(id);
  }
  return ids;
}

/**
 * What a receipt did, led by the receipt it made: "RCPT-000012: £600.00
 * applied to 1 open invoice and £100.00 on account." A receipt whose number
 * could not be read is still linked, as "the receipt"; rows that name no
 * receipt say what they did and nothing more.
 */
export function receiptOutcome(
  result: unknown,
  currency: string,
  receipts: readonly { documentId: string; number: string | null }[],
): Outcome | null {
  const did = cashOutcome(result, currency);
  if (did === null) return null;
  const documents = receipts.map((r, i) => ({
    documentId: r.documentId,
    number: r.number ?? (receipts.length === 1 ? "the receipt" : `receipt ${i + 1}`),
  }));
  const numbered = documents.filter((_, i) => receipts[i]?.number);
  if (numbered.length === 0) return { message: did, documents };
  return { message: `${joinAnd(numbered.map((d) => d.number))}: ${did}`, documents };
}

/**
 * What paying a run did, from erp_pay_payment_run's answer: the run, what left
 * the bank, and the supplier payments it made (20260930200000), each of which
 * prints a remittance advice from its own page. An organisation on procurement
 * controls version 6 makes no payment, and the sentence counts the bills.
 */
export function paymentRunOutcome(result: unknown, label: string): Outcome | null {
  const r = asRecord(result);
  if (!r) return null;
  const currency = text(r, "currency") ?? "GBP";
  const paid = Number(r["paid_minor"]);
  if (!Number.isFinite(paid)) return null;
  const run = text(r, "reference") ?? label;
  const payments = Array.isArray(r["payments"])
    ? r["payments"].map(asRecord).flatMap((p) => {
        const id = p?.["document_id"];
        const number = p ? text(p, "document_number") : null;
        return typeof id === "string" && number ? [{ documentId: id, number }] : [];
      })
    : [];
  const bills = Number(r["lines_paid"]);
  const writtenOff = Number(r["written_off_minor"]);
  const held = Number(r["held"]);

  const parts = [`${run} paid ${formatMinor(paid, currency)}`];
  if (payments.length > 0)
    parts[0] += ` to ${payments.length} ${plural(payments.length, "supplier", "suppliers")}: ${joinAnd(
      payments.map((p) => p.number),
    )}`;
  else if (Number.isFinite(bills) && bills > 0)
    parts[0] += ` on ${bills} ${plural(bills, "bill", "bills")}`;
  if (Number.isFinite(writtenOff) && writtenOff > 0)
    parts.push(`${formatMinor(writtenOff, currency)} written off within the tolerance`);
  const sentence = `${parts.join(", and ")}.`;
  const heldNote =
    Number.isFinite(held) && held > 0
      ? ` ${held} ${plural(held, "line was", "lines were")} held and not paid.`
      : "";
  return { message: `${sentence}${heldNote}`, documents: payments };
}

function joinAnd(words: readonly string[]): string {
  if (words.length <= 1) return words[0] ?? "";
  return `${words.slice(0, -1).join(", ")} and ${words[words.length - 1] ?? ""}`;
}

/**
 * What a planning run produced, from its row in erp_planning_runs.
 *
 * The run returns only its id, and "Run planning — done." says nothing about
 * whether anything needs ordering. The run's own row counts what it raised.
 */
export function planningOutcome(label: string, run: unknown): string | null {
  const r = asRecord(run);
  if (!r) return null;
  const orders = Number(r["orders_raised"]);
  const exceptions = Number(r["exceptions_raised"]);
  if (!Number.isFinite(orders) || !Number.isFinite(exceptions)) return null;
  if (orders === 0 && exceptions === 0)
    return `${label}: no planned orders and no exceptions. Nothing at that site runs short within the horizon. Planning orders a stocked product only when its planning policy reorders and open orders or the forecast take its projected stock below the reorder point.`;
  const parts = [
    `${orders} planned ${plural(orders, "order", "orders")}`,
    `${exceptions} ${plural(exceptions, "exception", "exceptions")}`,
  ];
  return `${label}: ${parts.join(" and ")}.`;
}

// ─────────────────────────────────────────────────────────────────────────────
// A document's own page
// ─────────────────────────────────────────────────────────────────────────────

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The document a path opens, when it opens one: /documents/<uuid>. */
export function documentIdInPath(pathname: string): string | null {
  const m = /^\/documents\/([^/]+)\/?$/.exec(pathname);
  const id = m?.[1];
  return id && UUID.test(id) ? id : null;
}

/** How a move looks beside the others: the way forward, a way back, or a way out. */
export type TransitionTone = "forward" | "back" | "out";

const WAY_OUT = /^(cancel|void|withdraw|abandon|discard|scrap|terminate|write_?off)/;
// Expire is how a quotation ends unanswered: beside Convert to a sales order it
// was drawn as the dark button, as if it were the way on (J-76).
const WAY_BACK =
  /^(reject|decline|refuse|return|send_back|reopen|revert|recall|dispute|hold|expire)/;
const OUT_STATES = new Set([
  "cancelled",
  "canceled",
  "void",
  "voided",
  "withdrawn",
  "abandoned",
  "discarded",
  "terminated",
]);
const BACK_STATES = new Set([
  "rejected",
  "declined",
  "refused",
  "returned",
  "disputed",
  "on_hold",
  "expired",
]);

/**
 * Cancel sat beside Submit as a second dark primary button. A way out is
 * drawn as one, a way back as a plain button, and only the way forward is the
 * button the eye lands on.
 */
export function transitionTone(t: { code: string; to_state?: string | null }): TransitionTone {
  const code = t.code.toLowerCase();
  const to = (t.to_state ?? "").toLowerCase();
  if (WAY_OUT.test(code) || OUT_STATES.has(to)) return "out";
  if (WAY_BACK.test(code) || BACK_STATES.has(to)) return "back";
  return "forward";
}

const TONE_ORDER: Readonly<Record<TransitionTone, number>> = { forward: 0, back: 1, out: 2 };

/** The moves in the order they are drawn: forward first, the way out last. */
export function byTone<T extends { code: string; to_state?: string | null }>(
  moves: readonly T[],
): T[] {
  return moves
    .map((m, i) => ({ m, i, rank: TONE_ORDER[transitionTone(m)] }))
    .sort((a, b) => a.rank - b.rank || a.i - b.i)
    .map((x) => x.m);
}

// ─────────────────────────────────────────────────────────────────────────────
// Pickers and steps
// ─────────────────────────────────────────────────────────────────────────────

function shorten(value: string, max: number): string {
  return value.length > max ? `${value.slice(0, max - 1).trimEnd()}…` : value;
}

/**
 * A warehouse task as somebody on the floor says it: "FG-5000 Acme widget from
 * Goods in to Bulk store, 100" rather than "putaway — FG-5000 — RECV — BULK".
 * The kind leads only where a picker offers both kinds.
 */
export function describeWarehouseTask(row: Row, withKind = false): string {
  const item = [text(row, "item"), text(row, "item_name")]
    .filter((x): x is string => x !== null)
    .map((x, i) => (i === 1 ? shorten(x, 28) : x))
    .join(" ");
  const from = text(row, "from_location_name") ?? text(row, "from_location");
  const to = text(row, "to_location_name") ?? text(row, "to_location");
  const quantity = text(row, "quantity");
  let out = item === "" ? "Task" : item;
  if (from && to) out += ` from ${from} to ${to}`;
  else if (to) out += ` to ${to}`;
  else if (from) out += ` from ${from}`;
  if (quantity) out += `, ${quantity}`;
  const kind = text(row, "kind");
  return withKind && kind ? `${prettifyField(kind)}: ${out}` : out;
}

/** Today as the database writes a date, in the reader's own time zone. */
export function localIsoDate(now: Date = new Date()): string {
  const y = now.getFullYear();
  const m = String(now.getMonth() + 1).padStart(2, "0");
  const d = String(now.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

/**
 * The calendar quarter so far, as the dates a tax read asks for: the first day
 * of the quarter today falls in, and today. A VAT return covers a quarter, so
 * that is the period a person opening the tax report most often means.
 */
export function quarterToDate(now: Date = new Date()): { p_from: string; p_to: string } {
  const first = new Date(now.getFullYear(), Math.floor(now.getMonth() / 3) * 3, 1);
  return { p_from: localIsoDate(first), p_to: localIsoDate(now) };
}

/**
 * Where an accounting period stands for somebody closing the books.
 *
 *   0  the current period, the one today falls in
 *   1  an open period that has already ended, waiting to be closed
 *   2  a closed period, which may still be reopened
 *   3  a period that has not started yet
 *   4  a period of a year closed for good
 */
export function periodRank(row: Row, today: string): number {
  const status = text(row, "status") ?? "";
  const starts = text(row, "starts_on") ?? "";
  const ends = text(row, "ends_on") ?? "";
  if (status === "permanently_closed") return 4;
  if (status === "future" || (starts !== "" && starts > today)) return 3;
  if (starts !== "" && starts <= today && (ends === "" || today <= ends)) return 0;
  if (status === "closed") return 2;
  return 1;
}

/**
 * The Close step's periods, in the order they are worked.
 *
 * The door lists the calendar newest first, and a demonstration's calendar
 * runs a year ahead, so the step opened on December next year. It opens on
 * the current period, then the open periods that have ended, oldest first —
 * the next to close. Closed periods, latest first, periods not yet started
 * and years closed for good wait behind "Show future and finished", where
 * Reopen still reaches a closed one.
 *
 * The step counts what this returns, so a closed period is not work waiting:
 * the demonstration's Financials step read "Close 68", every closed month of
 * every ledger, while one month was open (J-98).
 */
export function orderPeriods<T extends Row>(
  rows: readonly T[],
  today: string,
  includeLater = false,
): T[] {
  return rows
    .map((row) => ({ row, rank: periodRank(row, today), starts: text(row, "starts_on") ?? "" }))
    .filter((x) => includeLater || x.rank < 2)
    .sort((a, b) => {
      if (a.rank !== b.rank) return a.rank - b.rank;
      const newestFirst = a.rank === 2 || a.rank === 4;
      const byDate = a.starts < b.starts ? -1 : a.starts > b.starts ? 1 : 0;
      if (byDate !== 0) return newestFirst ? -byDate : byDate;
      return (text(a.row, "ledger") ?? "").localeCompare(text(b.row, "ledger") ?? "");
    })
    .map((x) => x.row);
}

/**
 * What an approval task is for, as a person reads it: "PO-000057 · Purchase
 * order" for a document, and the kind of thing otherwise.
 */
export function approvalSubject(row: Row): string {
  const number = text(row, "document_number");
  const type = text(row, "document_type_name");
  if (number) return type ? `${number} · ${type}` : number;
  const kind = text(row, "object_type");
  return kind ? prettifyField(kind) : "—";
}

/**
 * An approval waiting on me, as its picker offers it: what it is for, who it is
 * with, what it is worth, and who asked — "PO-000143 · Purchase order — Anchor
 * Fasteners — £108.60 — Samuel Ogunjobi". The amount is what the approver
 * decides on, and the picker left it out (J-56).
 */
export function approvalChoice(row: Row): string {
  const value = text(row, "value_minor");
  const currency = text(row, "currency");
  const amount =
    value !== null && Number.isFinite(Number(value)) && currency
      ? formatMinor(Number(value), currency)
      : null;
  return [approvalSubject(row), text(row, "partner"), amount, text(row, "requested_by")]
    .filter((x): x is string => x !== null && x !== "" && x !== "—")
    .join(" — ");
}

/** The step of an approval, by its name, and by its code only as words. */
export function approvalStep(row: Row): string {
  const name = text(row, "step_name");
  const code = text(row, "step_code");
  if (name && name !== code) return name;
  return code ? prettifyField(code) : "—";
}
