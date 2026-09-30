import { Navigate, createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";

import { Centred, Gate, SignIn } from "../components/erp/gate";
import { NotFoundComponent } from "../components/erp/not-found";
import { callErp, isConfigured } from "../lib/erp";
import { addressPath, addressShaped, readAddressLookup } from "../lib/tenant-address";

/**
 * An organisation's own way in: cloveerp.com/acme.
 *
 * Every other route is static and wins over this one, so /sales is the sales
 * area and never an organisation called "sales" — the database reserves every
 * top-level route name, and supabase/ci/app_addresses.sh fails the build when
 * a route is added that it does not.
 *
 * What an address does is small on purpose. Signed out, it puts the
 * organisation's name on the sign-in form. Signed in, it opens the desk — the
 * desk of whichever organisation the account belongs to, which is decided by
 * current_tenant_id() and never by this path. Somebody who opens another
 * organisation's address and signs in lands in their own.
 *
 * An address the organisation has since renamed answers with the new one, so
 * a bookmark or a printed link keeps working. An address nobody holds is a
 * page that does not exist.
 */

export const Route = createFileRoute("/$address")({
  head: () => ({
    meta: [
      { title: "Sign in — Clove ERP" },
      // An organisation's door, not a page for a search to find.
      { name: "robots", content: "noindex, nofollow" },
    ],
  }),
  component: AddressPage,
});

function AddressPage() {
  const { address } = Route.useParams();
  const code = address.toLowerCase();
  const shaped = addressShaped(code);

  const lookup = useQuery({
    queryKey: ["erp_tenant_by_address", code],
    queryFn: async () =>
      readAddressLookup(await callErp<unknown>("erp_tenant_by_address", { p_code: code })),
    enabled: isConfigured && shaped,
    staleTime: 5 * 60_000,
  });

  if (!isConfigured || !shaped) return <NotFoundComponent />;

  if (lookup.isPending) {
    return (
      <Centred>
        <p role="status" className="text-sm text-muted-foreground">
          Finding {code}…
        </p>
      </Centred>
    );
  }

  // A failed lookup and an address nobody holds read the same to a visitor,
  // on purpose: neither has anything to offer but the way home.
  const found = lookup.data ?? null;
  if (found === null) return <NotFoundComponent />;

  // Renamed since, or typed in capitals: the organisation's address as it is.
  if (found.code !== address) {
    return <Navigate to="/$address" params={{ address: found.code }} replace />;
  }

  return (
    <Gate
      bare
      signedOut={<SignIn organisation={found.name} returnPath={addressPath(found.code)} />}
    >
      <Navigate to="/" replace />
    </Gate>
  );
}
