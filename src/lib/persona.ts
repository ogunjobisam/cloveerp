/**
 * Acting as a demonstration's other person (J-46).
 *
 * A demonstration has a second person, Priya Shah of Finance, who cannot sign
 * in. A visitor who may give people roles chooses her under "Act as" in the
 * account menu, and the database then answers her as the one acting: what the
 * visitor does is recorded as hers, and a step that needs two people — a
 * payment run proposed by one and approved by another — can be shown. The
 * database refuses everything here outside a demonstration; this only reads
 * what public.erp_demonstration_personas() says.
 *
 * The choice belongs to the browser tab that made it. The tab keeps it in its
 * own sessionStorage, so it ends when the tab closes, and names her in the
 * `x-clove-act-as` header of every request it makes to the database. Another
 * tab, or another device, sends no header and is the person who signed in.
 * The header asks; the database decides (erp.principal_context), and answers
 * as the person whenever the header names somebody it may not.
 *
 * Pure, so it can be tested without a browser.
 */

/** The request header naming whom this tab acts as. PostgREST hands it to SQL in request.headers. */
export const ACT_AS_HEADER = "x-clove-act-as";

/** Where the tab keeps whom it acts as: sessionStorage, which is the tab's own. */
export const ACT_AS_KEY = "clove.act-as";

/** Beside it, the sign-in that chose: a choice is never carried over to somebody else. */
export const ACT_AS_BY_KEY = "clove.act-as.by";

/** The part of Storage this needs, so a test can pass a plain object. */
export type TabStore = Pick<Storage, "getItem" | "setItem" | "removeItem">;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Whom this tab acts as, or null for the person who signed in. Anything not an id is nobody. */
export function readTabPersona(store: TabStore | null | undefined): string | null {
  if (!store) return null;
  try {
    const value = store.getItem(ACT_AS_KEY);
    return value && UUID.test(value) ? value : null;
  } catch {
    // Storage blocked: the tab acts as the person who signed in.
    return null;
  }
}

/**
 * Keep whom this tab acts as, and which sign-in chose her, or forget both with
 * null.
 */
export function writeTabPersona(
  store: TabStore | null | undefined,
  personaId: string | null,
  chosenBy: string | null = null,
): void {
  if (!store) return;
  try {
    if (personaId && UUID.test(personaId)) {
      store.setItem(ACT_AS_KEY, personaId);
      if (chosenBy) store.setItem(ACT_AS_BY_KEY, chosenBy);
      else store.removeItem(ACT_AS_BY_KEY);
    } else {
      store.removeItem(ACT_AS_KEY);
      store.removeItem(ACT_AS_BY_KEY);
    }
  } catch {
    // Storage blocked: nothing is kept, and the tab acts as the person.
  }
}

/**
 * The sign-in this tab now holds. A choice made under another sign-in, or
 * under none that was recorded, is forgotten: whoever signs in next in this
 * tab is themselves until they choose.
 */
export function keepTabPersonaFor(store: TabStore | null | undefined, userId: string | null): void {
  if (!store) return;
  try {
    if (store.getItem(ACT_AS_KEY) === null) return;
    if (!userId || store.getItem(ACT_AS_BY_KEY) !== userId) writeTabPersona(store, null);
  } catch {
    // Storage blocked: nothing was kept.
  }
}

/**
 * Whether a request goes to the database's REST interface, the only place the
 * header is sent. The Edge Functions answer a preflight that lists the
 * headers they allow, and this is not one of them.
 */
export function isDatabaseRequest(target: string, projectUrl: string): boolean {
  return target.startsWith(`${projectUrl.replace(/\/+$/, "")}/rest/v1/`);
}

/** The request's headers, naming whom the tab acts as. */
export function withActAs(headers: HeadersInit | undefined, personaId: string): Headers {
  const out = new Headers(headers);
  out.set(ACT_AS_HEADER, personaId);
  return out;
}

export type PersonaPerson = {
  principal_id: string;
  display_name: string;
};

export type DemonstrationPersona = PersonaPerson & {
  code: string;
  roles: string[];
};

export type ActingAs = PersonaPerson;

/** What public.erp_demonstration_personas() answers. */
export type DemonstrationPersonas = {
  is_demonstration: boolean;
  signed_in: PersonaPerson | null;
  acting_as: ActingAs | null;
  personas: DemonstrationPersona[];
};

/** One line of the menu: yourself (persona null) or one of the people. */
export type PersonaChoice = {
  persona_id: string | null;
  name: string;
  roles: string[];
  current: boolean;
};

/**
 * The menu's lines: yourself first, then each person you may act as with the
 * roles they hold, the one in force marked. Nothing when there is nobody to
 * act as, so the menu shows no section at all.
 */
export function personaChoices(
  data: DemonstrationPersonas | null | undefined,
  yourself: string,
): PersonaChoice[] {
  const personas = data?.personas ?? [];
  if (personas.length === 0) return [];
  const acting = data?.acting_as?.principal_id ?? null;
  return [
    {
      persona_id: null,
      name: data?.signed_in?.display_name
        ? `${yourself} (${data.signed_in.display_name})`
        : yourself,
      roles: [],
      current: acting === null,
    },
    ...personas.map((p) => ({
      persona_id: p.principal_id,
      name: p.display_name,
      roles: p.roles ?? [],
      current: acting === p.principal_id,
    })),
  ];
}

/** Who is being acted as, or null when the person who signed in acts as themselves. */
export function actingAs(data: DemonstrationPersonas | null | undefined): ActingAs | null {
  const a = data?.acting_as ?? null;
  if (!a) return null;
  if (data?.signed_in && data.signed_in.principal_id === a.principal_id) return null;
  return a;
}
