# Clove ERP — Product & Capabilities Report (document)

Generate a polished, board-grade DOCX document — **"Clove ERP — Product & Capabilities Report, 30 August 2026"** — written for the platform owner / product director, and deliver it to `/mnt/documents` as a chat attachment.

## Content outline

1. **Cover & executive summary** — what Clove ERP is, who it's for, headline numbers (~45 migrations, 170+ curated RPCs, 23 UI routes, 6 configuration surfaces).
2. **Platform control plane** — Owner/Operator/Support roles, invitation-based onboarding, ownership transfer, audited cross-tenant access, tenant lifecycle (suspend, per-tenant encryption keys, irreversible key destruction).
3. **Module-by-module capabilities** — journey order (Plan → Source → Make → Move → Sell → Settle) plus Governance and Administration; each with features, RPC-backed flows, dashboards/KPIs, and record pickers.
4. **Addendum B configuration surfaces** — departments & approval routing (bands, delegation, substitution, stamped rule versions), account determination (no suspense fallback, coverage assertions), classification & code templates, default suppliers & release areas (print gating with shortfall reasons).
5. **Architecture & engineering** — database-as-product, RLS + audited RPC boundary, audit log/event outbox, change sets, worker/dispatch model, resource-key i18n, friendly errors, per-tenant branding.
6. **Security & compliance posture** — Vault-backed keys, append-only audit, reviewed SECURITY DEFINER boundaries, UK-centric compliance framing.
7. **Verification status** — typecheck/build/lint clean, authenticated route sweeps, self-check assertion suite.
8. **Honest gaps & roadmap** — remaining lint findings, demo data depth, resource-key coverage, ~80 API-only RPCs, AI-assisted setup as the next major feature.

## Design

- Match project brand: slate (#3F3A34) headings, amber (#C2703D) accents, warm paper (#F7F5F1) shading on key panels; Arial body (DOCX-safe), black titles.
- Use the Clove ERP wordmark on the cover and the three existing product screenshots (finance, warehouse, encryption panel) in relevant sections.
- Numbered headings, tables for module/feature matrices, bulleted capability lists, footer with page numbers.

## Technical

- Build with docx-js (skill workflow), US Letter portrait, explicit page size, DXA table widths, numbering config for bullets.
- Validate the DOCX, convert to PDF, render every page to an image and inspect all pages; fix layout issues and re-run until clean.
- Deliver: `ERPWare_Product_Capabilities_Report.docx` in `/mnt/documents` with a presentation-artifact tag.
