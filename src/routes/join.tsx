import { Navigate, createFileRoute, useNavigate } from "@tanstack/react-router";
import { useEffect, useState } from "react";

import { Gate } from "../components/erp/gate";
import { supabase } from "../lib/erp";
import {
  clearStoredInvitation,
  readStoredInvitation,
  storeInvitation,
} from "../lib/invitation-token";

/**
 * Where an invitation email lands.
 *
 * The link carries the token in its query. This page keeps it for the tab
 * (lib/invitation-token.ts), takes it back out of the address bar, and puts
 * the person through the ordinary gate: signed out, they sign in with the
 * address the invitation went to; signed in with no organisation, the
 * onboarding screen redeems it; already inside one, they go to their desk.
 *
 * The one-click link in the email signs them in on the way here, through
 * Supabase Auth, which appends the session to the address. The client reads
 * that as it starts, so the token is only removed from the address once it
 * has — removing it sooner would take the session with it.
 */

type JoinSearch = { token?: string };

export const Route = createFileRoute("/join")({
  validateSearch: (search: Record<string, unknown>): JoinSearch => {
    const token = search["token"];
    return typeof token === "string" && token !== "" ? { token } : {};
  },
  head: () => ({
    meta: [
      { title: "Join your organisation — Clove ERP" },
      {
        name: "description",
        content: "Accept an invitation to an organisation on Clove ERP.",
      },
      // A private door with a secret in its address: never indexed, and never
      // named to another site in a Referer header.
      { name: "robots", content: "noindex, nofollow" },
      { name: "referrer", content: "no-referrer" },
    ],
  }),
  component: JoinPage,
});

function JoinPage() {
  const { token } = Route.useSearch();
  const navigate = useNavigate();

  // Supabase Auth reports a link that expired or was already used in the
  // address fragment. Read on the first client render, before anything tidies
  // the address; shown only once the gate knows the person is signed out.
  const [linkFailed] = useState(
    () =>
      typeof window !== "undefined" &&
      /(?:^|[#&])error(?:_code|_description)?=/.test(window.location.hash),
  );

  useEffect(() => {
    if (!token) return;
    storeInvitation(token);
    let cancelled = false;
    const ready = supabase ? supabase.auth.getSession() : Promise.resolve(null);
    void ready
      .catch(() => null)
      .then(() => {
        if (!cancelled) void navigate({ to: "/join", search: {}, replace: true });
      });
    return () => {
      cancelled = true;
    };
  }, [token, navigate]);

  return (
    <Gate signIn={{ notice: <Invited linkFailed={linkFailed} />, returnPath: "/join" }}>
      <AlreadyInside />
    </Gate>
  );
}

function Invited({ linkFailed }: { linkFailed: boolean }) {
  const holding = readStoredInvitation() !== null;
  return (
    <div className="mb-4 rounded-xl border border-primary/40 bg-primary/5 p-4 text-sm">
      {holding ? (
        <>
          <p className="font-medium">You have been invited to Clove ERP.</p>
          <p className="mt-1 text-muted-foreground">
            Sign in with the address the invitation was sent to, and you will be brought into the
            organisation.
          </p>
        </>
      ) : (
        <p className="text-muted-foreground">
          This page accepts an invitation. Open the link in your invitation email again, or sign in
          and paste the token you were given.
        </p>
      )}
      {linkFailed ? (
        <p className="mt-2 text-muted-foreground">
          The sign-in link in the email has expired or was already used. Sign in below if this
          address already has a password or a Google account; otherwise ask whoever invited you to
          send the invitation again.
        </p>
      ) : null}
    </div>
  );
}

/**
 * Signed in and already inside an organisation.
 *
 * A sign-in belongs to one principal, so an invitation cannot move it into a
 * second organisation; the held token is dropped rather than left for whoever
 * next signs in on this tab.
 */
function AlreadyInside() {
  useEffect(() => {
    clearStoredInvitation();
  }, []);
  return <Navigate to="/" replace />;
}
