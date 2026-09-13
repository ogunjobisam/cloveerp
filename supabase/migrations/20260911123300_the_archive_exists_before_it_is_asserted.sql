-- The archive exists before it is asserted.
--
-- 20260911123400 ends with erp.assert_document_archive_sound(), which refuses
-- a database with no document-output bucket. On the build's own cluster that
-- bucket is inserted by supabase/ci/00_host_bootstrap.sql before the first
-- migration runs, so the build never saw the problem. Every Supabase host
-- does it the other way round: `supabase start`, a preview branch and a fresh
-- project all apply the migrations first and create the buckets config.toml
-- declares afterwards. So on every one of them the replay died at that file:
--
--   ERROR: ERPWARE_DOCUMENT_ARCHIVE_MISSING: the private document archive
--   does not exist (SQLSTATE P0001)
--
-- on every push to main since 8 September in the typescript job, and on the
-- preview branch of every pull request since 11 September, whose migration
-- history stopped at 20260911114004 for that reason.
--
-- A migration is written once, so 20260911123400 keeps its assertion. This
-- file sorts immediately before it and provides what the host would have
-- provided later: the same bucket, with the same three properties the
-- assertion checks and config.toml declares. It sorts out of order on purpose
-- — the build replays in full once for that, and deploy.yml applies with
-- --include-all so it reaches live too, where the Storage API made the bucket
-- long ago and this does nothing.
--
-- Nothing on conflict, deliberately. The bucket is the host's: where the host
-- has already made it, this must not rewrite it, and where the host makes it
-- later from config.toml it finds the same three properties waiting. The
-- assertion one file on is what refuses a bucket that is public, unlimited or
-- open to a browser role; this only makes sure there is one to assert.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('document-output', 'document-output', false, 20971520, array['application/pdf']::text[])
on conflict (id) do nothing;

-- The proof this file can give: the row is there, in the shape the next file
-- will insist on. erp.assert_document_archive_sound() itself does not exist
-- until 20260911123400 defines it.
do $archive$
begin
  if not exists (
    select 1 from storage.buckets b
     where b.id = 'document-output'
       and not b.public
       and b.file_size_limit = 20971520
       and b.allowed_mime_types = array['application/pdf']::text[]) then
    raise exception 'ERPWARE_DOCUMENT_ARCHIVE_MISSING: the private document archive does not exist, or is not private, PDF-only and limited to 20 MiB';
  end if;
end
$archive$;
