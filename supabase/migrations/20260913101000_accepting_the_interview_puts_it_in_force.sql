-- Accepting the interview puts it in force.
--
-- 20260913100000 made the interview easy to answer: likely answers, starter
-- suggestions, a sessions list and a readable diff per section. What it left
-- is the last mile. A proposed interview was seven change sets on the
-- Configuration screen, listed newest first with one shared timestamp, and a
-- person had to submit, approve and promote each in an order nothing wrote
-- down: the companies before the ledgers that belong to them, the ledgers
-- before an accounting code can name an account, the departments before the
-- approval bands that hang off them. Getting it wrong was a refusal naming a
-- table the person had never heard of.
--
-- So accepting is now one action, and the order is the product's:
--
--   organisation -> finance -> departments -> approvals -> accounting codes
--   -> product classification -> product codes -> marshalling areas
--
--   * Each section runs in its own savepoints. Submitting lands on its own,
--     so an approval request raised by a change-set approval chain survives a
--     later refusal; approving and promoting land together or not at all.
--   * Before go-live the author approves and promotes their own sections,
--     exactly as the module installers already do during the bootstrap
--     window. After go-live accepting stops at ready: the self-approval
--     control is never asked to look away, and a second administrator
--     approves on Configuration.
--   * The statutory chart's pack is brought in whenever that chart is on and
--     no nominal account exists yet, whether or not accounting codes were
--     proposed: choosing the numbering promised the accounts. Finance is set
--     up when accounting codes were proposed and finance is not installed, or
--     a company has no general ledger yet: the pack first, then the finance
--     installer for every active company without a general ledger, by code.
--     The step waits for the organisation section, which carries both the
--     companies and the chart, in every state. The statutory chart with more
--     than one company is refused, because its pack charts one company.
--   * Promotion itself now refuses the two things the organisation section
--     could only check when it was proposed: changing the currency or the
--     financial year of a company whose books are set up, and switching the
--     statutory numbering on over accounts that already exist. And the
--     finance installer refuses a company with no accounts under the
--     statutory numbering, rather than giving it ledgers and nothing to post
--     to.
--   * A refusal is reported per section with its code, message, detail and
--     hint, and the sections that depend on it wait for it; nothing is raised
--     except for an interview that does not exist or has not been proposed.
--     Accepting again picks up from where each section stands.
--
-- The work lives beside the proposer in the intelligence schema: it reads
-- erp_ai.proposal, finds each section through the session columns
-- 20260913100000 added, and calls only the change-set and installer functions
-- a person's own change goes through. Nothing registered as a transaction-path
-- function reaches it, so the intelligence boundary is unchanged; and it
-- never touches a proposal's status, producer or reviewer.
--
-- Also here:
--
--   * erp_change_sets() says per row whether the caller may approve it: not
--     when the organisation is live and they wrote it. Configuration's Approve
--     button reads that instead of assuming every author is refused, which was
--     wrong for the whole bootstrap window. Interview sections share a
--     timestamp, so the list is ordered by code within it.
--   * The copy that described the interview wrongly: the help topic for the
--     onboarding screen was still the invitations topic; first-run step 1 sent
--     an administrator to the interview to invite somebody, and step 4 to
--     master-data change requests to approve configuration; five walkthrough
--     reasons promised defaults the interview never proposes, a chart the base
--     pack never ships and a screen that does not approve changes.
--   * erp_test.interview_ease_suite(): nineteen cases over the answering doors
--     20260913100000 built and the accepting door this file builds.

-- ═════════════════════════════════════════════════════════════════════════════
-- 0. Promotion refuses what would rewrite a company's books
-- ═════════════════════════════════════════════════════════════════════════════
--
-- The organisation section checks two things when it is proposed: a company's
-- currency and financial year change only while it has no general ledger, and
-- the statutory numbering is chosen only while no nominal account exists. A
-- proposal is frozen, and the books can be set up between proposing it and
-- promoting it — on Configuration, or by a second administrator approving it
-- later — so both are checked again where items are applied, which every
-- route reaches: accepting, approving on Configuration, replaying a manifest.
--
-- Patched from the definition the database carries, by asserted replacement,
-- as 20260912260000 did; nothing else in the promoter changes.

do $promoter$
declare
  v_def text := pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure);
  v_n1  text := $n1$perform erp.upsert_entity(p ->> 'code', p ->> 'name', p ->> 'legal_name',$n1$;
  v_r1  text := $r1$-- A company whose books are set up keeps its currency and the
        -- month its financial year starts: its ledgers, periods and postings
        -- are in them. The currency compared is the one erp.upsert_entity()
        -- would write, which is the first company's when none is given.
        if exists (
             select 1 from erp.entity ex
              where ex.tenant_id = v_tenant and ex.code = erp.slug_code(p ->> 'code')
                and exists (select 1 from erp.ledger l
                             where l.tenant_id = v_tenant and l.entity_id = ex.id and l.code = 'GL')
                and (ex.base_currency is distinct from coalesce(
                       nullif(p ->> 'currency', '')::character(3),
                       (select e1.base_currency from erp.entity e1
                         where e1.tenant_id = v_tenant and e1.status = 'active'
                         order by e1.code limit 1),
                       'GBP'::character(3))
                     or ex.fiscal_year_start_month is distinct from
                        coalesce((p ->> 'fiscal_year_start_month')::smallint, 1::smallint))) then
          raise exception
            'CLOVEERP_COMPANY_BOOKS_ALREADY_KEPT: company % already keeps its books, so its currency and the month its financial year starts cannot change', p ->> 'code'
            using errcode = '23514',
                  hint = 'Leave the currency and the financial year of a company whose books are set up as they are. A business that keeps its books in another currency or year is added as a company of its own.';
        end if;
        perform erp.upsert_entity(p ->> 'code', p ->> 'name', p ->> 'legal_name',$r1$;
  v_n2  text := $n2$when 'capability' then$n2$;
  v_r2  text := $r2$when 'capability' then
      -- The statutory numbering gives the standard chart's numbers to other
      -- things, so it is switched on before any nominal account exists or not
      -- at all. Here rather than in erp.set_capability(), which the Features
      -- screen and the chart suites call before there are accounts.
      if i.operation <> 'remove'
         and p ->> 'code' = 'statutory_chart_8_1'
         and coalesce((p ->> 'enabled')::boolean, true)
         and not erp.capability_on(v_tenant, 'statutory_chart_8_1', current_date)
         and exists (select 1 from erp.account a where a.tenant_id = v_tenant) then
        raise exception
          'CLOVEERP_CHART_ALREADY_IN_USE: this organisation already has nominal accounts, so the statutory numbering cannot be switched on'
          using errcode = '23514',
                hint = 'Choose the numbering before any nominal account exists. This organisation keeps the numbering its accounts already use.';
      end if;$r2$;
begin
  if (length(v_def) - length(replace(v_def, v_n1, ''))) / length(v_n1) <> 1 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the entity arm of erp.apply_change_set_item() is not the text this migration patches';
  end if;
  if (length(v_def) - length(replace(v_def, v_n2, ''))) / length(v_n2) <> 1 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the capability arm of erp.apply_change_set_item() is not the text this migration patches';
  end if;
  execute replace(replace(v_def, v_n1, v_r1), v_n2, v_r2);

  v_def := pg_get_functiondef('erp.apply_change_set_item(uuid)'::regprocedure);
  if position('CLOVEERP_COMPANY_BOOKS_ALREADY_KEPT' in v_def) = 0
     or position('CLOVEERP_CHART_ALREADY_IN_USE' in v_def) = 0 then
    raise exception 'CLOVEERP_PROMOTER_UNRECOGNISED: the promoter did not take both refusals';
  end if;
end
$promoter$;

-- And the finance installer, which creates no accounts under the statutory
-- numbering because the chart_8_1 pack ships them, refuses a company that has
-- none rather than giving it ledgers and periods with nothing to post to. The
-- chart and demonstration suites apply the pack before they install finance,
-- so none of them reaches this.
do $installer$
declare
  v_def text := pg_get_functiondef('erp.configure_finance(integer,character,uuid)'::regprocedure);
  v_n   text := $n$  v_ccy := coalesce(p_currency, e.base_currency, 'GBP');$n$;
  v_r   text := $r$  if erp.capability_on(v_tenant, 'statutory_chart_8_1', current_date)
     and not exists (select 1 from erp.account a where a.tenant_id = v_tenant and a.entity_id = e.id) then
    raise exception
      'CLOVEERP_STATUTORY_CHART_NOT_APPLIED: company % has no nominal accounts, and under the statutory numbering they come from the statutory chart pack, not from setting up finance', e.code
      using errcode = '23514',
            hint = 'Apply the statutory chart pack on the Packs screen and put it in force, then set up finance. The statutory numbering covers one company for now.';
  end if;
  v_ccy := coalesce(p_currency, e.base_currency, 'GBP');$r$;
begin
  if (length(v_def) - length(replace(v_def, v_n, ''))) / length(v_n) <> 1 then
    raise exception 'CLOVEERP_INSTALLER_UNRECOGNISED: erp.configure_finance() is not the text this migration patches';
  end if;
  execute replace(v_def, v_n, v_r);

  if position('CLOVEERP_STATUTORY_CHART_NOT_APPLIED' in
              pg_get_functiondef('erp.configure_finance(integer,character,uuid)'::regprocedure)) = 0 then
    raise exception 'CLOVEERP_INSTALLER_UNRECOGNISED: erp.configure_finance() did not take its refusal';
  end if;
end
$installer$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 1. Accepting an interview
-- ═════════════════════════════════════════════════════════════════════════════

create or replace function erp_ai.accept_interview(p_session_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant    uuid := erp.require_tenant_id();
  s           erp.interview_session%rowtype;
  v_live      boolean;
  v_step      text;
  v_dep       text;
  v_cs        uuid;
  v_code      text;
  v_before    text;
  v_after     text;
  v_now       text;
  v_outcome   text;
  v_waits     text;
  v_landed    boolean;
  v_msg       text;
  v_state     text;
  v_detail    text;
  v_hint      text;
  v_has_b3    boolean;
  v_stat      boolean;
  v_need_chart boolean;
  v_need_books boolean;
  v_fp_cs     uuid;
  v_fp_code   text;
  v_fp_status text;
  v_pack      jsonb;
  v_pack_cs   uuid;
  v_ent       record;
  v_first     uuid;
  v_steps     jsonb := '[]'::jsonb;
  v_unlanded  text[] := '{}';
  v_blocked   text[] := '{}';
  v_n_landed  integer := 0;
  v_n_waiting integer := 0;
  v_n_refused integer := 0;
begin
  -- Locked, so two people accepting the same interview at once take turns
  -- rather than both submitting the same sections.
  select * into s from erp.interview_session
   where tenant_id = v_tenant and id = p_session_id
     for update;

  if not found then
    raise exception 'CLOVEERP_UNKNOWN_INTERVIEW: %', p_session_id
      using errcode = '23503',
            hint = 'Open the interview from the onboarding screen; an interview that belongs to another organisation is not visible here.';
  end if;

  if s.status <> 'proposed' then
    raise exception 'CLOVEERP_INTERVIEW_NOT_PROPOSED: % is %, and only an interview that has been proposed can be accepted', s.code, s.status
      using errcode = '23514',
            hint = 'Propose the interview first; accepting puts the changes it proposed in force.';
  end if;

  v_live := erp.tenant_is_live(v_tenant);

  foreach v_step in array array['B.7', 'finance', 'B.1', 'B.2', 'B.3', 'B.4', 'B.5', 'B.6'] loop
    v_cs := null; v_code := null; v_before := null; v_after := null; v_now := null;
    v_outcome := null; v_waits := null; v_landed := false;
    v_msg := null; v_state := null; v_detail := null; v_hint := null;

    -- Finance needs the companies and the chart the organisation section
    -- carries; approval bands need their departments; an accounting code's
    -- account needs finance. A dependency that was refused or skipped always
    -- holds its dependants back. One that is only waiting for a second person
    -- holds them back before go-live, when accepting would otherwise promote
    -- them over it; after go-live they are submitted beside it. Finance waits
    -- for the organisation section in both states.
    v_dep := case v_step when 'finance' then 'B.7' when 'B.2' then 'B.1' when 'B.3' then 'finance' end;
    if v_dep is not null
       and (v_dep = any (v_blocked)
            or (v_dep = any (v_unlanded) and (not v_live or v_step = 'finance'))) then
      v_waits := v_dep;
    end if;

    if v_step = 'finance' then
      select exists (
               select 1 from erp_ai.proposal p
                 join erp.change_set c on c.tenant_id = p.tenant_id and c.id = p.change_set_id
                where p.tenant_id = v_tenant
                  and p.interview_session_id = p_session_id
                  and p.interview_section = 'B.3')
        into v_has_b3;

      -- The finance installer's own test for "already installed".
      select c.id, c.code, c.status::text into v_fp_cs, v_fp_code, v_fp_status
        from erp.change_set c
       where c.tenant_id = v_tenant and c.code = 'finance-posting';

      -- Two things this step can owe. The statutory numbering's accounts,
      -- whenever that numbering is on and no nominal account exists yet,
      -- whether or not accounting codes were proposed: choosing the numbering
      -- promised them, and nothing else brings them in. And the books, when
      -- accounting codes were proposed and finance is not installed, or a
      -- company (one the organisation section has just created, most often)
      -- has no general ledger yet.
      v_stat := erp.capability_on(v_tenant, 'statutory_chart_8_1', current_date);
      v_need_chart := v_stat and not exists (select 1 from erp.account a where a.tenant_id = v_tenant);
      v_need_books := v_has_b3
                      and (v_fp_cs is null
                           or exists (select 1 from erp.entity e
                                       where e.tenant_id = v_tenant and e.status = 'active'
                                         and not exists (select 1 from erp.ledger l
                                                          where l.tenant_id = v_tenant and l.entity_id = e.id
                                                            and l.code = 'GL')));

      if not v_need_chart and not v_need_books then
        if v_has_b3 and v_fp_cs is not null then
          v_outcome := 'already_set_up';
          v_cs := v_fp_cs; v_code := v_fp_code; v_before := v_fp_status; v_after := v_fp_status;
          v_landed := v_fp_status = 'promoted';
        else
          v_outcome := 'not_needed';
          v_landed := true;
        end if;
      elsif v_waits is not null then
        v_outcome := 'skipped';
      elsif v_stat and (select count(*) from erp.entity e
                         where e.tenant_id = v_tenant and e.status = 'active') > 1 then
        -- The pack names no company, so its accounts land on the first one by
        -- code, and every other company would have books and nothing to post
        -- to. Refused until the numbering can be set up per company.
        v_outcome := 'refused';
        v_state := '23514';
        v_msg := 'CLOVEERP_STATUTORY_CHART_ONE_COMPANY: statutory numbering can be set up for one company only for now, and this organisation has more than one, so the books were not set up';
        v_hint := 'Keep the standard numbering while you have more than one company. The other sections that do not need the books still go in.';
      else
        v_before := null;

        -- The statutory chart ships its accounts as a pack, and the installer
        -- creates none of its own once that chart is on; so the pack lands
        -- first, reused when it was already applied.
        if v_need_chart then
          begin
            select tp.change_set_id into v_pack_cs
              from erp.tenant_pack tp
              join erp.change_set c on c.tenant_id = tp.tenant_id and c.id = tp.change_set_id
             where tp.tenant_id = v_tenant
               and tp.pack_code = 'chart_8_1'
               and tp.status in ('planned', 'applied')
               and c.status in ('draft', 'ready', 'approved', 'promoted')
             order by (c.status = 'promoted') desc, tp.created_at desc
             limit 1;

            if v_pack_cs is null then
              v_pack := erp.apply_content_pack('chart_8_1');
              v_pack_cs := (v_pack ->> 'change_set_id')::uuid;
            end if;

            select c.status::text into v_now
              from erp.change_set c where c.tenant_id = v_tenant and c.id = v_pack_cs;
            if v_now = 'draft' then
              perform erp.submit_change_set(v_pack_cs);
            end if;
          exception when others then
            get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate,
                                    v_detail = pg_exception_detail, v_hint = pg_exception_hint;
          end;

          if v_msg is null and not v_live then
            begin
              select c.status::text into v_now
                from erp.change_set c where c.tenant_id = v_tenant and c.id = v_pack_cs;
              if v_now = 'ready' then
                perform erp.approve_change_set(v_pack_cs);
                v_now := 'approved';
              end if;
              if v_now = 'approved' then
                perform erp.promote_change_set(v_pack_cs);
              end if;
            exception when others then
              get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate,
                                      v_detail = pg_exception_detail, v_hint = pg_exception_hint;
            end;
          end if;

          -- Read back rather than trusted: a variable set inside a block that
          -- was rolled back still holds what the block wrote into it.
          select c.id, c.code, c.status::text into v_cs, v_code, v_after
            from erp.change_set c where c.tenant_id = v_tenant and c.id = v_pack_cs;

          if v_msg is not null or v_after is distinct from 'promoted' then
            v_outcome := case
                           when v_msg like 'CLOVEERP_CHANGE_SET_APPROVAL_PENDING%' then 'awaiting_approval'
                           when v_msg is not null then 'refused'
                           else 'ready'
                         end;
          elsif not v_need_books then
            -- The accounts are in; nothing asked for the books yet.
            v_outcome := 'chart_applied';
            v_landed := true;
          end if;
        end if;

        if v_outcome is null then
          v_cs := null; v_code := null; v_after := null;
          v_before := v_fp_status;
          begin
            for v_ent in
              select e.id from erp.entity e
               where e.tenant_id = v_tenant and e.status = 'active'
                 and not exists (select 1 from erp.ledger l
                                  where l.tenant_id = v_tenant and l.entity_id = e.id and l.code = 'GL')
               order by e.code
            loop
              perform erp.configure_finance(null::integer, null::character, v_ent.id);
            end loop;

            -- Every company already had its ledgers, yet the rules were never
            -- installed: the installer is idempotent on a company it has seen.
            if not exists (select 1 from erp.change_set c
                            where c.tenant_id = v_tenant and c.code = 'finance-posting') then
              select e.id into v_first from erp.entity e
               where e.tenant_id = v_tenant and e.status = 'active'
               order by e.code limit 1;
              perform erp.configure_finance(null::integer, null::character, v_first);
            end if;
          exception when others then
            get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate,
                                    v_detail = pg_exception_detail, v_hint = pg_exception_hint;
          end;

          select c.id, c.code, c.status::text into v_cs, v_code, v_after
            from erp.change_set c
           where c.tenant_id = v_tenant and c.code = 'finance-posting';

          v_landed := coalesce(v_msg is null and v_after = 'promoted', false);

          -- The installer submits and approves in one call before go-live, so
          -- an approval chain on configuration changes refuses the approval
          -- and the whole call rolls back: the ledgers, the change and the
          -- approval request with them. Nothing is waiting for anybody, so
          -- this is a refusal with the way out, not a wait.
          if v_msg like 'CLOVEERP_CHANGE_SET_APPROVAL_PENDING%' then
            v_detail := v_msg;
            v_msg := 'CLOVEERP_FINANCE_SET_UP_HELD_BY_APPROVAL: the books could not be set up, because an approval chain on configuration changes asks for sign-off first and setting up the books is approved in the same step before go-live, so nothing was kept';
            v_hint := 'Take configuration changes out of the approval chain until the books are set up, then accept again; put the chain back afterwards.';
          end if;
          v_outcome := case when v_msg is not null then 'refused' else 'set_up' end;
        end if;
      end if;
    else
      select c.id, c.code, c.status::text into v_cs, v_code, v_before
        from erp_ai.proposal p
        join erp.change_set c on c.tenant_id = p.tenant_id and c.id = p.change_set_id
       where p.tenant_id = v_tenant
         and p.interview_session_id = p_session_id
         and p.interview_section = v_step
       order by p.created_at desc
       limit 1;

      -- A section that proposed nothing has nothing to accept.
      continue when v_cs is null;

      if v_before = 'promoted' then
        v_outcome := 'already_promoted';
        v_after := v_before;
        v_landed := true;
      elsif v_before not in ('draft', 'ready', 'approved') then
        -- Promoting, failed, rolled back or cancelled: not something
        -- accepting can move on from.
        v_outcome := 'not_acceptable';
        v_after := v_before;
      elsif v_waits is not null then
        v_outcome := 'skipped';
        v_after := v_before;
      else
        -- Submitting lands on its own.
        begin
          if v_before = 'draft' then
            perform erp.submit_change_set(v_cs);
          end if;
        exception when others then
          get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate,
                                  v_detail = pg_exception_detail, v_hint = pg_exception_hint;
        end;

        -- Approving and promoting land together, and only before go-live.
        if v_msg is null and not v_live then
          begin
            select c.status::text into v_now
              from erp.change_set c where c.tenant_id = v_tenant and c.id = v_cs;
            if v_now = 'ready' then
              perform erp.approve_change_set(v_cs);
              v_now := 'approved';
            end if;
            if v_now = 'approved' then
              perform erp.promote_change_set(v_cs);
            end if;
          exception when others then
            get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate,
                                    v_detail = pg_exception_detail, v_hint = pg_exception_hint;
          end;
        end if;

        select c.status::text into v_after
          from erp.change_set c where c.tenant_id = v_tenant and c.id = v_cs;

        v_landed := coalesce(v_after = 'promoted', false);
        v_outcome := case
                       when v_msg like 'CLOVEERP_CHANGE_SET_APPROVAL_PENDING%' then 'awaiting_approval'
                       when v_msg is not null then 'refused'
                       when v_landed then 'promoted'
                       else 'ready'
                     end;
      end if;
    end if;

    if v_outcome in ('refused', 'skipped', 'not_acceptable') then
      v_blocked := array_append(v_blocked, v_step);
    elsif not v_landed then
      v_unlanded := array_append(v_unlanded, v_step);
    end if;

    if v_outcome in ('refused', 'not_acceptable') then
      v_n_refused := v_n_refused + 1;
    elsif v_outcome <> 'not_needed' and v_landed then
      v_n_landed := v_n_landed + 1;
    elsif v_outcome <> 'not_needed' then
      v_n_waiting := v_n_waiting + 1;
    end if;

    v_steps := v_steps || jsonb_build_array(jsonb_build_object(
      'step', v_step,
      'change_set_id', v_cs,
      'change_set_code', v_code,
      'status_before', v_before,
      'status', v_after,
      'outcome', v_outcome,
      'waits_for', case when v_outcome = 'skipped' then v_waits end,
      'refusal', case when v_msg is not null then jsonb_build_object(
                   'code', coalesce(substring(v_msg from '^(CLOVEERP_[A-Z0-9_]+)'), v_state),
                   'message', v_msg,
                   'detail', nullif(v_detail, ''),
                   'hint', nullif(v_hint, '')) end));
  end loop;

  return jsonb_build_object(
    'interview', s.code,
    'live', v_live,
    'stops_at', case when v_live then 'ready' else 'promoted' end,
    'steps', v_steps,
    'landed', v_n_landed,
    'waiting', v_n_waiting,
    'refused', v_n_refused);
end;
$$;

revoke all on function erp_ai.accept_interview(uuid) from public, anon;

comment on function erp_ai.accept_interview(uuid) is
  'Accepts a proposed onboarding interview, section by section in the order '
  'organisation, finance, departments, approvals, accounting codes, product '
  'classification, product codes, marshalling areas. Submits each section''s '
  'change set; before go-live also approves and promotes it, as the module '
  'installers do; after go-live stops at ready. Brings in the §8.1 chart pack '
  'whenever that chart is on and no nominal account exists, and sets finance '
  'up when accounting codes were proposed and finance is not installed or a '
  'company has no general ledger; the statutory chart is refused with more '
  'than one company. Reports each section''s outcome and '
  'refusal rather than raising, and picks up where each section stands when '
  'run again. Never changes a proposal''s status, producer or reviewer.';

create or replace function public.erp_accept_interview(p_session_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure');
  return erp_ai.accept_interview(p_session_id);
end;
$$;

revoke all on function public.erp_accept_interview(uuid) from public, anon;
grant execute on function public.erp_accept_interview(uuid) to authenticated, service_role;

comment on function public.erp_accept_interview(uuid) is
  'Accepts a proposed onboarding interview under administration.configure. '
  'Approving and promoting still ask for administration.promote, and setting '
  'finance up for finance.configure; a section refused for want of either is '
  'reported, not raised.';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_accept_interview', 'erp.authorise',
   'Accepts a proposed onboarding interview under administration.configure: submits each section''s change set and, before go-live, approves and promotes it through the change-set functions, setting finance up first when accounting codes were proposed. Writes no configuration of its own.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- ═════════════════════════════════════════════════════════════════════════════
-- 2. The change-set list says who may approve
-- ═════════════════════════════════════════════════════════════════════════════

-- Same signature and return type as 20260829190000, so the grants stay.
create or replace function public.erp_change_sets()
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'change_set_id', c.id, 'code', c.code, 'name', c.name,
           'status', c.status, 'created_at', c.created_at,
           'authored_by', a.display_name,
           -- What a reviewer needs before approving: whether they wrote it,
           'is_own', c.created_by = erp.current_principal_id(),
           -- and whether that stops them, which it does only once the
           -- organisation is live.
           'may_approve', not coalesce(erp.tenant_is_live(c.tenant_id)
                                       and c.created_by = erp.current_principal_id(), false))
           -- The sections of one interview share a timestamp.
           order by c.created_at desc, c.code), '[]'::jsonb)
    from erp.change_set c
    left join erp.app_user a on a.tenant_id = c.tenant_id and a.id = c.created_by
   where c.tenant_id = erp.current_tenant_id()
$$;

-- ═════════════════════════════════════════════════════════════════════════════
-- 3. The copy that described the interview wrongly
-- ═════════════════════════════════════════════════════════════════════════════

do $copy$
declare
  v_n integer;
begin
  -- The onboarding screen's help was the invitations topic.
  update erp_ref.help_topic h set
    summary = 'The onboarding interview: how this organisation works, asked one section at a time with likely answers to pick from. Your answers become proposed changes you can read line by line, then accept.',
    steps = '["Start the interview, or carry on with the one you left open.","Answer the organisation section first, then the rest; pick a suggestion or type your own, and skip what does not apply.","Propose: each section becomes a change, shown line by line.","Accept: before go-live the changes are put in force in order, and finance is set up when you proposed accounting codes; after go-live they wait for a second administrator to approve them on Configuration."]'::jsonb,
    next_action = 'Answer the organisation section first: finance and everything after it build on it.',
    actions = (select array_agg(distinct x.a order by x.a)
                 from unnest(array_remove(h.actions, 'erp_invite_principal')
                             || array['erp_start_interview', 'erp_interview_sessions', 'erp_interview_questions',
                                      'erp_answer_interview', 'erp_propose_from_interview', 'erp_proposals',
                                      'erp_change_set_items', 'erp_accept_interview']) as x(a))
   where h.screen_path = '/administration/onboarding';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_COPY_TARGET_MISSING: % help topic(s) for /administration/onboarding, expected 1', v_n
      using hint = 'The topic is seeded by 20260904500000; this migration corrects its words and cannot insert it.';
  end if;

  -- First-run step 1 invites a second administrator, which happens on
  -- Permissions.
  update erp_ref.first_run_step s
     set screen_path = '/administration/permissions'
   where s.guide_code = 'administrator' and s.seq = 1
     and s.screen_path = '/administration/onboarding';
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_COPY_TARGET_MISSING: % administrator first-run step 1 row(s) on /administration/onboarding, expected 1', v_n
      using hint = 'The step is seeded by 20260904500000; check whether its screen was already corrected.';
  end if;

  -- First-run step 4 approves configuration, which happens on Configuration,
  -- not on master-data change requests; and before go-live the author may.
  update erp_ref.first_run_step s
     set screen_path = '/administration/configuration',
         action_label = 'Open configuration',
         why = 'Before go-live you may approve and promote your own changes. After it, somebody other than the author approves each one; until a change is promoted it is not in force.'
   where s.guide_code = 'administrator' and s.seq = 4;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'CLOVEERP_COPY_TARGET_MISSING: % administrator first-run step 4 row(s), expected 1', v_n
      using hint = 'The step is seeded by 20260904500000.';
  end if;

  -- Five walkthrough reasons: a default the interview never proposes, a chart
  -- the base pack never ships, and a screen that does not approve changes.
  update erp_ref.setup_step s set why = v.why
    from (values
      ('onboarding.start',
       'Each answer becomes configuration, proposed as a change you can read before anything takes effect.'),
      ('onboarding.answer',
       'Questions offer suggestions and, where one can be worked out, a likely answer; pick one or type your own, and skip what does not apply. A question left unanswered proposes nothing.'),
      ('onboarding.propose',
       'Each section becomes a change listed line by line. Before go-live, accepting puts them in force in order; after it, a second administrator approves them on Configuration.'),
      ('packs.base',
       'The base pack brings departments, roles, accounting codes, units of measure and reason codes, as a change to approve. It brings no chart of accounts: setting up finance creates the standard one, and the statutory chart is a pack of its own.'),
      ('configuration.promote',
       'Nothing takes effect until a change is approved and promoted, here on Configuration. Before go-live you may approve your own; after it, a second administrator must.')
    ) as v(code, why)
   where s.code = v.code;
  get diagnostics v_n = row_count;
  if v_n <> 5 then
    raise exception 'CLOVEERP_COPY_TARGET_MISSING: % of 5 setup steps found to reword', v_n
      using hint = 'The steps are registered by 20260913022000; a code changed name.';
  end if;

  update erp_ref.setup_screen sc set blurb = v.blurb
    from (values
      ('/administration/onboarding',
       'Answer the interview a section at a time, organisation first. Your answers become changes you read and accept.'),
      ('/administration/packs',
       'Features first, then the starter packs of departments, roles and codes, each arriving as a change to approve.')
    ) as v(path, blurb)
   where sc.screen_path = v.path;
  get diagnostics v_n = row_count;
  if v_n <> 2 then
    raise exception 'CLOVEERP_COPY_TARGET_MISSING: % of 2 setup screens found to reword', v_n
      using hint = 'The screens are registered by 20260913022000; a path changed.';
  end if;
end
$copy$;

-- Inviting keeps a home now that the onboarding topic no longer carries it.
select erp_meta.add_help_actions('/administration/permissions', array['erp_invite_principal']);

select erp.assert_guidance_sound();
select erp.assert_first_run_guidance_actionable();
select erp.assert_setup_walkthrough_actionable();
select erp_test.assert_setup_walkthrough_suite();

-- ═════════════════════════════════════════════════════════════════════════════
-- 4. The suite
-- ═════════════════════════════════════════════════════════════════════════════
--
-- Seven organisations, each with its own sign-in:
--   zzease1  not live; answering, never proposed               cases 1-4, 14
--   zzease2  not live, no finance, one site                    cases 4-10
--   zzease3  not live, finance installed first                 cases 12, 16, 17
--   zzease4  not live, no finance; the statutory chart         case 11
--   zzease5  live, with a second administrator                 case 13
--   zzease6  not live; a department and a grouping exist       case 15
--   zzease7  not live; the statutory chart and nothing else    case 18

create or replace function erp_test.interview_ease_suite()
returns table(case_name text, passed boolean, detail text)
language plpgsql
set search_path = ''
as $$
declare
  a1 uuid := gen_random_uuid();
  a2 uuid := gen_random_uuid();
  a3 uuid := gen_random_uuid();
  a4 uuid := gen_random_uuid();
  a5 uuid := gen_random_uuid();
  a6 uuid := gen_random_uuid();
  a7 uuid := gen_random_uuid();
  a8 uuid := gen_random_uuid();
  v        jsonb;
  q        jsonb;
  res      jsonb;
  res2     jsonb;
  res3     jsonb;
  t1 uuid; t2 uuid; t3 uuid; t4 uuid; t5 uuid; t6 uuid; t7 uuid;
  e2 uuid;
  s1a uuid; s1b uuid; s2 uuid; s3 uuid; s4 uuid; s5 uuid;
  s1c uuid; s3b uuid; s6 uuid; s7 uuid;
  v_cs2 uuid;
  v_u7  uuid;
  v_b1 uuid; v_b2 uuid; v_b3 uuid; v_b7 uuid;
  v_u6     uuid;
  v_tok    text;
  v_ok1 boolean; v_ok2 boolean; v_ok3 boolean; v_ok4 boolean; v_ok5 boolean; v_ok6 boolean;
  v_msg    text;
  v_msg2   text;
  v_state  text;
  v_n      bigint;
  v_m      bigint;
  v_steps  text[];
  v_err    text;
  v_err_detail text;
  v_err_ctx    text;
  v_tenants uuid[];
  v_t      uuid;
begin
  begin
    insert into auth.users (id, email) values
      (a1, 'ease1@zzease1.test'),
      (a2, 'ease2@zzease2.test'),
      (a3, 'ease3@zzease3.test'),
      (a4, 'ease4@zzease4.test'),
      (a5, 'author@zzease5.test'),
      (a6, 'second@zzease5.test'),
      (a7, 'ease6@zzease6.test'),
      (a8, 'ease7@zzease7.test');

    -- ── zzease1: answering ────────────────────────────────────────────────

    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v := erp.onboard_tenant('Ease one', 'zzease1');
    t1 := (v ->> 'tenant_id')::uuid;
    s1a := (public.erp_start_interview('ease-1a') ->> 'session_id')::uuid;
    s1b := (public.erp_start_interview('ease-1b') ->> 'session_id')::uuid;

    -- 1
    v := public.erp_interview_questions(s1a);

    v_ok1 := jsonb_typeof(v) = 'array'
      and jsonb_array_length(v) = (select count(*) from erp_ref.interview_question)
      and not exists (
        select 1 from jsonb_array_elements(v) as x(el)
         where not (x.el ? 'suggestions' and x.el ? 'left_suggestions' and x.el ? 'likely'
                    and x.el ? 'example' and x.el ? 'applies_when'));

    v_ok2 := not exists (
      select 1 from jsonb_array_elements(v) as x(el)
       where x.el ->> 'answer_shape' = 'boolean'
         and not coalesce((
           select count(*) = 2
                  and array_agg(sg.el ->> 'value' order by sg.el ->> 'value') = array['false', 'true']
                  and bool_and(coalesce(btrim(sg.el ->> 'label'), '') <> '')
             from jsonb_array_elements(case when jsonb_typeof(x.el -> 'suggestions') = 'array'
                                            then x.el -> 'suggestions' else '[]'::jsonb end) as sg(el)), false));

    v_ok3 := not exists (
      select 1 from jsonb_array_elements(v) as x(el)
       where x.el ->> 'answer_shape' = 'choice'
         and not coalesce((
           select (select array_agg(ch.c order by ch.c)
                     from jsonb_array_elements_text(coalesce(x.el -> 'choices', '[]'::jsonb)) as ch(c))
                  = array_agg(sg.el ->> 'value' order by sg.el ->> 'value')
                  and bool_and(coalesce(btrim(sg.el ->> 'label'), '') <> '')
             from jsonb_array_elements(case when jsonb_typeof(x.el -> 'suggestions') = 'array'
                                            then x.el -> 'suggestions' else '[]'::jsonb end) as sg(el)), false));

    select x.el into q from jsonb_array_elements(v) as x(el) where x.el ->> 'code' = 'approval.threshold';
    v_ok4 := q is not null
      and coalesce(btrim(q ->> 'example'), '') <> ''
      and coalesce(q -> 'likely', 'null'::jsonb) = 'null'::jsonb
      and jsonb_array_length(case when jsonb_typeof(q -> 'suggestions') = 'array'
                                  then q -> 'suggestions' else '[]'::jsonb end) = 0;

    select x.el into q from jsonb_array_elements(v) as x(el) where x.el ->> 'code' = 'org.fiscal_year_start';
    v_ok5 := q is not null
      and (select array_agg(sg.el ->> 'value' order by sg.el ->> 'value')
             from jsonb_array_elements(case when jsonb_typeof(q -> 'suggestions') = 'array'
                                            then q -> 'suggestions' else '[]'::jsonb end) as sg(el))
          = array(select g::text from generate_series(1, 12) as g order by g::text);

    select x.el into q from jsonb_array_elements(v) as x(el) where x.el ->> 'code' = 'dept.list';
    v_ok6 := q is not null
      and exists (select 1 from jsonb_array_elements(case when jsonb_typeof(q -> 'suggestions') = 'array'
                                                          then q -> 'suggestions' else '[]'::jsonb end) as sg(el)
                   where sg.el ->> 'value' = 'FIN' and sg.el ->> 'code' = 'FIN'
                     and coalesce(btrim(sg.el ->> 'label'), '') <> '')
      and not exists (select 1 from jsonb_array_elements(case when jsonb_typeof(q -> 'suggestions') = 'array'
                                                              then q -> 'suggestions' else '[]'::jsonb end) as sg(el)
                       where (sg.el ->> 'value') is distinct from (sg.el ->> 'code'));

    case_name := 'every question comes back with what to pick from, and every choice with a label';
    passed := coalesce(v_ok1 and v_ok2 and v_ok3 and v_ok4 and v_ok5 and v_ok6, false);
    detail := format('keys on every question %s; booleans offer yes and no %s; choices labelled one per value %s; '
                     'threshold has an example and no likely answer %s; twelve months %s; starter departments by code %s',
                     v_ok1, v_ok2, v_ok3, v_ok4, v_ok5, v_ok6);
    return next;

    -- 2
    perform public.erp_answer_interview(s1a, 'org.multi_company', 'true'::jsonb);
    perform public.erp_answer_interview(s1a, 'org.companies', '[{"left":"ZZ-IE","right":"Zz Ireland"}]'::jsonb);
    perform public.erp_answer_interview(s1a, 'approval.needed', 'true'::jsonb);
    v := public.erp_interview_questions(s1a);

    select x.el into q from jsonb_array_elements(v) as x(el) where x.el ->> 'code' = 'org.legislation';
    v_ok1 := q is not null
      and exists (select 1 from jsonb_array_elements(case when jsonb_typeof(q -> 'likely') = 'array'
                                                          then q -> 'likely' else '[]'::jsonb end) as l(el)
                   where l.el ->> 'left' = 'MAIN' and l.el ->> 'right' = 'gb_vat');
    v_ok2 := q is not null
      and exists (select 1 from jsonb_array_elements(case when jsonb_typeof(q -> 'left_suggestions') = 'array'
                                                          then q -> 'left_suggestions' else '[]'::jsonb end) as l(el)
                   where l.el ->> 'value' = 'MAIN' and l.el -> 'present' = 'true'::jsonb)
      and exists (select 1 from jsonb_array_elements(case when jsonb_typeof(q -> 'left_suggestions') = 'array'
                                                          then q -> 'left_suggestions' else '[]'::jsonb end) as l(el)
                   where l.el ->> 'value' = 'ZZ-IE');
    v_ok3 := q is not null
      and exists (select 1 from jsonb_array_elements(case when jsonb_typeof(q -> 'suggestions') = 'array'
                                                          then q -> 'suggestions' else '[]'::jsonb end) as sg(el)
                   where sg.el ->> 'value' = 'gb_vat')
      and not exists (select 1 from jsonb_array_elements(case when jsonb_typeof(q -> 'suggestions') = 'array'
                                                              then q -> 'suggestions' else '[]'::jsonb end) as sg(el)
                       where sg.el ->> 'value' = 'example_vat');
    v_msg := q ->> 'likely';

    select x.el into q from jsonb_array_elements(v) as x(el) where x.el ->> 'code' = 'approval.currency';
    v_ok4 := q is not null and q ->> 'likely' = 'GBP';
    v_ok5 := not exists (select 1 from erp.interview_answer ia
                          where ia.tenant_id = t1 and ia.session_id = s1a
                            and ia.question_code in ('org.legislation', 'approval.currency'));

    case_name := 'likely answers are worked out from the organisation and never stored';
    passed := coalesce(v_ok1 and v_ok2 and v_ok3 and v_ok4 and v_ok5, false);
    detail := format('MAIN likely under gb_vat %s (likely %s); companies to the left, answered and existing %s; '
                     'packs offered without the illustrative one %s; approval currency likely GBP %s; nothing stored %s',
                     v_ok1, coalesce(v_msg, 'null'), v_ok2, v_ok3, v_ok4, v_ok5);
    return next;

    -- 3
    v_msg := null;
    begin
      perform public.erp_answer_interview(s1a, 'approval.threshold', '"5,000"'::jsonb);
      select ia.answer into q from erp.interview_answer ia
       where ia.tenant_id = t1 and ia.session_id = s1a and ia.question_code = 'approval.threshold';
      v_ok1 := jsonb_typeof(q) = 'number' and q = '5000'::jsonb;
      v_msg := coalesce(q::text, 'nothing stored');
    exception when others then
      v_ok1 := false; v_msg := left(sqlerrm, 80);
    end;

    begin
      perform public.erp_answer_interview(s1a, 'approval.threshold', '"five"'::jsonb);
      v_ok2 := false; v_msg2 := 'a word was accepted as a number';
    exception when others then
      v_ok2 := sqlerrm like 'CLOVEERP_ANSWER_SHAPE%'; v_msg2 := left(sqlerrm, 60);
    end;

    begin
      perform erp.answer_interview(s1a, 'approval.threshold', null::jsonb);
      v_ok3 := false;
    exception when others then
      get stacked diagnostics v_state = returned_sqlstate;
      v_ok3 := sqlerrm like 'CLOVEERP_%' and v_state <> '23502';
    end;

    begin
      res := public.erp_answer_interview(s1a, 'approval.threshold', null::jsonb);
      v_ok4 := coalesce(res -> 'cleared' = 'true'::jsonb, false)
        and not exists (select 1 from erp.interview_answer ia
                         where ia.tenant_id = t1 and ia.session_id = s1a and ia.question_code = 'approval.threshold');
    exception when others then
      v_ok4 := false; v_msg2 := v_msg2 || '; clearing: ' || left(sqlerrm, 60);
    end;

    case_name := 'a number typed with a comma is stored as a number, and an answer can be cleared';
    passed := coalesce(v_ok1 and v_ok2 and v_ok3 and v_ok4, false);
    detail := format('"5,000" stored as %s (%s); a word refused %s (%s); a missing answer refused by name %s; cleared from the screen %s',
                     v_msg, v_ok1, v_ok2, v_msg2, v_ok3, v_ok4);
    return next;

    -- 4, first half: two open interviews to come back to.
    v := public.erp_interview_sessions();
    v_ok1 := v -> 'live' = 'false'::jsonb
      and exists (
        select 1 from jsonb_array_elements(case when jsonb_typeof(v -> 'sessions') = 'array'
                                                then v -> 'sessions' else '[]'::jsonb end) as x(el)
         where x.el ->> 'code' = 'ease-1a' and x.el ->> 'status' = 'open'
           and array(select sc.el ->> 'section'
                       from jsonb_array_elements(case when jsonb_typeof(x.el -> 'sections') = 'array'
                                                      then x.el -> 'sections' else '[]'::jsonb end)
                            with ordinality as sc(el, ord)
                      order by sc.ord) = array['B.7', 'B.1', 'B.2', 'B.3', 'B.4', 'B.5', 'B.6']
           and exists (select 1 from jsonb_array_elements(case when jsonb_typeof(x.el -> 'sections') = 'array'
                                                               then x.el -> 'sections' else '[]'::jsonb end) as sc(el)
                        where sc.el ->> 'section' = 'B.7' and coalesce((sc.el ->> 'answered')::integer, 0) >= 1))
      and exists (
        select 1 from jsonb_array_elements(case when jsonb_typeof(v -> 'sessions') = 'array'
                                                then v -> 'sessions' else '[]'::jsonb end) as x(el)
         where x.el ->> 'code' = 'ease-1b' and x.el ->> 'status' = 'open'
           and not exists (select 1 from jsonb_array_elements(case when jsonb_typeof(x.el -> 'sections') = 'array'
                                                                   then x.el -> 'sections' else '[]'::jsonb end) as sc(el)
                            where coalesce((sc.el ->> 'answered')::integer, 0) <> 0));
    v_msg := null;
    begin
      perform public.erp_answer_interview(s1a, 'code.wanted', 'false'::jsonb);
      v_ok2 := true;
    exception when others then
      v_ok2 := false; v_msg := left(sqlerrm, 60);
    end;

    -- ── zzease5, set up now: live, with a second administrator ───────────
    --
    -- Taken live before the other organisations install anything, so going
    -- live is judged on this organisation and the product's own registers
    -- alone. Its interview is case 13.

    perform set_config('request.jwt.claims', json_build_object('sub', a5)::text, true);
    v := erp.onboard_tenant('Ease five', 'zzease5');
    t5 := (v ->> 'tenant_id')::uuid;
    perform erp.configure_finance();
    v := public.erp_invite_principal('second@zzease5.test', 'Second Admin');
    v_u6 := (v ->> 'app_user_id')::uuid;
    v_tok := v ->> 'token';
    perform erp.grant_role(v_u6, 'administrator', null, null, 'co-administrator');
    perform set_config('request.jwt.claims', json_build_object('sub', a6)::text, true);
    perform erp.claim_invitation(v_tok);
    perform set_config('request.jwt.claims', json_build_object('sub', a5)::text, true);
    perform erp.go_live();

    -- ── zzease2: proposing, reading and accepting ────────────────────────

    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    v := erp.onboard_tenant('Ease two', 'zzease2');
    t2 := (v ->> 'tenant_id')::uuid;
    e2 := (v ->> 'entity_id')::uuid;

    -- A site, because a site's own stock policy is proposed below. Business
    -- data, not a configuration surface, so it is written directly.
    insert into erp.site (tenant_id, entity_id, code, name, site_type)
    values (t2, e2, 'MAIN', 'Main', 'warehouse');

    s2 := (public.erp_start_interview('ease-2') ->> 'session_id')::uuid;
    perform public.erp_answer_interview(s2, 'dept.list', '[{"code":"FIN","name":"Finance"},"Operations"]'::jsonb);
    perform public.erp_answer_interview(s2, 'approval.needed', 'true'::jsonb);
    perform public.erp_answer_interview(s2, 'approval.object_type', '"purchase_order"'::jsonb);
    perform public.erp_answer_interview(s2, 'approval.currency', '"GBP"'::jsonb);
    perform public.erp_answer_interview(s2, 'approval.threshold', '5000'::jsonb);
    perform public.erp_answer_interview(s2, 'approval.role', '"administrator"'::jsonb);
    perform public.erp_answer_interview(s2, 'approval.line_manager', 'false'::jsonb);
    perform public.erp_answer_interview(s2, 'posting.item_classes', '[{"code":"FG","name":"Finished good"}]'::jsonb);
    perform public.erp_answer_interview(s2, 'posting.receipt_account', '"1200"'::jsonb);
    perform public.erp_answer_interview(s2, 'code.wanted', 'true'::jsonb);
    perform public.erp_answer_interview(s2, 'code.prefix', '"IT"'::jsonb);
    perform public.erp_answer_interview(s2, 'code.wanted', 'false'::jsonb);
    perform public.erp_answer_interview(s2, 'org.policies_differ', 'true'::jsonb);
    perform public.erp_answer_interview(s2, 'org.identity_by_class', '[{"left":"FG","right":"pallet"}]'::jsonb);
    perform public.erp_answer_interview(s2, 'org.allocation_by_site', '[{"left":"MAIN","right":"lifo"}]'::jsonb);

    res := public.erp_propose_from_interview(s2);

    select (x.el ->> 'change_set_id')::uuid into v_b1 from jsonb_array_elements(res -> 'proposals') as x(el) where x.el ->> 'section' = 'B.1';
    select (x.el ->> 'change_set_id')::uuid into v_b2 from jsonb_array_elements(res -> 'proposals') as x(el) where x.el ->> 'section' = 'B.2';
    select (x.el ->> 'change_set_id')::uuid into v_b3 from jsonb_array_elements(res -> 'proposals') as x(el) where x.el ->> 'section' = 'B.3';
    select (x.el ->> 'change_set_id')::uuid into v_b7 from jsonb_array_elements(res -> 'proposals') as x(el) where x.el ->> 'section' = 'B.7';

    -- 4, second half: a proposed interview is listed as proposed and is closed.
    v := public.erp_interview_sessions();
    v_ok3 := exists (
      select 1 from jsonb_array_elements(case when jsonb_typeof(v -> 'sessions') = 'array'
                                              then v -> 'sessions' else '[]'::jsonb end) as x(el)
       where x.el ->> 'code' = 'ease-2' and x.el ->> 'status' = 'proposed'
         and array(select p.el ->> 'section'
                     from jsonb_array_elements(case when jsonb_typeof(x.el -> 'proposals') = 'array'
                                                    then x.el -> 'proposals' else '[]'::jsonb end)
                          with ordinality as p(el, ord)
                    order by p.ord)
             = array(select o.sec
                       from unnest(array['B.7', 'B.1', 'B.2', 'B.3', 'B.4', 'B.5', 'B.6']) with ordinality as o(sec, ord)
                      where o.sec in (select y.el ->> 'section' from jsonb_array_elements(res -> 'proposals') as y(el))
                      order by o.ord)
         and not exists (select 1 from jsonb_array_elements(case when jsonb_typeof(x.el -> 'proposals') = 'array'
                                                                 then x.el -> 'proposals' else '[]'::jsonb end) as p(el)
                          where (p.el ->> 'change_set_status') is distinct from 'draft'));
    begin
      perform public.erp_answer_interview(s2, 'code.digits', '6'::jsonb);
      v_ok4 := false; v_msg2 := 'a proposed interview took another answer';
    exception when others then
      v_ok4 := sqlerrm like 'CLOVEERP_INTERVIEW_NOT_OPEN%'; v_msg2 := left(sqlerrm, 60);
    end;

    case_name := 'the sessions list shows what to come back to, and what has been proposed';
    passed := coalesce(v_ok1 and v_ok2 and v_ok3 and v_ok4, false);
    detail := format('two open interviews, by section in the screen''s order %s; answering one again %s%s; '
                     'the proposed one listed with its proposals %s; and closed to answers %s (%s)',
                     v_ok1, v_ok2, coalesce(' (' || v_msg || ')', ''), v_ok3, v_ok4, v_msg2);
    return next;

    -- 5
    v_ok1 := (select array_agg(i.object_key order by i.object_key)
                from erp.change_set_item i
               where i.tenant_id = t2 and i.change_set_id = v_b1 and i.object_kind = 'department')
             = array['FIN', 'OPERATIONS'];
    v_ok2 := exists (select 1 from erp.change_set_item i
                      where i.tenant_id = t2 and i.change_set_id = v_b3
                        and i.object_kind = 'posting_class' and i.object_key = 'item|FG');
    case_name := 'a starter suggestion keeps its code, and a typed name is still made into one';
    passed := coalesce(v_ok1 and v_ok2, false);
    detail := format('departments %s; accounting code item|FG %s',
                     coalesce((select string_agg(i.object_key, ', ' order by i.object_key)
                                 from erp.change_set_item i
                                where i.tenant_id = t2 and i.change_set_id = v_b1 and i.object_kind = 'department'), 'none'),
                     v_ok2);
    return next;

    -- 6
    v_ok1 := not exists (select 1 from jsonb_array_elements(res -> 'proposals') as x(el) where x.el ->> 'section' = 'B.5');
    v_ok2 := not exists (select 1 from erp.change_set_item i
                           join erp_ai.proposal p on p.tenant_id = i.tenant_id and p.change_set_id = i.change_set_id
                          where i.tenant_id = t2 and i.object_kind = 'code_template');
    v_ok3 := not exists (select 1 from erp_ai.proposal_evidence ev
                          where ev.tenant_id = t2 and ev.source_ref = 'code.prefix');
    v_ok4 := v_b2 is not null;
    case_name := 'an answer whose question no longer applies is not proposed';
    passed := coalesce(v_ok1 and v_ok2 and v_ok3 and v_ok4, false);
    detail := format('no product-code section %s; no code template %s; no evidence from the prefix %s; approvals still proposed %s',
                     v_ok1, v_ok2, v_ok3, v_ok4);
    return next;

    -- 7
    v_ok1 := exists (select 1 from erp.change_set_item i
                      where i.tenant_id = t2 and i.change_set_id = v_b7
                        and i.object_kind = 'container_identity_policy' and i.object_key = 'CLASS-FG');
    v_ok2 := exists (select 1 from erp.change_set_item i
                      where i.tenant_id = t2 and i.change_set_id = v_b7
                        and i.object_kind = 'config' and i.object_key = 'stock.allocation_policy|*|MAIN');
    case_name := 'a policy that differs by class or by site, answered as left and right, is proposed';
    passed := coalesce(v_ok1 and v_ok2, false);
    detail := format('organisation section %s; identity for FG %s; allocation at MAIN %s',
                     coalesce(v_b7::text, 'not proposed'), v_ok1, v_ok2);
    return next;

    -- 8
    v_msg2 := null; v_n := null; v_m := null; v_ok1 := false; v_ok2 := false;
    begin
      v_ok1 := jsonb_array_length(res -> 'proposals') > 0
        and not exists (
          select 1 from jsonb_array_elements(res -> 'proposals') as x(el)
           where jsonb_array_length(public.erp_change_set_items((x.el ->> 'change_set_id')::uuid))
                 <> (select count(*) from erp.change_set_item i
                      where i.tenant_id = t2 and i.change_set_id = (x.el ->> 'change_set_id')::uuid));
      if v_b1 is not null then
        v_ok2 := not exists (
          select 1 from jsonb_array_elements(public.erp_change_set_items(v_b1)) as o(el)
           where not (o.el ? 'item_id' and o.el ? 'object_kind' and o.el ? 'object_key' and o.el ? 'payload'));
      end if;
      if v_b7 is not null then
        select min(o.ord) filter (where o.el ->> 'object_kind' = 'config'),
               min(o.ord) filter (where o.el ->> 'object_kind' = 'container_identity_policy')
          into v_n, v_m
          from jsonb_array_elements(public.erp_change_set_items(v_b7)) with ordinality as o(el, ord);
      end if;
    exception when others then
      v_msg2 := left(sqlerrm, 90);
    end;
    v_ok3 := coalesce(v_n < v_m, false);
    begin
      perform public.erp_change_set_items(gen_random_uuid());
      v_ok4 := false; v_msg := 'a change nobody made was listed';
    exception when others then
      v_ok4 := sqlerrm like 'CLOVEERP_CHANGE_SET_NOT_FOUND%'; v_msg := left(sqlerrm, 60);
    end;
    case_name := 'each proposed change is listed item by item, in the order it would be put in force';
    passed := coalesce(v_msg2 is null and v_ok1 and v_ok2 and v_ok3 and v_ok4, false);
    detail := format('every item listed %s; each with its kind, key and payload %s; a setting before a handling-unit policy %s (%s, %s); '
                     'an unknown change refused %s (%s)%s',
                     v_ok1, v_ok2, v_ok3, coalesce(v_n::text, '-'), coalesce(v_m::text, '-'), v_ok4, v_msg,
                     coalesce('; reading raised ' || v_msg2, ''));
    return next;

    -- 9
    res2 := public.erp_accept_interview(s2);
    v_steps := array(select x.el ->> 'step'
                       from jsonb_array_elements(res2 -> 'steps') with ordinality as x(el, ord)
                      order by x.ord);
    v_ok1 := v_steps = array['B.7', 'finance', 'B.1', 'B.2', 'B.3'];
    v_ok2 := res2 -> 'live' = 'false'::jsonb and res2 ->> 'stops_at' = 'promoted'
      and not exists (select 1 from jsonb_array_elements(res2 -> 'steps') as x(el)
                       where x.el ->> 'step' <> 'finance' and (x.el ->> 'outcome') is distinct from 'promoted')
      and exists (select 1 from jsonb_array_elements(res2 -> 'steps') as x(el)
                   where x.el ->> 'step' = 'finance' and x.el ->> 'outcome' = 'set_up');
    v_ok3 := exists (select 1 from erp.department d where d.tenant_id = t2 and d.code = 'FIN' and d.status = 'active')
      and exists (select 1 from erp.department d where d.tenant_id = t2 and d.code = 'OPERATIONS' and d.status = 'active')
      and (select count(*) from erp.approval_band ab
             join erp.department d on d.tenant_id = ab.tenant_id and d.id = ab.department_id
            where ab.tenant_id = t2 and d.code in ('FIN', 'OPERATIONS') and ab.status = 'active') = 2;
    v_ok4 := not exists (select 1 from erp_ai.proposal p
                           join erp.change_set c on c.tenant_id = p.tenant_id and c.id = p.change_set_id
                          where p.tenant_id = t2 and c.status <> 'promoted');
    case_name := 'accepting before go-live puts every section in force, organisation and finance first';
    passed := coalesce(v_ok1 and v_ok2 and v_ok3 and v_ok4, false);
    detail := format('order %s %s; outcomes %s: %s; departments and their bands %s; every proposed change promoted %s',
                     array_to_string(v_steps, ' > '), v_ok1, v_ok2,
                     coalesce((select string_agg(format('%s %s%s', x.el ->> 'step', x.el ->> 'outcome',
                                                        coalesce(' [' || (x.el -> 'refusal' ->> 'message') || ']', '')),
                                                 '; ' order by x.ord)
                                 from jsonb_array_elements(res2 -> 'steps') with ordinality as x(el, ord)), 'none'),
                     v_ok3, v_ok4);
    return next;

    -- 10
    v_ok1 := exists (select 1 from erp.module_installation m where m.tenant_id = t2 and m.module_code = 'finance');
    v_ok2 := exists (select 1 from erp.account_determination ad
                       join erp.account a on a.tenant_id = ad.tenant_id and a.id = ad.account_id
                      where ad.tenant_id = t2 and ad.transaction_type = 'goods_receipt'
                        and a.code = '1200' and ad.status = 'active');
    select count(*) into v_n from erp.change_set c where c.tenant_id = t2;
    res3 := public.erp_accept_interview(s2);
    select count(*) into v_m from erp.change_set c where c.tenant_id = t2;
    v_ok3 := v_n = v_m
      and jsonb_array_length(res3 -> 'steps') = jsonb_array_length(res2 -> 'steps')
      and not exists (select 1 from jsonb_array_elements(res3 -> 'steps') as x(el)
                       where (x.el ->> 'outcome') not in ('already_promoted', 'already_set_up'));
    case_name := 'accepting sets finance up when accounting codes were proposed, and accepting again changes nothing';
    passed := coalesce(v_ok1 and v_ok2 and v_ok3, false);
    detail := format('finance installed %s; goods received reach 1200 %s; second acceptance %s: %s',
                     v_ok1, v_ok2, v_ok3,
                     coalesce((select string_agg(format('%s %s', x.el ->> 'step', x.el ->> 'outcome'), '; ' order by x.ord)
                                 from jsonb_array_elements(res3 -> 'steps') with ordinality as x(el, ord)), 'none'));
    return next;

    -- ── zzease4: the statutory chart ─────────────────────────────────────

    -- 11
    perform set_config('request.jwt.claims', json_build_object('sub', a4)::text, true);
    v := erp.onboard_tenant('Ease four', 'zzease4');
    t4 := (v ->> 'tenant_id')::uuid;
    s4 := (public.erp_start_interview('ease-4') ->> 'session_id')::uuid;
    perform public.erp_answer_interview(s4, 'org.chart', '"statutory"'::jsonb);
    perform public.erp_answer_interview(s4, 'posting.item_classes', '["Finished goods"]'::jsonb);

    v := public.erp_interview_questions(s4);
    select x.el into q from jsonb_array_elements(v) as x(el) where x.el ->> 'code' = 'posting.receipt_account';
    v_ok1 := q is not null
      and exists (select 1 from jsonb_array_elements(case when jsonb_typeof(q -> 'suggestions') = 'array'
                                                          then q -> 'suggestions' else '[]'::jsonb end) as sg(el)
                   where sg.el ->> 'value' = '2300')
      and (coalesce(q -> 'likely', 'null'::jsonb) = 'null'::jsonb or q ->> 'likely' = '2300');
    v_msg := coalesce(q ->> 'likely', 'null');

    perform public.erp_answer_interview(s4, 'posting.receipt_account', '"2300"'::jsonb);
    res := public.erp_propose_from_interview(s4);
    v_b7 := null;
    select (x.el ->> 'change_set_id')::uuid into v_b7 from jsonb_array_elements(res -> 'proposals') as x(el) where x.el ->> 'section' = 'B.7';
    v_ok2 := exists (select 1 from erp.change_set_item i
                      where i.tenant_id = t4 and i.change_set_id = v_b7
                        and i.object_kind = 'capability' and i.payload ->> 'code' = 'statutory_chart_8_1');

    res2 := public.erp_accept_interview(s4);
    v_ok3 := erp.capability_on(t4, 'statutory_chart_8_1', current_date)
      and exists (select 1 from erp.account a where a.tenant_id = t4 and a.code = '2300' and a.status = 'active')
      and not exists (select 1 from erp.account a where a.tenant_id = t4 and a.code = '1200');
    v_ok4 := exists (select 1 from erp.module_installation m where m.tenant_id = t4 and m.module_code = 'finance')
      and exists (select 1 from erp.account_determination ad
                    join erp.account a on a.tenant_id = ad.tenant_id and a.id = ad.account_id
                   where ad.tenant_id = t4 and ad.transaction_type = 'goods_receipt'
                     and a.code = '2300' and ad.status = 'active');
    case_name := 'choosing the statutory chart proposes it, and accepting sets finance up on that chart';
    passed := coalesce(v_ok1 and v_ok2 and v_ok3 and v_ok4, false);
    detail := format('stock account offered from the chosen chart %s (likely %s); the chart proposed %s; '
                     'chart on with its accounts and no standard ones %s; finance installed and goods received reach 2300 %s; steps: %s',
                     v_ok1, v_msg, v_ok2, v_ok3, v_ok4,
                     coalesce((select string_agg(format('%s %s%s', x.el ->> 'step', x.el ->> 'outcome',
                                                        coalesce(' [' || (x.el -> 'refusal' ->> 'message') || ']', '')),
                                                 '; ' order by x.ord)
                                 from jsonb_array_elements(res2 -> 'steps') with ordinality as x(el, ord)), 'none'));
    return next;

    -- ── zzease3: a refusal is reported ───────────────────────────────────

    -- 12
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v := erp.onboard_tenant('Ease three', 'zzease3');
    t3 := (v ->> 'tenant_id')::uuid;
    perform erp.configure_finance();
    s3 := (public.erp_start_interview('ease-3') ->> 'session_id')::uuid;
    perform public.erp_answer_interview(s3, 'dept.list', '["Operations"]'::jsonb);
    perform public.erp_answer_interview(s3, 'posting.receipt_account', '"9999"'::jsonb);
    res := public.erp_propose_from_interview(s3);
    v_b3 := null;
    select (x.el ->> 'change_set_id')::uuid into v_b3 from jsonb_array_elements(res -> 'proposals') as x(el) where x.el ->> 'section' = 'B.3';

    v_msg := null;
    begin
      res2 := public.erp_accept_interview(s3);
    exception when others then
      res2 := null; v_msg := left(sqlerrm, 90);
    end;
    v_ok1 := v_msg is null;
    v_ok2 := exists (select 1 from jsonb_array_elements(res2 -> 'steps') as x(el)
                      where x.el ->> 'step' = 'B.1' and x.el ->> 'outcome' = 'promoted')
      and exists (select 1 from jsonb_array_elements(res2 -> 'steps') as x(el)
                   where x.el ->> 'step' = 'finance' and x.el ->> 'outcome' = 'already_set_up');
    v_ok3 := exists (select 1 from jsonb_array_elements(res2 -> 'steps') as x(el)
                      where x.el ->> 'step' = 'B.3' and x.el ->> 'outcome' = 'refused'
                        and x.el -> 'refusal' ->> 'code' = 'CLOVEERP_PROMOTION_UNKNOWN_ACCOUNT')
      and coalesce((res2 ->> 'refused')::integer, 0) >= 1;
    v_ok4 := not exists (select 1 from erp.account_determination ad where ad.tenant_id = t3)
      and exists (select 1 from erp.change_set c where c.tenant_id = t3 and c.id = v_b3 and c.status <> 'promoted');
    case_name := 'a section that cannot be put in force is reported with its reason, and the rest still are';
    passed := coalesce(v_ok1 and v_ok2 and v_ok3 and v_ok4, false);
    detail := format('returned rather than raised %s%s; departments in force and finance already there %s; '
                     'accounting codes refused for an unknown account %s; nothing of it in force %s; steps: %s',
                     v_ok1, coalesce(' (' || v_msg || ')', ''), v_ok2, v_ok3, v_ok4,
                     coalesce((select string_agg(format('%s %s%s', x.el ->> 'step', x.el ->> 'outcome',
                                                        coalesce(' [' || (x.el -> 'refusal' ->> 'code') || ']', '')),
                                                 '; ' order by x.ord)
                                 from jsonb_array_elements(res2 -> 'steps') with ordinality as x(el, ord)), 'none'));
    return next;

    -- ── zzease5: after go-live ───────────────────────────────────────────

    -- 13
    perform set_config('request.jwt.claims', json_build_object('sub', a5)::text, true);
    s5 := (public.erp_start_interview('ease-5') ->> 'session_id')::uuid;
    perform public.erp_answer_interview(s5, 'dept.list', '["Operations","Finance"]'::jsonb);
    perform public.erp_answer_interview(s5, 'approval.needed', 'true'::jsonb);
    perform public.erp_answer_interview(s5, 'approval.object_type', '"purchase_order"'::jsonb);
    perform public.erp_answer_interview(s5, 'approval.currency', '"GBP"'::jsonb);
    perform public.erp_answer_interview(s5, 'approval.threshold', '5000'::jsonb);
    perform public.erp_answer_interview(s5, 'approval.role', '"administrator"'::jsonb);
    res := public.erp_propose_from_interview(s5);
    v_b1 := null; v_b2 := null;
    select (x.el ->> 'change_set_id')::uuid into v_b1 from jsonb_array_elements(res -> 'proposals') as x(el) where x.el ->> 'section' = 'B.1';
    select (x.el ->> 'change_set_id')::uuid into v_b2 from jsonb_array_elements(res -> 'proposals') as x(el) where x.el ->> 'section' = 'B.2';

    res2 := public.erp_accept_interview(s5);
    v_ok1 := res2 -> 'live' = 'true'::jsonb and res2 ->> 'stops_at' = 'ready'
      and exists (select 1 from jsonb_array_elements(res2 -> 'steps') as x(el)
                   where x.el ->> 'step' = 'B.1' and x.el ->> 'outcome' = 'ready')
      and exists (select 1 from jsonb_array_elements(res2 -> 'steps') as x(el)
                   where x.el ->> 'step' = 'B.2' and x.el ->> 'outcome' = 'ready')
      and not exists (select 1 from erp.department d
                       where d.tenant_id = t5 and d.code in ('OPERATIONS', 'FINANCE'));

    begin
      perform erp.approve_change_set(v_b1);
      v_ok2 := false; v_msg := 'the author approved their own change after go-live';
    exception when others then
      v_ok2 := sqlerrm like 'CLOVEERP_CHANGE_SET_SELF_APPROVAL%'; v_msg := left(sqlerrm, 60);
    end;

    perform set_config('request.jwt.claims', json_build_object('sub', a6)::text, true);
    v_msg2 := null;
    begin
      perform erp.approve_change_set(v_b1);
      perform erp.promote_change_set(v_b1);
      perform erp.approve_change_set(v_b2);
      perform erp.promote_change_set(v_b2);
    exception when others then
      v_msg2 := left(sqlerrm, 90);
    end;
    v_ok3 := v_msg2 is null
      and (select count(*) from erp.department d
            where d.tenant_id = t5 and d.code in ('OPERATIONS', 'FINANCE') and d.status = 'active') = 2
      and (select count(*) from erp.approval_band ab
             join erp.department d on d.tenant_id = ab.tenant_id and d.id = ab.department_id
            where ab.tenant_id = t5 and d.code in ('OPERATIONS', 'FINANCE') and ab.status = 'active') = 2;
    perform set_config('request.jwt.claims', json_build_object('sub', a5)::text, true);

    case_name := 'after go-live accepting stops at ready, and a second administrator puts it in force';
    passed := coalesce(v_ok1 and v_ok2 and v_ok3, false);
    detail := format('stopped at ready with nothing in force %s (steps: %s); the author refused %s (%s); '
                     'the second administrator''s approval landed departments and bands %s%s',
                     v_ok1,
                     coalesce((select string_agg(format('%s %s', x.el ->> 'step', x.el ->> 'outcome'), '; ' order by x.ord)
                                 from jsonb_array_elements(res2 -> 'steps') with ordinality as x(el, ord)), 'none'),
                     v_ok2, v_msg, v_ok3, coalesce(' (' || v_msg2 || ')', ''));
    return next;

    -- ── zzease1 again: the statutory chart and two companies ────────────

    -- 14
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    s1c := (public.erp_start_interview('ease-1c') ->> 'session_id')::uuid;
    perform public.erp_answer_interview(s1c, 'org.multi_company', 'true'::jsonb);
    perform public.erp_answer_interview(s1c, 'org.companies', '[{"left":"ZZ-IE","right":"Zz Ireland"}]'::jsonb);
    v := public.erp_interview_questions(s1c);
    q := null;
    select x.el into q from jsonb_array_elements(v) as x(el) where x.el ->> 'code' = 'org.chart';
    v_ok1 := q is not null
      and exists (select 1 from jsonb_array_elements(case when jsonb_typeof(q -> 'suggestions') = 'array'
                                                          then q -> 'suggestions' else '[]'::jsonb end) as sg(el)
                   where sg.el ->> 'value' = 'statutory'
                     and sg.el -> 'available' = 'false'::jsonb
                     and coalesce(btrim(sg.el ->> 'unavailable_reason'), '') <> '');
    v_msg := null;
    begin
      perform public.erp_answer_interview(s1c, 'org.chart', '"statutory"'::jsonb);
      perform public.erp_propose_from_interview(s1c);
      v_ok2 := false; v_msg := 'the statutory numbering was proposed for two companies';
    exception when others then
      v_ok2 := sqlerrm like 'CLOVEERP_INTERVIEW_CHART_ONE_COMPANY%'; v_msg := left(sqlerrm, 90);
    end;
    v_ok3 := (select s.status from erp.interview_session s where s.tenant_id = t1 and s.id = s1c) = 'open'
      and not exists (select 1 from erp_ai.proposal p where p.tenant_id = t1 and p.interview_session_id = s1c);
    case_name := 'the statutory numbering is not offered, and is refused, for more than one company';
    passed := coalesce(v_ok1 and v_ok2 and v_ok3, false);
    detail := format('offered as unavailable with a reason %s; proposing it refused by name %s (%s); '
                     'the interview stays open with nothing proposed %s',
                     v_ok1, v_ok2, v_msg, v_ok3);
    return next;

    -- ── zzease6: what already exists is kept ─────────────────────────────

    -- 15
    perform set_config('request.jwt.claims', json_build_object('sub', a7)::text, true);
    v := erp.onboard_tenant('Ease six', 'zzease6');
    t6 := (v ->> 'tenant_id')::uuid;
    v_u7 := (v ->> 'principal_id')::uuid;
    -- What a starter pack, or a person on the organisation screen, leaves
    -- behind: a department with a parent, a manager and a cost centre, and a
    -- compulsory grouping. Written directly, as the organisation is not live.
    perform erp.upsert_department('EXEC', 'Executive', null, null, 'CC100', null, null);
    perform erp.upsert_department('FIN', 'Finance', v_u7,
      (select d.id from erp.department d where d.tenant_id = t6 and d.code = 'EXEC'), 'CC200', null, null);
    perform erp.upsert_classification_axis('PRODUCT_TYPE', 'Product type', true, 'FG', 10, null);

    s6 := (public.erp_start_interview('ease-6') ->> 'session_id')::uuid;
    perform public.erp_answer_interview(s6, 'dept.list',
      '[{"code":"FIN","name":"Finance"},{"code":"SALES","name":"Sales"}]'::jsonb);
    perform public.erp_answer_interview(s6, 'classification.axes', '[{"code":"PRODUCT_TYPE","name":"Product type"}]'::jsonb);
    perform public.erp_answer_interview(s6, 'classification.mandatory', 'false'::jsonb);
    v_msg := null; res2 := null;
    begin
      res := public.erp_propose_from_interview(s6);
      res2 := public.erp_accept_interview(s6);
    exception when others then
      v_msg := left(sqlerrm, 120);
    end;
    v_ok1 := v_msg is null
      and exists (select 1 from jsonb_array_elements(res2 -> 'steps') as x(el)
                   where x.el ->> 'step' = 'B.1' and x.el ->> 'outcome' = 'promoted')
      and exists (select 1 from jsonb_array_elements(res2 -> 'steps') as x(el)
                   where x.el ->> 'step' = 'B.4' and x.el ->> 'outcome' = 'promoted');
    v_ok2 := exists (select 1 from erp.department d
                      where d.tenant_id = t6 and d.code = 'FIN' and d.name = 'Finance'
                        and d.default_cost_centre = 'CC200'
                        and d.manager_user_id = v_u7
                        and d.parent_department_id = (select p.id from erp.department p
                                                        where p.tenant_id = t6 and p.code = 'EXEC'));
    v_ok3 := exists (select 1 from erp.department d
                      where d.tenant_id = t6 and d.code = 'SALES' and d.default_cost_centre = 'CC600');
    v_ok4 := exists (select 1 from erp.classification_axis ca
                      where ca.tenant_id = t6 and ca.code = 'PRODUCT_TYPE'
                        and ca.is_mandatory and ca.seq = 10 and ca.item_classes = array['FG']::text[]);
    case_name := 'picking a department or a grouping that already exists keeps what it already had';
    passed := coalesce(v_ok1 and v_ok2 and v_ok3 and v_ok4, false);
    detail := format('accepted%s: %s; FIN keeps its cost centre, parent and manager %s (%s); '
                     'a new starter department takes its suggested cost centre %s; '
                     'product type stays compulsory, in its place, for its kinds %s (%s)',
                     coalesce(' with a raise (' || v_msg || ')', ''),
                     coalesce((select string_agg(format('%s %s', x.el ->> 'step', x.el ->> 'outcome'), '; ' order by x.ord)
                                 from jsonb_array_elements(res2 -> 'steps') with ordinality as x(el, ord)), 'none'),
                     v_ok2,
                     coalesce((select format('%s, parent %s, manager %s', d.default_cost_centre,
                                             (select p.code from erp.department p where p.id = d.parent_department_id),
                                             d.manager_user_id is not null)
                                 from erp.department d where d.tenant_id = t6 and d.code = 'FIN'), 'missing'),
                     v_ok3, v_ok4,
                     coalesce((select format('compulsory %s, seq %s, kinds %s', ca.is_mandatory, ca.seq, ca.item_classes)
                                 from erp.classification_axis ca where ca.tenant_id = t6 and ca.code = 'PRODUCT_TYPE'), 'missing'));
    return next;

    -- ── zzease3 again: promotion guards the books ────────────────────────

    -- 16
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_msg := null; v_msg2 := null;
    begin
      v_cs2 := erp.create_change_set('ease-3-currency', 'A company''s currency', null);
      perform erp.add_change_set_item(v_cs2, 'entity', 'MAIN',
        jsonb_build_object('code', 'MAIN', 'name', 'Ease three', 'currency', 'EUR', 'country', 'GB',
                           'locale', 'en', 'document_locale', 'en', 'fiscal_year_start_month', 1));
      perform erp.submit_change_set(v_cs2);
      perform erp.approve_change_set(v_cs2);
      perform erp.promote_change_set(v_cs2);
      v_ok1 := false; v_msg := 'a company whose books are set up changed its currency';
    exception when others then
      v_ok1 := sqlerrm like 'CLOVEERP_COMPANY_BOOKS_ALREADY_KEPT%'; v_msg := left(sqlerrm, 90);
    end;
    begin
      v_cs2 := erp.create_change_set('ease-3-numbering', 'The statutory numbering', null);
      perform erp.add_change_set_item(v_cs2, 'capability', 'statutory_chart_8_1',
        jsonb_build_object('code', 'statutory_chart_8_1', 'enabled', true, 'reason', 'interview ease suite'));
      perform erp.submit_change_set(v_cs2);
      perform erp.approve_change_set(v_cs2);
      perform erp.promote_change_set(v_cs2);
      v_ok2 := false; v_msg2 := 'the statutory numbering went on over accounts that already exist';
    exception when others then
      v_ok2 := sqlerrm like 'CLOVEERP_CHART_ALREADY_IN_USE%'; v_msg2 := left(sqlerrm, 90);
    end;
    v_ok3 := (select e.base_currency::text from erp.entity e where e.tenant_id = t3 and e.code = 'MAIN') = 'GBP'
      and not erp.capability_on(t3, 'statutory_chart_8_1', current_date);
    case_name := 'promotion refuses a new currency for a company with books, and the statutory numbering over existing accounts';
    passed := coalesce(v_ok1 and v_ok2 and v_ok3, false);
    detail := format('currency refused %s (%s); numbering refused %s (%s); company and numbering unchanged %s',
                     v_ok1, v_msg, v_ok2, v_msg2, v_ok3);
    return next;

    -- 17
    s3b := (public.erp_start_interview('ease-3b') ->> 'session_id')::uuid;
    perform public.erp_answer_interview(s3b, 'org.multi_company', 'true'::jsonb);
    perform public.erp_answer_interview(s3b, 'org.companies', '[{"left":"ZZ-NEW","right":"Zz New"}]'::jsonb);
    perform public.erp_answer_interview(s3b, 'posting.item_classes', '[{"code":"SPARE","name":"Spare parts"}]'::jsonb);
    v_msg := null; res2 := null;
    begin
      res := public.erp_propose_from_interview(s3b);
      res2 := public.erp_accept_interview(s3b);
    exception when others then
      v_msg := left(sqlerrm, 120);
    end;
    v_ok1 := v_msg is null
      and exists (select 1 from jsonb_array_elements(res2 -> 'steps') as x(el)
                   where x.el ->> 'step' = 'B.7' and x.el ->> 'outcome' = 'promoted')
      and exists (select 1 from jsonb_array_elements(res2 -> 'steps') as x(el)
                   where x.el ->> 'step' = 'finance' and x.el ->> 'outcome' = 'set_up');
    v_ok2 := exists (select 1 from erp.ledger l
                       join erp.entity e on e.tenant_id = l.tenant_id and e.id = l.entity_id
                      where l.tenant_id = t3 and e.code = 'ZZ-NEW' and l.code = 'GL')
      and exists (select 1 from erp.account a
                    join erp.entity e on e.tenant_id = a.tenant_id and e.id = a.entity_id
                   where a.tenant_id = t3 and e.code = 'ZZ-NEW');
    v_ok3 := exists (select 1 from jsonb_array_elements(res2 -> 'steps') as x(el)
                      where x.el ->> 'step' = 'B.3' and x.el ->> 'outcome' = 'promoted');
    case_name := 'a company added once finance is installed gets its books when accounting codes are accepted';
    passed := coalesce(v_ok1 and v_ok2 and v_ok3, false);
    detail := format('company in force and its books set up %s; ledger and accounts on ZZ-NEW %s; accounting codes in force %s; steps: %s%s',
                     v_ok1, v_ok2, v_ok3,
                     coalesce((select string_agg(format('%s %s%s', x.el ->> 'step', x.el ->> 'outcome',
                                                        coalesce(' [' || (x.el -> 'refusal' ->> 'message') || ']', '')),
                                                 '; ' order by x.ord)
                                 from jsonb_array_elements(res2 -> 'steps') with ordinality as x(el, ord)), 'none'),
                     coalesce(' (' || v_msg || ')', ''));
    return next;

    -- ── zzease7: the statutory chart with no accounting codes ────────────

    -- 18
    perform set_config('request.jwt.claims', json_build_object('sub', a8)::text, true);
    v := erp.onboard_tenant('Ease seven', 'zzease7');
    t7 := (v ->> 'tenant_id')::uuid;
    s7 := (public.erp_start_interview('ease-7') ->> 'session_id')::uuid;
    perform public.erp_answer_interview(s7, 'org.chart', '"statutory"'::jsonb);
    v_msg := null; res := null; res2 := null;
    begin
      res := public.erp_propose_from_interview(s7);
      res2 := public.erp_accept_interview(s7);
    exception when others then
      v_msg := left(sqlerrm, 120);
    end;
    v_ok1 := v_msg is null
      and not exists (select 1 from jsonb_array_elements(res -> 'proposals') as x(el) where x.el ->> 'section' = 'B.3')
      and exists (select 1 from jsonb_array_elements(res2 -> 'steps') as x(el)
                   where x.el ->> 'step' = 'finance' and x.el ->> 'outcome' = 'chart_applied');
    v_ok2 := erp.capability_on(t7, 'statutory_chart_8_1', current_date)
      and exists (select 1 from erp.account a where a.tenant_id = t7 and a.code = '2300' and a.status = 'active')
      and not exists (select 1 from erp.account a where a.tenant_id = t7 and a.code = '1200');
    v_ok3 := not exists (select 1 from erp.ledger l where l.tenant_id = t7);
    case_name := 'choosing the statutory numbering with no accounting codes still brings in its nominal accounts';
    passed := coalesce(v_ok1 and v_ok2 and v_ok3, false);
    detail := format('only the chart was owed, and it landed %s; the numbering on with its accounts and no standard ones %s; '
                     'the books wait for accounting codes %s; steps: %s%s',
                     v_ok1, v_ok2, v_ok3,
                     coalesce((select string_agg(format('%s %s%s', x.el ->> 'step', x.el ->> 'outcome',
                                                        coalesce(' [' || (x.el -> 'refusal' ->> 'message') || ']', '')),
                                                 '; ' order by x.ord)
                                 from jsonb_array_elements(res2 -> 'steps') with ordinality as x(el, ord)), 'none'),
                     coalesce(' (' || v_msg || ')', ''));
    return next;

  exception when others then
    get stacked diagnostics v_err = message_text, v_err_detail = pg_exception_detail,
                            v_err_ctx = pg_exception_context;
  end;

  -- A statement that raised outside its case undoes everything built above;
  -- the cases already returned stand, and this one says where it stopped.
  if v_err is not null then
    case_name := 'the suite ran to its end';
    passed := false;
    detail := format('%s%s | %s', v_err, coalesce(' — ' || nullif(v_err_detail, ''), ''), left(coalesce(v_err_ctx, ''), 600));
    return next;
  end if;

  -- ── Clean up ──────────────────────────────────────────────────────────

  perform set_config('request.jwt.claims', '', true);
  select coalesce(array_agg(t.id), '{}'::uuid[]) into v_tenants
    from erp.tenant t
   where t.code in ('zzease1', 'zzease2', 'zzease3', 'zzease4', 'zzease5', 'zzease6', 'zzease7');
  foreach v_t in array v_tenants loop
    perform erp.begin_tenant_purge(v_t);
    delete from erp.tenant where id = v_t;
    perform erp.end_tenant_purge();
  end loop;
  delete from auth.users where id in (a1, a2, a3, a4, a5, a6, a7, a8);

  -- 19
  case_name := 'the suite removes the organisations and sign-ins it built';
  passed := not exists (select 1 from erp.tenant t
                         where t.code in ('zzease1', 'zzease2', 'zzease3', 'zzease4', 'zzease5', 'zzease6', 'zzease7'))
        and not exists (select 1 from auth.users u where u.id in (a1, a2, a3, a4, a5, a6, a7, a8));
  detail := format('%s organisation(s) purged', coalesce(array_length(v_tenants, 1), 0));
  return next;
end;
$$;

revoke all on function erp_test.interview_ease_suite() from public, anon, authenticated;

create or replace function erp_test.assert_interview_ease_suite()
returns text
language plpgsql
set search_path = ''
as $$
declare
  -- Four on answering, four on proposing and reading, five on accepting, one
  -- on the statutory numbering and two companies, one on keeping what exists,
  -- two on the books under a company added later and promotion's own guards,
  -- one on the statutory numbering alone, and the clean-up.
  c_expected constant integer := 19;
  v_total  integer;
  v_passed integer;
  v_detail text;
begin
  create temp table if not exists _interview_ease_result
    (case_name text, passed boolean, detail text) on commit drop;
  delete from _interview_ease_result;
  insert into _interview_ease_result select * from erp_test.interview_ease_suite();

  select count(*), count(*) filter (where coalesce(r.passed, false)),
         string_agg(format('  %s — %s', r.case_name, r.detail), E'\n') filter (where not coalesce(r.passed, false))
    into v_total, v_passed, v_detail
    from _interview_ease_result r;
  drop table _interview_ease_result;

  if v_passed < v_total then
    raise exception E'CLOVEERP_INTERVIEW_EASE_SUITE_FAILED: %/% case(s) failed\n%', v_total - v_passed, v_total, v_detail
      using errcode = 'P0001';
  end if;
  if v_total <> c_expected then
    raise exception 'CLOVEERP_INTERVIEW_EASE_SUITE_INCOMPLETE: % case(s), expected %', v_total, c_expected
      using errcode = 'P0001',
            detail = 'A case was added or lost. Update the count deliberately.';
  end if;
  return format('interview ease: %s/%s cases passed', v_passed, v_total);
end;
$$;

revoke all on function erp_test.assert_interview_ease_suite() from public, anon, authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 4b. The words the interview screen says, so each can be renamed
-- ═════════════════════════════════════════════════════════════════════════════
-- Every literal the rebuilt onboarding and configuration screens pass to ui(),
-- plus the onboarding tile's blurb. supabase/ci/screen_strings.sh harvests the
-- screens and refuses any string with no row keyed erp_ref.ui_key(text).

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'Words on the onboarding interview and configuration screens, added when the interview began offering answers and putting them in force.'
  from (values
    ('Waiting for approval'),
    ('Approved, not yet in force'),
    ('Being put in force'),
    ('In force'),
    ('Not applied'),
    ('Proposed'),
    ('earliest expiry first'),
    ('oldest stock first'),
    ('newest stock first'),
    ('no handling-unit labels; stock is known by product, batch and serial'),
    ('each unit'),
    ('the case'),
    ('the carton'),
    ('the pallet'),
    ('the master pallet'),
    ('{role}, and the manager of whoever raised it'),
    ('the manager of whoever raised it'),
    ('nobody named yet'),
    ('Remove: {change}'),
    ('Add the department {name} ({code})'),
    ('Add the department {code}'),
    ('A requisition from {department} above {amount} needs sign-off by {approver}'),
    ('A purchase order from {department} above {amount} needs sign-off by {approver}'),
    ('A purchase invoice for {department} above {amount} needs sign-off by {approver}'),
    ('A sales order from {department} above {amount} needs sign-off by {approver}'),
    ('A {document} from {department} above {amount} needs sign-off by {approver}'),
    ('Add the accounting code {name} ({code}) for business partners'),
    ('Add the accounting code {name} ({code}) for products'),
    ('Goods that arrive are added to nominal account {account}'),
    ('{event} uses nominal account {account}'),
    ('Group products by {name} ({code}); every product needs a value'),
    ('Group products by {name} ({code}); a value is optional'),
    ('Add {name} ({code}) as a value of {axis}'),
    ('Add the product code pattern {name}'),
    ('New product codes follow the pattern {pattern}, for example {example}'),
    ('Add the marshalling area {name} ({code}), topped up when short; stock left more than {hours} hours goes back to storage'),
    ('Add the marshalling area {name} ({code}), topped up when short'),
    ('Add the marshalling area {name} ({code}), bringing in just what is short; stock left more than {hours} hours goes back to storage'),
    ('Add the marshalling area {name} ({code}), bringing in just what is short'),
    ('The company {name} ({code})'),
    ('The company {code}'),
    ('in {country}'),
    ('keeps its books in {currency}'),
    ('writes in {language}'),
    ('starts its year in {month}'),
    ('{company} follows {rules}'),
    ('a standard cost you set'),
    ('first in, first out'),
    ('average cost'),
    ('Stock is costed at {method}; differences from what you pay go to nominal account {account}'),
    ('Stock is costed at {method}'),
    ('{kind} products are labelled at {level}'),
    ('Stock is labelled at {level}'),
    ('At {site}, stock is picked {method}'),
    ('Stock is picked {method}'),
    ('Change the setting {setting}'),
    ('Number nominal accounts by statutory ranges'),
    ('Stop numbering nominal accounts by statutory ranges'),
    ('Switch on the feature {feature}'),
    ('Switch off the feature {feature}'),
    ('Another change: {kind} {key}'),
    ('Yes'),
    ('No'),
    ('Your organisation'),
    ('Your companies, where they trade, how their books are numbered, and how stock is costed and picked.'),
    ('Departments'),
    ('The teams that spend money or approve spending.'),
    ('Approvals'),
    ('Which documents need someone''s sign-off before they count, and above what value.'),
    ('Accounting codes'),
    ('How products and business partners are grouped so their transactions reach the right nominal accounts.'),
    ('Product classification'),
    ('The ways you group products for search and reporting, such as brand or storage condition.'),
    ('Product codes'),
    ('Whether new product codes follow a pattern, and what it looks like.'),
    ('Marshalling areas'),
    ('Where stock is gathered before picking and despatch.'),
    ('Setting up the books'),
    ('Loading your interviews…'),
    ('Start the interview'),
    ('Seven short sections, starting with your organisation. Your answers save as you give them, so you can stop at any time and pick up where you left off.'),
    ('Starting…'),
    ('Your first-day questionnaire. Describe how the business works — your companies, departments, who signs off spending, how products are grouped and coded — and your answers become the set-up to match. Most questions come with a likely answer you can take with one press. Nothing changes until you accept what your answers propose.'),
    ('Earlier interviews'),
    ('Open one to see what its answers proposed and whether those changes are in force.'),
    ('See what it proposed'),
    ('Loading the questions…'),
    ('No questions came back for this interview. That is not expected: refresh the page, and if it stays empty, ask your administrator to check the product content was installed.'),
    ('Interview sections'),
    ('Section'),
    ('Use the suggested answers for this section'),
    ('Questions answered in this section'),
    ('Nothing in this section applies, given your earlier answers.'),
    ('Back'),
    ('Next'),
    ('Review and propose'),
    ('Propose the changes'),
    ('Proposing turns your answers into changes, one group per section. You see every change in plain words before anything is put in force, and a question left unanswered changes nothing.'),
    ('Answer these first — they are needed before you can propose:'),
    ('Some answers need correcting before you can propose.'),
    ('Some answers did not save. Try saving them again before you propose:'),
    ('Proposing…'),
    ('Your last answers are still saving.'),
    ('That is not a number. Type digits, for example 5,000.'),
    ('Use a whole number.'),
    ('Use at most {places} decimal places.'),
    ('Use a number from {min} to {max}.'),
    ('Use a number of at least {min}.'),
    ('That number is too large for this question.'),
    ('Choose one of the options.'),
    ('Each row needs both columns filled in. Finish or remove the unfinished rows.'),
    ('(required)'),
    ('Saving…'),
    ('Saved'),
    ('Not saved'),
    ('Likely answer:'),
    ('Use this'),
    ('Try saving again'),
    ('Clear this answer'),
    ('Likely'),
    ('pick from the list'),
    ('Choose…'),
    ('or type your own'),
    ('Or type your own'),
    ('Nothing added yet.'),
    ('Your answer so far'),
    ('Remove'),
    ('Starting points — press one to add it, press it again to take it out'),
    ('already in your organisation'),
    ('add your own'),
    ('Type a name, then press Add'),
    ('Add'),
    ('Company code'),
    ('Company name'),
    ('Company'),
    ('Currency'),
    ('Country'),
    ('Language'),
    ('Tax and legal rules'),
    ('Kind of product'),
    ('Labelled at'),
    ('Site'),
    ('Picking order'),
    ('Grouping'),
    ('Value'),
    ('Name'),
    ('No rows yet.'),
    ('for example UK'),
    ('Something else…'),
    ('for example Northern Trading Ltd'),
    ('Remove row'),
    ('Add a row'),
    ('Already in your organisation:'),
    ('What your answers propose'),
    ('Back to interviews'),
    ('This organisation is live, so a second administrator approves these changes before they are in force. Nothing below changes anything until then.'),
    ('This organisation is not live yet, so accepting puts these changes in force straight away, in order: your organisation first, then the books, departments, approvals and the rest.'),
    ('Getting what your answers propose…'),
    ('Nothing was proposed from this interview.'),
    ('Waiting'),
    ('Needs attention'),
    ('Sending these for approval puts them in front of another administrator on Configuration. Nothing changes until they approve.'),
    ('This puts every change above in force, in order. A change that cannot go in yet is reported on its card with what to do, and the rest still go in.'),
    ('Working…'),
    ('Send for approval'),
    ('Put these changes in force'),
    ('Everything this interview proposed is in force.'),
    ('Nothing here is waiting for you. A change waiting for approval is approved on Configuration.'),
    ('Accounting codes need books to post to, so the books are set up for each company that has none, with nominal accounts numbered the way you chose.'),
    ('Loading the changes…'),
    ('Show fewer changes'),
    ('Show every change'),
    ('See this change on Configuration'),
    ('The books are set up'),
    ('Waiting for a second administrator to approve'),
    ('Waiting for approval from the people your approval rules name'),
    ('Waiting for {section} to go in first'),
    ('This change can no longer be put in force. Start a new interview to propose it again.'),
    ('Nothing to do here'),
    ('Before and after go-live'),
    ('While an organisation is still being set up, whoever makes a change can approve it and put it in force: there is nobody else to ask yet. Once the organisation is live, the person who made a change may not approve it, so a second administrator does.'),
    ('Changes waiting'),
    ('this organisation is live, and the ones you made need another administrator to approve them.'),
    ('approve them and put them in force below.'),
    ('The change you followed a link to is not on this list.'),
    ('You made this change, so another administrator approves it.'),
    ('Yours — another administrator approves it'),
    ('Questions about how this organisation works, a section at a time with likely answers; your answers become changes you accept.'),
    ('Could not refresh. What you see is what last loaded, and your unsaved answers are kept.'),
    ('Try again'),
    ('Why'),
    ('Nothing here is waiting for you. A change waiting for approval is approved on Configuration, and an approved change is put in force there.'),
    ('You chose statutory numbering, so its nominal accounts are added now. The books themselves are set up when you accept accounting codes.'),
    ('The nominal accounts are in place'),
    ('Approved, waiting to be put in force on Configuration')
  ) as v(text)
on conflict (key, locale) do nothing;

select erp.assert_resource_coverage('en');
select erp.assert_vocabulary_aligned();

-- ═════════════════════════════════════════════════════════════════════════════
-- 5. Generators, then the checks that read what changed
-- ═════════════════════════════════════════════════════════════════════════════

select erp_meta.add_help_actions('/administration/onboarding', array['erp_accept_interview']);

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_authorising_doors_are_volatile();
select erp.assert_authorise_codes_exist();
select erp.assert_invoker_doors_executable();
select erp.assert_intelligence_boundary();
select erp.assert_guidance_sound();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_no_legacy_refusal_prefix();
select erp_test.assert_onboarding_interview_suite();
select erp_test.assert_interview_ease_suite();
