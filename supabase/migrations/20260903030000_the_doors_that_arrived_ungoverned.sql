-- ─────────────────────────────────────────────────────────────────────────────
-- Three doors that arrived without their paperwork.
--
-- 20260903014640 and 20260903020414 added erp_create_site, erp_create_location
-- and a new body for erp_entities. A build from empty stops dead at
-- 20260903100000_capability_registry.sql, which is the next migration to call
-- erp.assert_public_api_safe():
--
--   ERPWARE_PUBLIC_API_UNSAFE: 3 finding(s)
--     public.erp_create_site      VOLATILE, writes, not on the write allow-list
--     public.erp_create_location  VOLATILE, writes, not on the write allow-list
--     public.erp_entities         on the allow-list gated by erp.authorise,
--                                 but its body does not call it
--
-- The third is the one that matters. public.erp_entities() used to be plpgsql,
-- VOLATILE, and began `perform erp.authorise('finance.read')` — a permission
-- check and an access-log row — and returned active entities only. It was
-- replaced by a STABLE sql body with no gate at all, so listing an
-- organisation's legal entities stopped requiring a permission and stopped
-- being recorded. Its row in erp_meta.public_write_allowance stayed behind,
-- still declaring `erp.authorise` as its gate, which is how the register came
-- to describe a door that no longer existed. A register that describes
-- something else is worse than no register.
--
-- So the gate goes back, exactly as it was, and the two new writers are
-- registered with a rationale. Nothing here weakens a rule to make a build
-- pass: erp_create_site and erp_create_location genuinely write and genuinely
-- authorise, which is what the allow-list is for recording.
--
-- Both are thin wrappers, so each declares the erp.* function it delegates to
-- rather than erp.authorise — the register checks that a door's declared gate
-- appears in that door's own body, and erp_receive_against and
-- erp_create_document are registered the same way for the same reason.
--
-- ── Why this file is numbered 20260903030000 ─────────────────────────────────
--
-- Because that is where it has to run. Migrations apply in filename order, the
-- doors land at 20260903014640, and the assertion that catches them is at
-- 20260903100000 — so a repair dated 20260904… would be five hours too late on
-- every build from empty. The number is not a claim about when it was written;
-- it is the position in the sequence where the schema is briefly wrong and
-- this is what puts it right.
--
-- The two migrations that created the doors cannot be corrected in place — a
-- migration is written once — so they are listed in
-- supabase/ci/boundary_grandfathered.txt with a note naming this file as their
-- repair, the same way 20260904584000 is listed against
-- 20260904585000_register_the_dashboard_doors.sql. An exception that names the
-- migration which makes it true is still a rule; one that names nothing is a
-- lowered bar.
-- ─────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────
-- The gate goes back on
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.erp_entities()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_out jsonb;
begin
  perform erp.authorise('finance.read');
  select coalesce(jsonb_agg(x order by x->>'code'), '[]'::jsonb) into v_out from (
    select jsonb_build_object(
      'entity_id', e.id, 'code', e.code, 'name', e.name,
      'base_currency', e.base_currency, 'country_code', e.country_code) as x
      from erp.entity e
     where e.tenant_id = erp.current_tenant_id() and e.status = 'active'
  ) s;
  return v_out;
end;
$function$;

comment on function public.erp_entities() is
  'The organisation''s active legal entities. Gated on finance.read and '
  'recorded, because which entities exist is part of how an organisation is '
  'structured; it briefly lost both and the register went on claiming '
  'otherwise.';

revoke all on function public.erp_entities() from public, anon;
grant execute on function public.erp_entities() to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- The two writers, registered
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values
  ('erp_create_site', 'erp.create_site',
   'Creates a site and the standard bays that go with it, under '
   'administration.configure. A new organisation cannot raise a purchase '
   'order, a receipt or a despatch until it has one, so this is the door that '
   'makes an empty organisation usable.'),
  ('erp_create_location', 'erp.create_location',
   'Creates a location within a site, under administration.configure. A '
   'receipt posts into a receiving location and a despatch picks from '
   'storage, so a site that has run out of the bays it was given needs a way '
   'to add another.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

-- The door and the proof that it is governed, in the same transaction.
select erp.assert_public_api_safe();
