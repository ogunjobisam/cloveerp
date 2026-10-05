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
 * Pure, so it can be tested without a browser.
 */

export type PersonaPerson = {
  principal_id: string;
  display_name: string;
};

export type DemonstrationPersona = PersonaPerson & {
  code: string;
  roles: string[];
};

export type ActingAs = PersonaPerson & { chosen_at: string };

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
