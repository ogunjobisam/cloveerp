import { createFileRoute } from "@tanstack/react-router";
import { useState } from "react";

import { PermissionNote } from "../../components/erp/action";
import { Gate } from "../../components/erp/gate";
import { PageHeader, Prose, TOUCH } from "../../components/erp/page";
import { useErpSession } from "../../components/erp/session-context";
import { Acceptance } from "../../components/packs/acceptance";
import { Capabilities } from "../../components/packs/capabilities";
import { Packs } from "../../components/packs/packs";
import { hasPermission } from "../../lib/erp";
import { useT } from "../../lib/i18n";

/**
 * Features and content, in the order somebody actually works through them.
 *
 * Readiness first, because it answers "what can this organisation not do yet?"
 * and every answer it gives points at one of the two tabs below it. Then
 * features, because a pack's contents depend on which are on. Then packs.
 *
 * Nothing on this screen promotes. Preparing a change and landing it are
 * separate acts with separate permissions, and Configuration is where the
 * second one lives.
 */

export const Route = createFileRoute("/administration/packs")({
  head: () => ({
    meta: [
      { title: "Features and content — ERPWare" },
      {
        name: "description",
        content:
          "Switch product features on and off, apply starter content packs, and see what this organisation is not yet able to do.",
      },
      { property: "og:title", content: "Features and content — ERPWare" },
      {
        property: "og:description",
        content: "Features, content packs, and what is still missing.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: () => (
    <Gate>
      <PacksScreen />
    </Gate>
  ),
});

const TABS = [
  { key: "features", label: "Features" },
  { key: "packs", label: "Content packs" },
] as const;

type TabKey = (typeof TABS)[number]["key"];

function PacksScreen() {
  const { t, ui } = useT();
  const { session } = useErpSession();
  const mayConfigure = hasPermission(session, "administration.configure");
  const [tab, setTab] = useState<TabKey>("features");

  return (
    <div className="flex min-w-0 flex-col gap-6">
      <PageHeader title={t("module.packs", "Features and content")}>
        Content arrives switched off until it is wanted. A feature decides three things at once —
        the navigation somebody sees, the fields a form shows, and the rules the engine evaluates —
        so switching one off is not merely hiding it: its rules stop running. That is why one with
        live data behind it cannot be switched off at all.
      </PageHeader>

      {mayConfigure ? null : <PermissionNote code="administration.configure" />}

      <Acceptance />

      <div className="flex flex-wrap gap-2" role="tablist" aria-label="Features and content">
        {TABS.map((x) => (
          <button
            key={x.key}
            type="button"
            role="tab"
            aria-selected={tab === x.key}
            className={`${TOUCH} rounded-md px-4 text-sm font-medium ${
              tab === x.key
                ? "bg-primary text-primary-foreground"
                : "border border-input text-muted-foreground"
            }`}
            onClick={() => setTab(x.key)}
          >
            {ui(x.label)}
          </button>
        ))}
      </div>

      {tab === "features" ? (
        <Capabilities mayConfigure={mayConfigure} />
      ) : (
        <Packs mayConfigure={mayConfigure} />
      )}

      <Prose className="text-xs text-muted-foreground">
        Once this organisation has gone live, a feature switch and a pack both prepare a change
        rather than taking effect immediately. That is deliberate: what the rules do is
        configuration, and configuration moves through promotion so that there is a diff to read and
        a point to roll back to.
      </Prose>
    </div>
  );
}
