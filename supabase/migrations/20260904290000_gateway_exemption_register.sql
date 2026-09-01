-- =============================================================================
-- The gateway net keeps its width, and gains a register
--
-- erp.assert_gateway_integrity() refused Part 14's store-and-forward queue:
--
--   a table other than erp.command holds dispatchable outbound intent
--   [erp.device_action] — if this is an outbound queue it must go through
--   erp.command
--
-- It was right to look and wrong about the answer, which is the most useful
-- thing a heuristic can be. Its own comment states the intent: "Every route to
-- the outside world starts with an erp.command row, so a second table holding
-- an outbound intent would be a second gateway." erp.device_action is not that.
-- §14.5's queue runs the other way — a handheld captures a pick in a cold store
-- with no signal and forwards it TO the platform on reconnection. Nothing
-- leaves the building.
--
-- Two ways to settle it, and the obvious one is wrong.
--
-- Narrowing the heuristic — say, to tables that also carry an external_system_id
-- — would make erp.device_action pass, and would also let a genuine outbound
-- queue through by the simple expedient of not having that column. A test that
-- can be evaded by omitting something is worse than the false positive it was
-- meant to fix.
--
-- So the net keeps its full width and gains what the audit and attribution
-- generators already have: a register of stated exceptions. Any table with an
-- idempotency key is a second gateway until somebody writes down why it is not,
-- and that sentence is then in the schema where the next person will read it.
-- =============================================================================

create table if not exists erp_meta.gateway_exemption (
  schema_name   text not null,
  table_name    text not null,
  rationale     text not null,
  registered_at timestamptz not null default now(),
  primary key (schema_name, table_name),
  constraint gateway_exemption_has_rationale
    check (length(btrim(rationale)) >= 40)
);

comment on table erp_meta.gateway_exemption is
  'Tables that carry an idempotency key and are NOT a second outbound gateway. '
  'The rationale has a minimum length because "not a gateway" is not a reason, '
  'and the point of the register is the sentence rather than the row.';

insert into erp_meta.gateway_exemption (schema_name, table_name, rationale) values
  ('erp', 'device_action',
   'Specification v1.2 §14.5. This queue is INBOUND: a handheld captures a pick, '
   'count, move or putaway while offline and forwards it to the platform on '
   'reconnection. The idempotency key exists so that "reconnection never '
   'duplicates", not so that a message can be dispatched to an external system. '
   'Nothing in this table leaves the building, and routing it through '
   'erp.command would put device capture behind the outbound adapter registry, '
   'which is neither where it belongs nor a place it could work.')
on conflict (schema_name, table_name) do update set rationale = excluded.rationale;

CREATE OR REPLACE FUNCTION erp.gateway_integrity_report()
 RETURNS TABLE(finding text, reference text, detail text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  -- Structural: could the gateway be bypassed?
  --
  -- Every route to the outside world starts with an erp.command row, so a
  -- second table holding an outbound intent would be a second gateway. This
  -- catches the case where someone adds one.
  select 'a table other than erp.command holds dispatchable outbound intent',
         format('%s.%s', c.relnamespace::regnamespace::text, c.relname),
         'if this is an outbound queue it must go through erp.command'
    from pg_catalog.pg_class c
   where c.relkind = 'r'
     and c.relnamespace::regnamespace::text = 'erp'
     and c.relname <> 'command'
     and exists (select 1 from pg_catalog.pg_attribute a
                  where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
                    and a.attname = 'idempotency_key')
     -- The net stays wide on purpose: any table with an idempotency key looks
     -- like a second gateway until somebody says why it is not. Narrowing the
     -- heuristic instead -- to tables that also name an external system, say --
     -- would let a real outbound queue through by omitting one column.
     and not exists (select 1 from erp_meta.gateway_exemption g
                      where g.schema_name = c.relnamespace::regnamespace::text
                        and g.table_name = c.relname)
  union all
  -- Structural: is the lifecycle guard still attached?
  select 'erp.command has no transition guard', 'erp.command',
         'the lifecycle would be whatever any UPDATE says it is'
   where not exists (
     select 1 from pg_catalog.pg_trigger tg
      where tg.tgrelid = 'erp.command'::regclass and not tg.tgisinternal
        and tg.tgfoid = 'erp.check_command_transition()'::regprocedure)
  union all
  -- Structural: is the credential guard still attached?
  select 'erp.external_system has no inline-credential guard', 'erp.external_system',
         'a connection document could carry a secret'
   where not exists (
     select 1 from pg_catalog.pg_trigger tg
      where tg.tgrelid = 'erp.external_system'::regclass and not tg.tgisinternal
        and tg.tgfoid = 'erp.reject_inline_credentials()'::regprocedure)
  union all
  -- Data: a dry run that reached a real terminal state, or the reverse.
  select 'a simulated command reached a live terminal state', c.id::text,
         format('dry_run = %s, status = %s', c.dry_run, c.status)
    from erp.command c
   where (c.dry_run and c.status = 'succeeded')
      or (not c.dry_run and c.status = 'simulated')
  union all
  -- Data: a credential in a stored connection or payload.
  select 'a stored connection contains a credential', s.code, f.path || ' — ' || f.finding
    from erp.external_system s
    cross join lateral erp.inline_credential_findings(s.connection) f
  union all
  select 'a command payload contains a credential', c.id::text, f.path || ' — ' || f.finding
    from erp.command c
    cross join lateral erp.inline_credential_findings(c.payload) f
  union all
  select 'a credential is stored where the reference should be', s.code, 'credential_ref'
    from erp.external_system s
   where s.credential_ref is not null
     and erp_ref.looks_like_secret(s.credential_ref)
  union all
  -- Data: a message that no longer hashes to what arrived.
  select 'a logged message no longer matches its hash', m.id::text,
         'the payload has been altered since receipt; it cannot be replayed'
    from erp.integration_message m
   where erp.payload_hash(m.payload, m.payload_ref) <> m.payload_hash
  union all
  -- Data: an external reference pointing at a system that no longer enables it.
  select 'an external reference is in conflict without detail', r.id::text,
         'sync_state is conflict but conflict_detail is null'
    from erp.external_ref r
   where r.sync_state = 'conflict' and r.conflict_detail is null
  union all
  -- Data: a command in flight for longer than any plausible lease.
  select 'a command has been in flight for over a day', c.id::text,
         format('claimed by %s at %s', coalesce(c.claimed_by, 'unknown'), c.claimed_at)
    from erp.command c
   where c.status = 'in_flight' and c.claimed_at < now() - interval '1 day'
$function$

;

-- Prove the net still catches what it is for: a table with an idempotency key
-- and no exemption is still a finding.
do $$
declare v_found integer;
begin
  create temp table zz_gateway_probe (
    id uuid primary key default gen_random_uuid(),
    tenant_id uuid,
    idempotency_key text
  ) on commit drop;

  -- A temp table is not in the erp schema, so it cannot exercise the predicate.
  -- Assert the shape of the check instead: the exemption must be the only thing
  -- letting erp.device_action through.
  delete from erp_meta.gateway_exemption
   where schema_name = 'erp' and table_name = 'device_action';

  select count(*) into v_found from erp.gateway_integrity_report()
   where reference = 'erp.device_action';

  if v_found <> 1 then
    raise exception
      'ERPWARE_GATEWAY_NET_TOO_NARROW: erp.device_action is not caught without '
      'its exemption, so the exemption is not what is letting it through and '
      'the check no longer means what it says';
  end if;

  insert into erp_meta.gateway_exemption (schema_name, table_name, rationale) values
    ('erp', 'device_action',
     'Specification v1.2 §14.5. This queue is INBOUND: a handheld captures a pick, '
     'count, move or putaway while offline and forwards it to the platform on '
     'reconnection. The idempotency key exists so that "reconnection never '
     'duplicates", not so that a message can be dispatched to an external system. '
     'Nothing in this table leaves the building, and routing it through '
     'erp.command would put device capture behind the outbound adapter registry, '
     'which is neither where it belongs nor a place it could work.');
end $$;

-- Register it as platform_internal and run the generators, like every other
-- erp_meta register. The isolation assertion caught this omission on the first
-- rebuild from empty: a table created without a policy row is a table outside
-- the pattern, however small its purpose.
insert into erp_meta.table_policy (schema_name, table_name, table_class, note)
values ('erp_meta','gateway_exemption','platform_internal',
        'Tables carrying an idempotency key that are not a second outbound gateway, each with the sentence saying why.')
on conflict (schema_name, table_name) do nothing;

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();

select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
select erp.assert_gateway_integrity();
