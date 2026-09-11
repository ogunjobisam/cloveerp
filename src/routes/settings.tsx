import { createFileRoute } from "@tanstack/react-router";

import { Gate } from "../components/erp/gate";
import { SettingsLaunchpad } from "../components/erp/launchpad";
import { PageHeader } from "../components/erp/page";
import { useErpSession } from "../components/erp/session-context";
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

  return (
    <div className="flex min-w-0 flex-col gap-8">
      <PageHeader title={t("nav.settings", "Settings")}>
        {ui(
          "How this organisation is set up, in the order you would set it up. Start at the top and work down; nothing here is needed to get the day's work done.",
        )}{" "}
        {session.tenant?.name ?? ""}
      </PageHeader>

      <SettingsLaunchpad />
    </div>
  );
}
