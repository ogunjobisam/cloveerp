import {
  LabelRefused,
  LabelUnavailable,
  buyLabel,
  type LabelRequest,
} from "../../../src/lib/carriers/easypost.ts";
import type { TenantBinding, WorkerConfig } from "./config.ts";
import { asPrincipal, type Sql } from "./db.ts";

/**
 * Labels from the carriers' own systems (20261004965000): the shipment.buy
 * commands erp.request_carrier_label() queued when a shipment was booked with
 * a carrier linked to the organisation's EasyPost account.
 *
 * For every organisation the pass serves, not only those an operator named:
 * the endpoint is EasyPost's own, never one the organisation chose, and the
 * key is the organisation's, read from the vault at send time
 * (erp.carrier_api_key) and never logged. An organisation with no connected
 * account is skipped before anything is claimed.
 *
 * Shaped as drainCommands is: the mark goes to the database before the
 * request leaves, a "never" from EasyPost fails the command for good, a 5xx or
 * 429 keeps its attempts, and a request that left and got no answer is
 * ambiguous, for a person to settle, never bought twice.
 */

/** The systems this stage drains, and drainCommands therefore leaves alone. */
export const CARRIER_SYSTEMS = ["easypost"] as const;

export type CarrierCounts = {
  labelsClaimed: number;
  labelsBought: number;
  labelsFailed: number;
  labelsAmbiguous: number;
};

const BATCH = 10;

type Buy = typeof buyLabel;

/** One pass over one organisation's label requests. */
export async function drainCarrierLabels(
  sql: Sql,
  b: TenantBinding,
  cfg: Pick<WorkerConfig, "workerName" | "leaseSeconds" | "httpTimeoutMs">,
  out: CarrierCounts,
  deps: { buy?: Buy } = {},
): Promise<void> {
  const buy = deps.buy ?? buyLabel;
  for (const systemCode of CARRIER_SYSTEMS) {
    const [system] = await asPrincipal(
      sql,
      b,
      (tx) =>
        tx`select 1 from erp.external_system
            where tenant_id = ${b.tenantId}::uuid and code = ${systemCode} and status = 'active'`,
    );
    if (!system) continue;

    const claimed = await asPrincipal(
      sql,
      b,
      (tx) =>
        tx`select * from erp.claim_command_batch(${systemCode}, ${BATCH}, ${cfg.workerName},
                                               make_interval(secs => ${cfg.leaseSeconds}))`,
    );
    if (claimed.length === 0) continue;
    out.labelsClaimed += claimed.length;

    const [keyRow] = await asPrincipal(
      sql,
      b,
      (tx) => tx`select erp.carrier_api_key(${systemCode}) as key`,
    );
    const apiKey = typeof keyRow?.["key"] === "string" ? (keyRow["key"] as string) : null;

    for (const command of claimed) {
      const id = command["id"] as string;
      if (apiKey === null) {
        await asPrincipal(
          sql,
          b,
          (tx) =>
            tx`select erp.fail_command(${id}::uuid,
                  'the organisation''s carrier key could not be read from the vault; connect the account again',
                  true)`,
        );
        out.labelsFailed += 1;
        continue;
      }
      if (command["dry_run"] === true) {
        await asPrincipal(
          sql,
          b,
          (tx) => tx`select erp.complete_command(${id}::uuid, '{"simulated": true}'::jsonb)`,
        );
        continue;
      }
      let sent = false;
      try {
        await asPrincipal(sql, b, (tx) => tx`select erp.mark_command_sent(${id}::uuid)`);
        sent = true;
        const label = await buy(command["payload"] as LabelRequest, apiKey, {
          timeoutMs: cfg.httpTimeoutMs,
        });
        const result = JSON.parse(JSON.stringify(label)) as Record<string, unknown>;
        await asPrincipal(sql, b, async (tx) => {
          await tx`select erp.apply_carrier_label(${id}::uuid, ${tx.json(result as never)})`;
          await tx`select erp.complete_command(${id}::uuid, ${tx.json(result as never)})`;
        });
        out.labelsBought += 1;
      } catch (err) {
        const message = String((err as Error).message);
        if (sent && err instanceof LabelUnavailable && !err.answered) {
          await asPrincipal(
            sql,
            b,
            (tx) => tx`select erp.mark_command_ambiguous(${id}::uuid, ${message})`,
          );
          out.labelsAmbiguous += 1;
          continue;
        }
        const permanent = err instanceof LabelRefused;
        await asPrincipal(
          sql,
          b,
          (tx) => tx`select erp.fail_command(${id}::uuid, ${message}, ${!permanent})`,
        );
        out.labelsFailed += 1;
      }
    }
  }
}
