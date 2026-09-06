import { createFileRoute, useNavigate } from "@tanstack/react-router";

import { SignIn } from "../components/erp/gate";

/**
 * Signing in, as a place rather than a state.
 *
 * The root used to be both the front door and the desk: a visitor who had
 * never heard of Clove ERP arrived at a password box, and on a build with no
 * project configured, at a message naming two environment variables. The root
 * is the product now, and this is where the people who work here come in.
 *
 * The screen itself is the one `Gate` renders — the same form, the same
 * Google button — so there is one sign-in to maintain. A deep link into a
 * gated route still prompts in place, because sending somebody to `/signin`
 * and then back again loses where they were going.
 */

export const Route = createFileRoute("/signin")({
  head: () => ({
    meta: [
      { title: "Sign in — Clove ERP" },
      {
        name: "description",
        content: "Sign in to Clove ERP. Your organisation is derived from your account.",
      },
      // Not a page to arrive at from a search: it is a door, and the product
      // page is what a search should find.
      { name: "robots", content: "noindex, follow" },
    ],
    links: [{ rel: "canonical", href: "https://cloveerp.com/signin" }],
  }),
  component: SignInPage,
});

function SignInPage() {
  const navigate = useNavigate();
  return <SignIn onSignedIn={() => void navigate({ to: "/" })} />;
}
