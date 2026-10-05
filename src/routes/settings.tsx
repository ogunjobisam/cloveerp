import { createFileRoute } from "@tanstack/react-router";

import { Gate } from "../components/erp/gate";
import { SettingsLaunchpad } from "../components/erp/launchpad";
import { SetupOverview } from "../components/erp/walkthrough";
import { PageHeader } from "../components/erp/page";
import { useErpSession } from "../components/erp/session-context";
import { hasPermission } from "../lib/erp";
import { useT } from "../lib/i18n";

/**
 * The Settings area's home.
 *
 * Everything that shapes the organisation rather than runs it, in the order it
 * is set up: the people, the system they work in, the products and places they
 * work on, where it posts to, what it is joined to, and the evidence over all
 * of it. It is a separate area from the work on purpose: an administrator
 * reads this page top to bottom, and nobody doing the day's work has these
 * screens in their way.
 *
 * The page is one list. Whoever configures the organisation gets the setup
 * order: every screen in the order it is set up, how far along, what is next,
 * and any Settings screen the order does not name. Everybody else gets the
 * launchpad's sections. erp_setup_progress refuses anybody without
 * administration.configure, so for them it is not asked at all rather than
 * drawn as a refusal. Hiding it is the convenience; the refusal is the
 * database's.
 *
 * While the order is being read, when the read fails, or when it answers
 * nothing, the launchpad stands in for it: the page is never blank, and an
 * administrator never waits on that read to reach a screen.
 */

export const Route = createFileRoute("/settings")({
  head: () => ({ meta: [{ title: "Settings — Clove ERP" }] }),
  component: () => (
    <Gate>
      <Settings />
    </Gate>
  ),
});

function Settings() {
  const { t, ui } = useT();
  const { session } = useErpSession();
  const mayConfigure = hasPermission(session, "administration.configure");

  return (
    <div className="flex min-w-0 flex-col gap-8">
      <PageHeader
        title={t("nav.settings", "Settings")}
        howItWorks={ui(
          "Start at the top and work down. Nothing here is needed to get the day's work done.",
        )}
      >
        {ui("How this organisation is set up, in the order you would set it up.")}{" "}
        {session.tenant?.name ?? ""}
      </PageHeader>

      {mayConfigure ? <SetupOverview fallback={<SettingsLaunchpad />} /> : <SettingsLaunchpad />}
    </div>
  );
}
