-- A posting rule raises lines, and the reconciliation reads the organisation
-- it is visiting.
--
-- On the night of 15 September the console's "The whole database reconciles"
-- said this:
--
--   CLOVEERP_DATABASE_DOES_NOT_RECONCILE: 20/48 check(s) failed across 3
--   organisation(s)
--     clove-foods: posting rule cash_application v1 — CLOVEERP_POSTING_RULE_EMPTY
--     …and the same ten rules again in the demonstration organisation.
--
-- Twenty minutes earlier the deploy had run the same function against the same
-- database and answered:
--
--   whole database: 3 organisation(s), 48 check(s), all reconcile
--
-- Both are the truth about the session that asked. The rules are not empty.
-- The difference is that somebody was signed in.
--
-- erp.assert_whole_database_reconciles() visits every organisation by setting
-- the job context and leaving the signed-in person where they were.
-- 20260914079000 found what that means, in the console's commercial routines:
-- "the context is honoured only when nobody is signed in". A person's own
-- organisation comes first in erp.current_tenant_id(), so a job context is
-- read only when there is no person. The deploy has no person, so it visits
-- what it names. The console is reached through a definer door with the
-- operator's own claims still on the session, so every check it ran while
-- walking the estate ran against the operator's own organisation instead.
--
-- Most of the register's per-organisation assertions ask their question of
-- erp.current_tenant_id() and so quietly answered it three times about one
-- organisation — wrong, and silent. The posting-rule loop is the one that
-- names the organisation it is looking at: it enumerates the rules of the
-- organisation being visited and then asks erp.assert_posting_rule_balances()
-- about each by code and version. That routine looks the rule up in the
-- organisation in context, did not find a rule of somebody else's
-- organisation, and said "raises no lines" — which is what it says when the
-- lines are empty and, until now, also what it said when there was no rule to
-- read at all. Ten rules, two organisations, twenty findings, none of them
-- about the books.
--
-- 20260914080000 made this exact repair for three console routines and left a
-- check behind. That check reads the routines whose source names
-- erp_meta.require_platform() or erp_meta.platform_actor(); the whole-database
-- reconciliation names neither, so it was never a candidate.
--
-- What is held here:
--
--   1. The reconciliation works inside each organisation it visits, through
--      erp_meta.act_in_tenant(), which sets the person aside for the rest of
--      the call. Nothing else about it moves: the refusal keeps its prefix and
--      still names the organisation and the rule at fault, and the success
--      text is byte-for-byte what it was.
--
--   2. A rule that is not a rule of this organisation is refused in those
--      words rather than as one that raises nothing, so a context fault can
--      never again be read as an accounting fault.
--
--   3. A rule in force cannot be written with no lines, by any path. Promotion
--      has asserted it since 20260829220000 and still does; now the table
--      refuses it as well, so a direct write, a repair by hand and a path
--      written next year are all covered by the same rule. A rule in force
--      that raises nothing would let a document post a journal with nothing in
--      it, and the journal guard would refuse that at commit with an opaque
--      message about a journal nobody asked for.
--
--   4. An assertion over every organisation's rules in force, registered so
--      the console can run it and the build must. It reads the rules rather
--      than the session, so it cannot be fooled the way the reconciliation
--      was.
--
--   5. erp_test.posting_rules_raise_lines_suite(), which proves all of it,
--      including the original finding: with a person signed in, a rule of
--      another organisation is now read in that organisation.
--
-- No repair is shipped, because there is nothing to repair. The estate check
-- below is the proof of that, run on every build and by the console: if any
-- organisation ever does hold a rule in force that raises nothing, it will be
-- named, and which accounts it should reach is the owner's decision rather
-- than something to invent here.

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. What "raises nothing" means, said once
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp.posting_rule_raises_nothing(p_posting_lines jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_posting_lines is null
      or jsonb_typeof(p_posting_lines) <> 'array'
      or jsonb_array_length(p_posting_lines) = 0
$$;

comment on function erp.posting_rule_raises_nothing(jsonb) is
  'Whether a posting rule''s lines would raise no journal line at all: absent, '
  'not a list, or an empty list. One statement, read by the table guard, by '
  'the estate check and by the assertion promotion runs.';

revoke all on function erp.posting_rule_raises_nothing(jsonb) from public, anon, authenticated;

-- The words, for the people they refuse.

select erp.register_refusal(
  'CLOVEERP_POSTING_RULE_EMPTY',
  'A posting rule that is in force and raises no lines.',
  'A rule in force decides which accounts a document reaches and on which side. One that lists no lines would let a document post a journal with nothing in it, so the ledger would be silently short of what the document did.',
  'Give the rule at least one line to debit and one to credit, of equal value, then put it in force.');

select erp.register_refusal(
  'CLOVEERP_POSTING_RULE_NOT_IN_THIS_ORGANISATION',
  'A question about a posting rule that belongs to another organisation.',
  'Rules are held by the organisation that promoted them. Asking about one from inside a different organisation finds nothing, and finding nothing is not the same as a rule that raises nothing.',
  'Ask again from inside the organisation that holds the rule.');

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The assertion promotion runs tells the two faults apart
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Re-emitted rather than patched by needle: the live body differs from the one
-- 20260829220000 wrote only in its prefix, which 20260904980000 rewrote, and
-- the text below carries that prefix already.

create or replace function erp.assert_posting_rule_balances(
  p_code text, p_version integer)
returns void
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_found  boolean;
  v_lines  jsonb;
  v_out    numeric;
  v_bad    text;
begin
  select true, pr.posting_lines into v_found, v_lines
    from erp.posting_rule pr
   where pr.tenant_id = v_tenant and pr.code = p_code and pr.version = p_version;

  -- Not the same fault, and saying so is the whole of 20260916010000. A rule
  -- of another organisation is unreadable from here; a rule of this one that
  -- lists nothing is configuration that looks like behaviour.
  if not coalesce(v_found, false) then
    raise exception 'CLOVEERP_POSTING_RULE_NOT_IN_THIS_ORGANISATION: % v% is not a rule of this organisation', p_code, p_version
      using errcode = '23503',
            hint = 'Ask again from inside the organisation that holds the rule.';
  end if;

  if erp.posting_rule_raises_nothing(v_lines) then
    raise exception 'CLOVEERP_POSTING_RULE_EMPTY: % v% raises no lines', p_code, p_version
      using errcode = '23514',
            hint = 'A rule that posts nothing is configuration that looks like behaviour.';
  end if;

  -- Every side must be one of two words. A typo here would otherwise read as a
  -- credit, because the interpreter has to treat "not debit" as something.
  select string_agg(distinct l.value ->> 'side', ', ') into v_bad
    from jsonb_array_elements(v_lines) l
   where coalesce(l.value ->> 'side', '') not in ('debit', 'credit');

  if v_bad is not null then
    raise exception 'CLOVEERP_POSTING_RULE_SIDE: % v% has line side(s) %',
      p_code, p_version, v_bad using errcode = '23514';
  end if;

  v_out := erp.posting_rule_imbalance(v_lines);

  if v_out <> 0 then
    raise exception
      'CLOVEERP_POSTING_RULE_UNBALANCED: % v% is out by % per unit of document value',
      p_code, p_version, v_out
      using errcode = '23514',
            hint = 'Debit rates must sum to credit rates, or every journal this '
                   'rule raises will fail its balance check at commit.';
  end if;
end;
$$;

comment on function erp.assert_posting_rule_balances(text, integer) is
  'The rule named, read in the organisation in context: it has to be a rule of '
  'that organisation, it has to raise lines, every line has to take a side, and '
  'the debit rates have to sum to the credit rates. All four are answerable '
  'without a document, which is why promotion answers them.';

revoke all on function erp.assert_posting_rule_balances(text, integer) from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. A rule in force cannot be written with no lines
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Promotion asserts it, and promotion is the only path in this repository that
-- writes a rule. The guard is on the table because the next path will not be
-- written by whoever reads that assertion.

create or replace function erp.check_posting_rule_raises_lines()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'active' and erp.posting_rule_raises_nothing(new.posting_lines) then
    raise exception 'CLOVEERP_POSTING_RULE_EMPTY: % v% raises no lines', new.code, new.version
      using errcode = '23514',
            hint = 'Give the rule at least one line to debit and one to credit, of equal value, then put it in force.';
  end if;
  return new;
end;
$$;

comment on function erp.check_posting_rule_raises_lines() is
  'Refuses a posting rule that is in force and lists no lines, whichever path '
  'wrote it. A rule not yet in force may list nothing, because that is what a '
  'draft is for.';

revoke all on function erp.check_posting_rule_raises_lines() from public, anon, authenticated;

drop trigger if exists t_posting_rule_raises_lines on erp.posting_rule;

create trigger t_posting_rule_raises_lines
  before insert or update on erp.posting_rule
  for each row execute function erp.check_posting_rule_raises_lines();

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The check over every organisation's rules in force
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Reads the rules rather than the session. The reconciliation asked the
-- question one organisation at a time, from inside whichever organisation it
-- happened to be in; this one asks it of the estate, so no session context can
-- change the answer.

create or replace function erp.posting_rules_in_force()
returns table(tenant_code text, rule_code text, rule_version integer,
              lines integer, raises_nothing boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select tn.code, pr.code, pr.version,
         case when jsonb_typeof(pr.posting_lines) = 'array'
              then jsonb_array_length(pr.posting_lines) else 0 end,
         erp.posting_rule_raises_nothing(pr.posting_lines)
    from erp.posting_rule pr
    join erp.tenant tn on tn.id = pr.tenant_id
   where pr.status = 'active'
     and tn.deleted_at is null
   order by tn.code, pr.code, pr.version
$$;

comment on function erp.posting_rules_in_force() is
  'Every posting rule in force in every organisation that is not awaiting '
  'purge, with how many lines it raises. Runs as its owner because the estate '
  'is not one organisation''s to read; it is reachable only from owner-held '
  'code.';

revoke all on function erp.posting_rules_in_force() from public, anon, authenticated;

insert into erp_meta.security_definer_allowance (schema_name, function_name, rationale)
values ('erp', 'posting_rules_in_force',
  'Reads every organisation''s posting rules so one check can say whether any of them raises nothing. A per-organisation read would have to be asked from inside each organisation, which is the fault this check exists to catch. Returns counts and codes, no amounts and no names of people.')
on conflict (schema_name, function_name) do update set rationale = excluded.rationale;

create or replace function erp.posting_rule_without_lines_report()
returns table(finding text, reference text, detail text)
language sql
stable
set search_path = ''
as $$
  select 'a posting rule in force raises no lines',
         f.tenant_code || ' / ' || f.rule_code || ' v' || f.rule_version::text,
         'in force, and lists nothing to debit or credit, so a document posting through it would raise a journal with nothing in it'
    from erp.posting_rules_in_force() f
   where f.raises_nothing
   order by 2
$$;

comment on function erp.posting_rule_without_lines_report() is
  'Every rule in force, in any organisation, that would raise no journal line. '
  'The console reads this beside the assertion, so a finding names the '
  'organisation and the rule rather than a count.';

revoke all on function erp.posting_rule_without_lines_report() from public, anon, authenticated;

create or replace function erp.assert_every_posting_rule_raises_lines()
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  v_count  integer;
  v_detail text;
  v_rules  integer;
  v_orgs   integer;
begin
  select count(*), string_agg(format('  %s — %s', r.reference, r.detail), E'\n')
    into v_count, v_detail
    from erp.posting_rule_without_lines_report() r;

  if v_count > 0 then
    raise exception 'CLOVEERP_POSTING_RULE_EMPTY: % rule(s) in force raise no lines', v_count
      using errcode = '23514', detail = v_detail,
            hint = 'Give each rule at least one line to debit and one to credit, of equal value, then put it in force.';
  end if;

  select count(*), count(distinct f.tenant_code) into v_rules, v_orgs
    from erp.posting_rules_in_force() f;

  return format('posting rules: %s in force across %s organisation(s), every one raises lines',
                v_rules, v_orgs);
end;
$$;

comment on function erp.assert_every_posting_rule_raises_lines() is
  'Every posting rule in force, in every organisation not awaiting purge, '
  'raises at least one line. Asked of the estate rather than of a session, so '
  'the answer does not depend on who is signed in.';

revoke all on function erp.assert_every_posting_rule_raises_lines() from public, anon, authenticated;

insert into erp_meta.diagnostic_check
  (code, title, kind, scope, schema_name, function_name, arguments, detail_function, detail_arguments, blurb, runs_in_ci, seq)
values
  ('posting_rules_raise_lines', 'Every posting rule in force raises lines',
   'assertion', 'platform', 'erp', 'assert_every_posting_rule_raises_lines', '',
   'posting_rule_without_lines_report', '',
   'A rule in force decides which accounts a document reaches. One that lists no lines lets a document post a journal with nothing in it, and the journal guard refuses that at commit, on a document somebody needed. Asked of every organisation at once, so the answer does not depend on who is signed in.',
   true, 101)
on conflict (code) do update set
  title = excluded.title, schema_name = excluded.schema_name,
  function_name = excluded.function_name, arguments = excluded.arguments,
  detail_function = excluded.detail_function, blurb = excluded.blurb,
  runs_in_ci = excluded.runs_in_ci, seq = excluded.seq;

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. The reconciliation works in the organisation it is visiting
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The tenant list is taken once, before the walk begins: the rows are read
-- under whatever context the caller has, and the walk then changes that
-- context, so reading them lazily would have the loop deciding what to visit
-- from inside somewhere else.

create or replace function erp.assert_whole_database_reconciles()
returns text
language plpgsql
volatile
security invoker
set search_path = ''
as $$
declare
  v_trusted  boolean := erp.session_is_trusted();
  v_prev     text    := current_setting('erp.job_tenant_id', true);
  v_own      uuid    := erp.current_tenant_id();
  v_tenants  integer := 0;
  v_checks   integer := 0;
  v_fail     integer := 0;
  v_skipped  integer := 0;
  v_skipped_codes text;
  v_findings text    := '';
  v_out      text;
  v_call     text;
  v_ids      uuid[];
  v_codes    text[];
  v_i        integer;
  r          record;
begin
  if not v_trusted and v_own is null then
    raise exception 'CLOVEERP_NO_TENANT_CONTEXT: the whole-database reconciliation visits every organisation from a trusted session, or the caller''s own from an organisation session; this session has neither'
      using errcode = '42501';
  end if;

  -- An organisation awaiting purge has asked to be destroyed; deleted_at is
  -- the marker of that request (20260831180000). Its books are not visited,
  -- and it is named below so the result says what was left aside.
  select count(*), string_agg(tn.code, ', ' order by tn.code)
    into v_skipped, v_skipped_codes
    from erp.tenant tn
   where (v_trusted or tn.id = v_own)
     and tn.deleted_at is not null;

  select array_agg(tn.id order by tn.code), array_agg(tn.code order by tn.code)
    into v_ids, v_codes
    from erp.tenant tn
   where (v_trusted or tn.id = v_own)
     and tn.deleted_at is null;

  for v_i in 1 .. coalesce(array_length(v_ids, 1), 0) loop
    v_tenants := v_tenants + 1;

    -- Inside the organisation, not beside it. Setting the job context alone is
    -- honoured only when nobody is signed in (20260914079000), so a console
    -- session ran every check below against the operator's own organisation
    -- and reported the answer against somebody else's name.
    if v_trusted then
      perform erp_meta.act_in_tenant(v_ids[v_i]);
    end if;

    -- Every per-organisation assertion the register holds — stock, subledger,
    -- inventory, genealogy, manifest today — read from the register, so a
    -- tenant-scoped assertion registered tomorrow is driven by existing.
    for r in
      select d.schema_name, d.function_name, d.arguments
        from erp_meta.diagnostic_check d
       where d.kind = 'assertion' and d.scope = 'tenant'
         and d.function_name <> 'assert_whole_database_reconciles'
       order by d.seq, d.code
    loop
      v_call := format('%I.%I(%s)', r.schema_name, r.function_name, r.arguments);
      begin
        execute 'select ' || v_call into v_out;
        v_checks := v_checks + 1;
      exception when others then
        v_fail := v_fail + 1;
        v_findings := v_findings || format(E'  %s: %s — %s\n', v_codes[v_i], v_call, left(sqlerrm, 300));
      end;
    end loop;

    -- Every posting rule in force, through the check its installer ran once.
    for r in
      select pr.code, pr.version
        from erp.posting_rule pr
       where pr.tenant_id = v_ids[v_i] and pr.status = 'active'
       order by pr.code, pr.version
    loop
      begin
        perform erp.assert_posting_rule_balances(r.code, r.version);
        v_checks := v_checks + 1;
      exception when others then
        v_fail := v_fail + 1;
        v_findings := v_findings || format(E'  %s: posting rule %s v%s — %s\n', v_codes[v_i], r.code, r.version, left(sqlerrm, 300));
      end;
    end loop;

    -- Every entity bound to legislation, through the conformance cases.
    for r in
      select distinct b.entity_id, e.code as entity_code
        from erp.entity_legislation_binding b
        join erp.entity e on e.id = b.entity_id
       where b.tenant_id = v_ids[v_i] and b.status = 'active'
         and (b.effective_to is null or b.effective_to > current_date)
       order by e.code
    loop
      begin
        perform erp.assert_legislation_conformance(r.entity_id);
        v_checks := v_checks + 1;
      exception when others then
        v_fail := v_fail + 1;
        v_findings := v_findings || format(E'  %s: legislation on %s — %s\n', v_codes[v_i], r.entity_code, left(sqlerrm, 300));
      end;
    end loop;
  end loop;

  if v_trusted then
    perform erp_meta.stop_acting_in_tenant();
    if coalesce(v_prev, '') <> '' then
      perform set_config('erp.job_tenant_id', v_prev, true);
    end if;
  end if;

  if v_skipped > 0 then
    v_findings := v_findings || format(E'  %s awaiting purge skipped (%s)\n', v_skipped, v_skipped_codes);
  end if;

  if v_fail > 0 then
    raise exception E'CLOVEERP_DATABASE_DOES_NOT_RECONCILE: %/% check(s) failed across % organisation(s)\n%',
      v_fail, v_fail + v_checks, v_tenants, v_findings
      using errcode = '23514';
  end if;

  return format('whole database: %s organisation(s), %s%s check(s), all reconcile',
                v_tenants,
                case when v_skipped > 0
                     then format('%s awaiting purge skipped (%s), ', v_skipped, v_skipped_codes)
                     else '' end,
                v_checks);
end;
$$;

comment on function erp.assert_whole_database_reconciles is
  'Stock, subledger, inventory, genealogy and manifest for every organisation, '
  'every active posting rule balanced, every bound entity conformant. A trusted '
  'session visits every organisation, working inside each one rather than '
  'beside it, so a signed-in operator does not have the whole estate checked '
  'against their own organisation; an organisation session checks its own. '
  'An organisation awaiting purge (deleted_at set) is left aside and named in '
  'the result: its books are about to be destroyed with it. The build runs it '
  'last, after every suite, against whatever they left.';

revoke all on function erp.assert_whole_database_reconciles() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. The suite
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_test.posting_rules_raise_lines_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
volatile
set search_path = ''
as $$
declare
  ra        record;
  a1        uuid := gen_random_uuid();
  v_hex     text := substr(md5(gen_random_uuid()::text), 1, 6);
  v_acode   text;
  v_bcode   text;
  v_a       uuid;
  v_b       uuid;
  v_cs      uuid;
  v_words   boolean;
  v_promote text;
  v_direct  text;
  v_empty   text;
  v_rules   integer;
  v_thin    integer;
  v_unbal   integer;
  v_estate  text;
  v_report  integer;
  v_recon   text;
begin
  v_acode := 'zzprl-a-' || v_hex;
  v_bcode := 'zzprl-b-' || v_hex;

  -- Every falsification below is undone by the exception that ends the block,
  -- whichever way the run goes: a suite that leaves an organisation behind on
  -- the live database is a suite nobody may run there.
  begin
    select count(*) = 0 into v_words
      from erp_ref.refusal f
     where f.code in ('CLOVEERP_POSTING_RULE_EMPTY', 'CLOVEERP_POSTING_RULE_NOT_IN_THIS_ORGANISATION')
       and (erp_test.sounds_internal(f.refused)
            or erp_test.sounds_internal(f.why)
            or erp_test.sounds_internal(f.next_action));
    v_words := coalesce(v_words, false)
               and (select count(*) from erp_ref.refusal f
                     where f.code in ('CLOVEERP_POSTING_RULE_EMPTY',
                                      'CLOVEERP_POSTING_RULE_NOT_IN_THIS_ORGANISATION')) = 2;

    select * into ra from erp.provision_tenant(
      v_acode, 'Posting rules raise lines', 'admin@' || v_acode || '.test', 'Suite Admin');
    v_a := ra.tenant_id;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(ra.admin_token);

    -- The books, installed the way the product installs them.
    perform erp_test.reopen_bootstrap_window(v_a);
    perform erp.configure_finance();

    select count(*),
           count(*) filter (where erp.posting_rule_raises_nothing(pr.posting_lines)),
           count(*) filter (where erp.posting_rule_imbalance(pr.posting_lines) <> 0)
      into v_rules, v_thin, v_unbal
      from erp.posting_rule pr
     where pr.tenant_id = v_a and pr.status = 'active';

    -- A change set that names a rule and no lines. Promotion refused this
    -- before today; the table refuses it now, so the refusal arrives whichever
    -- of the two is reached first.
    begin
      v_cs := erp.create_change_set('zzprl-nolines-' || v_hex, 'A rule that raises nothing',
                                    'Proof that a rule in force cannot list nothing.');
      perform erp.add_change_set_item(
        v_cs, 'posting_rule', 'zzprlnothing',
        jsonb_build_object('code', 'zzprlnothing', 'name', 'Raises nothing',
                           'ledger', 'GL', 'event_type', 'stock.adjusted'));
      perform erp.submit_change_set(v_cs);
      perform erp.approve_change_set(v_cs);
      perform erp.promote_change_set(v_cs);
      v_promote := 'the rule was promoted';
    exception when others then v_promote := left(sqlerrm, 200);
    end;

    -- A direct write, which is the path promotion's assertion never sees.
    begin
      insert into erp.posting_rule (tenant_id, code, event_type, posting_lines, status, effective_from)
      values (v_a, 'zzprldirect', 'stock.adjusted', '[]'::jsonb, 'active', current_date);
      v_direct := 'the rule was written';
    exception when others then v_direct := left(sqlerrm, 200);
    end;

    -- And emptying the one in force.
    begin
      update erp.posting_rule pr
         set posting_lines = '[]'::jsonb
       where pr.tenant_id = v_a and pr.code = 'goods_receipt' and pr.status = 'active';
      v_empty := 'the rule was emptied';
    exception when others then v_empty := left(sqlerrm, 200);
    end;

    perform erp_test.close_bootstrap_window(v_a);

    -- The estate check, and the report it promises.
    begin
      v_estate := erp.assert_every_posting_rule_raises_lines();
    exception when others then v_estate := left(sqlerrm, 300);
    end;
    select count(*) into v_report from erp.posting_rule_without_lines_report();

    -- The finding of 15 September. A second organisation holds a rule that
    -- does not balance, and the person signed in belongs to the first. Before
    -- today the reconciliation looked the rule up in the signed-in person's
    -- organisation, found nothing, and said it raised no lines.
    -- Built with nobody signed in, so the guards that read the session see
    -- what they see when a suite builds an organisation from nothing; then the
    -- person comes back, because the person is the whole point of the case.
    perform set_config('request.jwt.claims', '', true);
    insert into erp.tenant (code, name)
    values (v_bcode, 'Another organisation entirely') returning id into v_b;
    insert into erp.posting_rule (tenant_id, code, event_type, posting_lines, status, effective_from)
    values (v_b, 'zzprlunbalanced', 'stock.adjusted',
            '[{"side":"debit","account":"1200","basis":"document_value","rate":1}]'::jsonb,
            'active', date '2020-01-01');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);

    begin
      v_recon := erp.assert_whole_database_reconciles();
    exception when others then v_recon := sqlerrm;
    end;

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      v_recon := coalesce(v_recon, 'the suite stopped: ' || left(sqlerrm, 200));
    end if;
  end;

  case_name := 'the refusals this holds are registered in the words of the people they refuse';
  passed := coalesce(v_words, false);
  detail := 'a rule in force that raises nothing, and a rule that is not this organisation''s to read';
  return next;

  case_name := 'a list that is absent, empty or not a list is what raising nothing means';
  passed := coalesce(erp.posting_rule_raises_nothing(null::jsonb)
                     and erp.posting_rule_raises_nothing('[]'::jsonb)
                     and erp.posting_rule_raises_nothing('{}'::jsonb)
                     and erp.posting_rule_raises_nothing('"nothing"'::jsonb)
                     and not erp.posting_rule_raises_nothing(
                           '[{"side":"debit","account":"1200","rate":1}]'::jsonb), false);
  detail := 'one statement, read by the table guard, the estate check and the assertion promotion runs';
  return next;

  case_name := 'the finance installer puts rules in force and every one of them raises balanced lines';
  passed := coalesce(v_rules > 0 and v_thin = 0 and v_unbal = 0, false);
  detail := format('%s rule(s) in force, %s raising nothing, %s out of balance',
                   coalesce(v_rules, -1), coalesce(v_thin, -1), coalesce(v_unbal, -1));
  return next;

  case_name := 'promoting a rule that names no lines is refused by name';
  passed := coalesce(v_promote like '%CLOVEERP_POSTING_RULE_EMPTY%', false);
  detail := coalesce(v_promote, 'nothing was tried');
  return next;

  case_name := 'nor may a rule in force be written with no lines by any other path';
  passed := coalesce(v_direct like '%CLOVEERP_POSTING_RULE_EMPTY%', false);
  detail := coalesce(v_direct, 'nothing was tried');
  return next;

  case_name := 'nor emptied once it is in force';
  passed := coalesce(v_empty like '%CLOVEERP_POSTING_RULE_EMPTY%', false);
  detail := coalesce(v_empty, 'nothing was tried');
  return next;

  case_name := 'every organisation''s rules in force raise lines, and the check says how many';
  passed := coalesce(v_estate like 'posting rules: % in force across % organisation(s), every one raises lines'
                     and v_report = 0, false);
  detail := coalesce(v_estate, 'no answer') || format(' (%s finding(s))', coalesce(v_report, -1));
  return next;

  -- The original finding, falsified. The rule is unbalanced, so the
  -- reconciliation must refuse; what matters is which refusal it names.
  case_name := 'the reconciliation reads a rule in the organisation that holds it, not in the signed-in person''s';
  passed := coalesce(v_recon like '%' || v_bcode || ': posting rule zzprlunbalanced v1 — %'
                     and v_recon like '%zzprlunbalanced v1 — CLOVEERP_POSTING_RULE_UNBALANCED%'
                     and v_recon not like '%zzprlunbalanced v1 — CLOVEERP_POSTING_RULE_EMPTY%'
                     and v_recon not like '%zzprlunbalanced v1 — CLOVEERP_POSTING_RULE_NOT_IN_THIS_ORGANISATION%',
                     false);
  detail := left(coalesce(v_recon, 'no answer'), 300);
  return next;

  case_name := 'every falsification was undone';
  passed := not exists (select 1 from erp.tenant tn where tn.code in (v_acode, v_bcode));
  detail := 'two organisations, a change set and four rules, all rolled back with the block that made them';
  return next;
end;
$$;

comment on function erp_test.posting_rules_raise_lines_suite() is
  'A rule in force cannot be written with no lines by promotion or by any '
  'other path; every organisation''s rules in force raise lines; and the '
  'whole-database reconciliation reads a rule in the organisation that holds '
  'it even when somebody is signed in somewhere else.';

create or replace function erp_test.assert_posting_rules_raise_lines_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  c_expected constant integer := 9;
  v_total  integer;
  v_failed integer;
  v_detail text;
begin
  select count(*),
         count(*) filter (where not coalesce(s.passed, false)),
         string_agg(format('  %s — %s', s.case_name, s.detail), E'\n') filter (where not coalesce(s.passed, false))
    into v_total, v_failed, v_detail
    from erp_test.posting_rules_raise_lines_suite() s;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_POSTING_RULES_SUITE_SHRANK: % case(s), expected %', v_total, c_expected
      using detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  if v_failed > 0 then
    raise exception E'CLOVEERP_POSTING_RULES_SUITE_FAILED: %/% case(s) failed\n%', v_failed, v_total, v_detail
      using hint = 'Read the failed case: a rule in force raises nothing, or the reconciliation is reading rules in the wrong organisation again.';
  end if;
  return format('posting rules raise lines: %s/%s cases passed', v_total - v_failed, v_total);
end;
$$;

revoke all on function erp_test.posting_rules_raise_lines_suite() from public, anon, authenticated;
revoke all on function erp_test.assert_posting_rules_raise_lines_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- The generators, then the assertions
-- ═════════════════════════════════════════════════════════════════════════════

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_append_only_guards();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_invoker_doors_executable();
select erp.assert_no_public_execute();
select erp.assert_no_caller_reachable_internals();
select erp.assert_no_caller_reachable_internal_routines();
select erp.assert_session_context_hygiene();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_resource_coverage('en');

select erp.assert_every_posting_rule_raises_lines();
select erp_test.assert_posting_rules_raise_lines_suite();
select erp.assert_whole_database_reconciles();
