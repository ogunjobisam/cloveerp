import { ActionButton, ErrorNote } from "./action";
import { useErpAction } from "./action";
import { hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";
import { permissionName } from "../../lib/permission-name";
import { useErpSession } from "./session-context";

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
  const { resources } = useT();

  const allowed = !permission || hasPermission(session, permission);

  return (
    <span className="inline-flex flex-col gap-1">
      <ActionButton
        variant={variant}
        busy={action.isPending}
        disabled={!allowed}
        title={
          allowed || !permission ? undefined : `Requires ${permissionName(permission, resources)}`
        }
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
