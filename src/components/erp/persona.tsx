import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Check, UserRound } from "lucide-react";

import {
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
} from "@/components/ui/dropdown-menu";

import { callErp } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { actingAs, personaChoices, type DemonstrationPersonas } from "../../lib/persona";
import { TOUCH } from "./page";

/**
 * Acting as a demonstration's other person (J-46).
 *
 * The database decides everything here: who may be acted as, who may choose,
 * and that it happens only in a demonstration. This reads its answer and
 * offers the choice. Once the person acting changes, every query is reset
 * rather than refreshed, so no screen goes on showing the other person's
 * approvals or permissions while it reloads.
 */
function usePersonas() {
  return useQuery({
    queryKey: ["erp_demonstration_personas"],
    queryFn: () => callErp<DemonstrationPersonas>("erp_demonstration_personas"),
    retry: false,
  });
}

function useActAs() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (personaId: string | null) =>
      callErp<DemonstrationPersonas>("erp_act_as_persona", { p_persona_id: personaId }),
    onSuccess: () => queryClient.resetQueries(),
  });
}

/** The account menu's "Act as", shown only where there is somebody to act as. */
export function PersonaMenuSection() {
  const { ui } = useT();
  const personas = usePersonas();
  const act = useActAs();
  const choices = personaChoices(personas.data, ui("Yourself"));
  if (choices.length === 0) return null;

  return (
    <>
      <DropdownMenuSeparator />
      <DropdownMenuLabel className="flex flex-col gap-0.5">
        <span className="text-[11px] uppercase tracking-wide text-muted-foreground">
          {ui("Act as")}
        </span>
        <span className="text-xs font-normal text-muted-foreground">
          {ui("For a step that needs a second person.")}
        </span>
      </DropdownMenuLabel>
      {choices.map((choice) => (
        <DropdownMenuItem
          key={choice.persona_id ?? "yourself"}
          disabled={act.isPending || choice.current}
          onSelect={() => {
            if (!choice.current) act.mutate(choice.persona_id);
          }}
          className="gap-2"
        >
          <Check className={`size-4 shrink-0 ${choice.current ? "opacity-100" : "opacity-0"}`} />
          <span className="flex min-w-0 flex-col">
            <span className="truncate">{choice.name}</span>
            {choice.roles.length > 0 ? (
              <span className="truncate text-xs text-muted-foreground">
                {choice.roles.join(" · ")}
              </span>
            ) : null}
          </span>
        </DropdownMenuItem>
      ))}
    </>
  );
}

/** Says who is acting, under the header, for as long as it is somebody else. */
export function PersonaBanner() {
  const { ui } = useT();
  const personas = usePersonas();
  const act = useActAs();
  const acting = actingAs(personas.data);
  if (!acting) return null;

  return (
    <div role="status" aria-live="polite" className="border-b border-border bg-card">
      <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-3 px-4 py-2 text-sm">
        <UserRound className="size-4 shrink-0 text-muted-foreground" aria-hidden />
        <span className="min-w-0 flex-1">
          <span className="font-medium">
            {ui("Acting as")} {acting.display_name}
          </span>
          <span className="text-muted-foreground">
            {" · "}
            {ui("What you do now is recorded as theirs.")}
          </span>
        </span>
        <button
          type="button"
          disabled={act.isPending}
          onClick={() => act.mutate(null)}
          className={`${TOUCH} shrink-0 rounded-md border border-border px-3 text-sm hover:bg-muted`}
        >
          {ui("Back to yourself")}
        </button>
      </div>
    </div>
  );
}
