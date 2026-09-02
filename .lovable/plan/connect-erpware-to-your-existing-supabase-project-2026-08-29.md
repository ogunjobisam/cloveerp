# Connect Clove ERP to your existing Supabase project

## Goal

Link the existing Clove ERP Supabase project (`xpzffnnhnhcqyjqcueja.supabase.co`) to this Lovable app so the preview stops showing "Not connected to a project" and the dashboard loads real tenant data.

## Current state

- `src/lib/erp.ts` already contains a Supabase client that reads `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY`, and a `callErp()` helper that talks to the database exclusively through the curated `public.erp_*` RPC functions (never raw tables).
- `src/components/erp/gate.tsx` renders the "Not connected to a project" screen only when those two variables are absent, then handles sign-in, tenant resolution (`erp_session` RPC), and the dashboard shell.
- The `VITE_`-prefixed variables cannot be set through the secrets tool — Lovable reserves them for the Cloud integration, so linking the project is the correct mechanism (and it also supplies the key to server-side code if needed later).

## Steps

1. **Link the existing project (you do this in the Lovable UI, ~1 minute)**
   - Open **Project Settings → Cloud** in the Lovable editor.
   - Choose **Connect existing Supabase project** (do NOT create a new project).
   - Enter the project URL `https://xpzffnnhnhcqyjqcueja.supabase.co` and the anon/publishable key from Supabase **Project Settings → API Keys** (the `anon public` key or `sb_publishable_...` key).
   - Complete the prompts. Lovable then injects `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY` into the build automatically — no code change needed for this step.

2. **Verify the connection (I do this)**
   - Reload the preview and confirm the "Not connected" screen is replaced by the **Sign in** screen, which proves the client is configured and can reach the project.
   - Confirm no environment/configuration errors in the browser console.

3. **Verify real data flows (I do this)**
   - Sign in with an account that has an ERP principal (if you don't have one yet, we create a test auth user plus its `erp.app_user` principal in your tenant first).
   - Confirm the `erp_session` RPC resolves the tenant, entities, sites, and permissions.
   - Open the dashboard and operations pages (`/operations/jobs`, `/operations/assurance`, `/operations/integrations`) and confirm they render real rows from the database, with screenshots as evidence.
   - If the RPC functions are missing from the linked project (error PGRST202), I'll report that the Clove ERP migrations haven't been applied to it and we'll apply them before re-verifying.

## Technical notes

- No frontend code changes are expected; the app is already written against this exact integration path. Any changes discovered during verification (e.g. key-format handling) will be minimal and confined to `src/lib/erp.ts`.
- The anon key is safe for the browser: access is enforced by your RLS policies and the `erp_*` functions, which is the design `erp.ts` already documents.
- Nothing in your Supabase project is modified by linking; only if migrations turn out to be missing would we apply schema (with your approval first).
