/**
 * Where enquiry notifications go, as the console reads it.
 *
 * The contact form's recipients used to be whoever held platform owner, which
 * tied answering a sales lead to holding the keys to the console. They are now
 * the enquiry.notify_to platform setting, and the owners are the fallback when
 * no address is set — so there are two lists worth showing, and they differ
 * exactly when nobody has set one.
 *
 * The database refuses regardless: public.erp_platform_set_enquiry_notify_to
 * checks for an owner on its first line and refuses an address that cannot be
 * one by name. What is decided here is only what the screen says before the
 * round trip.
 *
 * Pure, so it can be tested without a browser. Nothing here imports the
 * Supabase client.
 */

/** What the two notification doors return. */
export type EnquiryNotify = {
  /** The addresses an owner set. Empty when none is set. */
  configured: string[];
  /** Where the next enquiry actually goes — the fallback, when none is set. */
  recipients: string[];
  /** True when nothing is set and the platform owners are being told. */
  fallsBackToOwners: boolean;
  reason: string | null;
  updatedAt: string | null;
};

function strings(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.filter((v): v is string => typeof v === "string" && v.trim() !== "");
}

/**
 * The answer both doors give, read strictly.
 *
 * An older schema without the doors, an error, or any other payload reads as
 * null, and the screen says it cannot tell rather than claiming an empty list.
 * Claiming empty would read as "enquiries reach nobody", which is the one thing
 * this screen must never say when it does not know.
 */
export function readEnquiryNotify(answer: unknown): EnquiryNotify | null {
  if (typeof answer !== "object" || answer === null || Array.isArray(answer)) return null;
  const row = answer as Record<string, unknown>;
  if (!Array.isArray(row["recipients"])) return null;

  const reason = row["reason"];
  const updated = row["updated_at"];
  const configured = strings(row["configured"]);

  return {
    configured,
    recipients: strings(row["recipients"]),
    // Trust the database's own answer when it gave one; fall back to the shape
    // of the lists, which say the same thing.
    fallsBackToOwners:
      typeof row["falls_back_to_owners"] === "boolean"
        ? row["falls_back_to_owners"]
        : configured.length === 0,
    reason: typeof reason === "string" && reason.trim() !== "" ? reason : null,
    updatedAt: typeof updated === "string" && updated !== "" ? updated : null,
  };
}

/**
 * The addresses somebody typed, as a list to send.
 *
 * Split on commas, semicolons and whitespace, because a list of addresses gets
 * pasted out of a mail client as often as it gets typed, and the separator it
 * arrives with is not the typist's choice. Duplicates are dropped and case is
 * left alone: the local part of an address is case-sensitive by the spec, and
 * deciding otherwise is the mail provider's business, not this form's.
 *
 * An empty result is meaningful — it clears the setting, which sends enquiries
 * back to the platform owners — so it is not an error here.
 */
export function readAddressList(typed: string): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const part of typed.split(/[\s,;]+/)) {
    const address = part.trim();
    if (address === "" || seen.has(address)) continue;
    seen.add(address);
    out.push(address);
  }
  return out;
}

/**
 * Whether an address is worth a round trip.
 *
 * Deliberately the same shape check the database applies, and no more. What
 * makes an address real is that a message reaches it; this only catches what
 * obviously cannot be one, so the person typing hears it before the door does.
 */
export function looksLikeAddress(address: string): boolean {
  return /^[^@\s]+@[^@\s]+\.[a-zA-Z]{2,}$/.test(address.trim());
}

/** The typed addresses that cannot be addresses, for the message under the field. */
export function rejectedAddresses(typed: string): string[] {
  return readAddressList(typed).filter((a) => !looksLikeAddress(a));
}
