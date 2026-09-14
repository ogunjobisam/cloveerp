import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";
import { Tag } from "lucide-react";

import { callErp } from "../../lib/erp";
import type { PlatformRole } from "../../lib/platform";
import { Card, LINK_BUTTON } from "./kit";
import { SellingSetup, type CommercialState } from "./selling";

/**
 * What Clove ERP sells.
 *
 * The selling setup card lived at the top of Contracts, where it was the first
 * thing on a screen about something else. It belongs with the plans: both are
 * the catalogue, set up once and then left alone.
 */
export function SellingPage({ role }: { role: PlatformRole }) {
  // Cached: SellingSetup reads the same key, so naming the organisation costs
  // nothing.
  const state = useQuery({
    queryKey: ["erp_platform_commercial_state"],
    queryFn: () => callErp<CommercialState>("erp_platform_commercial_state"),
  });
  const platform = state.data?.platform_organisation ?? null;
  const where = platform ? (platform.name ?? platform.tenant_code) : "Clove ERP's own organisation";

  return (
    <div className="flex flex-col gap-5">
      <SellingSetup role={role} />
      <Card
        title="Changing a rate"
        icon={<Tag className="size-4 text-primary" />}
        description="Rates are not changed in the console."
      >
        <p className="text-sm text-muted-foreground">
          The price list is an ordinary price book inside {where}, so a rate is changed on the
          desk&rsquo;s Price book screen there, and the next quote uses it. If you are working in
          another organisation, switch to {where} from the account menu first.
        </p>
        <Link to="/commercial/price-book" className={`${LINK_BUTTON} mt-3`}>
          Open the Price book
        </Link>
      </Card>
    </div>
  );
}
