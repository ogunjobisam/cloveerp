import { ActionButton, ErrorNote } from "./action";
import { useErpAction } from "./action";
import { useErpSession } from "./gate";

/**
 * One button, one function call, one honest failure.
 *
 * Distinct from ActionDialog because these actions have nothing to ask: an
 * approval decision, a submission, a rollback. The permission check is the
 * same one the database will make, done early only so the button can explain
 * itself rather than fail after the click.
 */
export function RpcButton({
  label,
  fn,
  args = {},
  permission,
  invalidates,
  variant = "secondary",
  confirm,
}: {
  label: string;
  fn: string;
  args?: Record<string, unknown>;
  permission?: string;
  invalidates: string[];
  variant?: "primary" | "secondary";
  confirm?: string;
}) {
  const { session } = useErpSession();
  const action = useErpAction({ fn, invalidates });

  const allowed = !permission || (session?.permissions ?? []).includes(permission);

  return (
    <span className="inline-flex flex-col gap-1">
      <ActionButton
        variant={variant}
        busy={action.isPending}
        disabled={!allowed}
        title={allowed ? undefined : `Requires ${permission}`}
        onClick={() => {
          if (confirm && !window.confirm(confirm)) return;
          action.mutate(args);
        }}
      >
        {label}
      </ActionButton>
      {action.error ? <ErrorNote error={action.error} /> : null}
    </span>
  );
}
