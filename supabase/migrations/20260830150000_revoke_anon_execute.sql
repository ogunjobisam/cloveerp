-- Take the grant back on a database that already applied the earlier version.
--
-- 20260830140000 created public.erp_create_party_with_roles and revoked it
-- `from public` alone. On a Supabase project that leaves the execute grant anon
-- holds by default, so an unauthenticated caller could reach it. That file has
-- since been corrected, which is enough for anything built from empty — CI, and
-- any project the migrations are applied to in order.
--
-- It is not enough for a database that already ran the earlier version. The
-- Supabase preview branch attached to this pull request is exactly that: it
-- applies new migration files incrementally and does not re-run one whose text
-- has changed underneath it, which it says plainly in its own status comment.
-- So the preview holds a function with a grant that no file in the repository
-- describes any more.
--
-- Editing 20260830140000 in place was the mistake, and it is the same one that
-- file itself calls out two sections earlier when it redefines a suite rather
-- than amending the migration that declared it: a migration that has run is
-- history, and "unmerged" is not the same as "unapplied". A correction to
-- something already applied belongs in a new file, so that every database
-- reaches the same state by moving forward.
--
-- Idempotent, and a no-op on a database built from empty, where the corrected
-- 20260830140000 has already revoked it.

revoke all on function public.erp_create_party_with_roles(text, text, text[], text, text)
  from public, anon;

grant execute on function public.erp_create_party_with_roles(text, text, text[], text, text)
  to authenticated;

select erp.assert_public_api_safe();
