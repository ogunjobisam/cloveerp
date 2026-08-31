-- =============================================================================
-- Addendum B, Part 4 — the onboarding interview
--
-- §3.12: "every suggestion is a diff". erp_ai.proposal implements that
-- literally — proposal.change_set_id points at a B6 change set, so a machine's
-- suggestion is reviewed and promoted by exactly the machinery a human's
-- change goes through, with no weaker parallel path. This adds a producer to
-- that path, not a second way to change things.
--
-- Until 20260901130000 it could not have. erp.apply_change_set_item understood
-- twenty-two object kinds and none of the nine Addendum B surfaces was among
-- them, so an interview about departments and approval bands could have asked
-- questions and written prose but could not have produced a diff for anything
-- it exists to configure. ('onboarding_interview' is exempt from
-- proposal_authoring_has_change_set, so a prose-only version would have passed
-- the schema — which is exactly the hollow thing to avoid.)
--
-- THE QUESTION BANK IS CONFIGURATION, NOT CODE.
--
-- erp_ref.interview_question holds the questions: which surface each feeds,
-- what shape of answer it takes, what it maps to, and when it applies. Six
-- hard-coded question lists in TypeScript would have been faster and would
-- have made the interview the one part of this product whose behaviour is not
-- configured — in a product whose entire thesis is that behaviour is
-- configured rather than coded.
--
-- WHAT THIS CANNOT DO, AND WHY IT IS SAID HERE RATHER THAN DISCOVERED.
--
-- erp_ai.apply_proposal() requires a proposal validated in an environment that
-- is not production and is not the environment being promoted into. Every
-- organisation this product can currently create has exactly one environment —
-- erp.onboard_tenant() inserts 'production', is_self — so that route cannot
-- complete for any of them. The interview therefore produces the change set
-- and the proposal that explains it, and the change set is approved and
-- promoted through B6 exactly as a human-authored one is. The proposal is the
-- record of where the change came from and what was inspected to suggest it.
--
-- Adding a test environment so the stricter route can complete is a real piece
-- of work and a decision, not a detail; it is recorded in
-- erp_meta.policy_decision as an open question rather than assumed here.
-- =============================================================================

create table if not exists erp_ref.interview_question (
  code         text primary key,
  section      text not null,        -- which part of Addendum B this belongs to
  surface      text not null,        -- the configuration surface it feeds
  seq          integer not null,
  prompt       text not null,
  prompt_key   text not null,        -- resource key, so the question translates
  help         text,
  answer_shape text not null
    check (answer_shape in ('text', 'text_list', 'text_pairs', 'boolean',
                            'integer', 'money', 'choice')),
  choices      jsonb,
  -- The erp.change_set_item object_kind an answer to this question turns into.
  -- Null where the answer only shapes another question's items.
  maps_to      text,
  -- The code of an earlier question whose answer decides whether this one is
  -- asked at all. An interview that asks about approval thresholds when
  -- nothing needs approval is an interview nobody finishes.
  applies_when text references erp_ref.interview_question(code),
  is_required  boolean not null default false
);

comment on table erp_ref.interview_question is
  'The onboarding interview, held as reference configuration rather than as '
  'six question lists in TypeScript. Each row names the Addendum B surface it '
  'feeds and the change_set_item object_kind an answer becomes, so a new '
  'question is a row rather than a deployment.';

select erp_meta.register_table('erp_ref', 'interview_question', 'product_content',
  'The question bank. Product content: the same for every organisation.');

create table if not exists erp.interview_session (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references erp.tenant(id) on delete cascade,
  code         text not null,
  status       text not null default 'open'
                 check (status in ('open', 'proposed', 'abandoned')),
  started_at   timestamptz not null default now(),
  proposed_at  timestamptz,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  unique (tenant_id, code)
);

comment on table erp.interview_session is
  'One run of the onboarding interview. Answers hang off it, and proposing '
  'turns them into change sets — so a half-finished interview is a row, not a '
  'lost afternoon.';

create table if not exists erp.interview_answer (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references erp.tenant(id) on delete cascade,
  session_id    uuid not null references erp.interview_session(id) on delete cascade,
  question_code text not null references erp_ref.interview_question(code),
  answer        jsonb not null,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  updated_at    timestamptz not null default now(),
  updated_by    uuid,
  unique (tenant_id, session_id, question_code)
);

comment on table erp.interview_answer is
  'What somebody said, kept separately from what was proposed because of it. '
  'A proposal can be rejected and re-derived; the answers are the evidence.';

select erp_meta.register_table('erp', 'interview_session', 'tenant_scoped',
  'One run of the onboarding interview.');
select erp_meta.register_table('erp', 'interview_answer', 'tenant_scoped',
  'Answers given during an onboarding interview.');

-- ── The bank ─────────────────────────────────────────────────────────────────

insert into erp_ref.interview_question
  (code, section, surface, seq, prompt, prompt_key, help, answer_shape, choices,
   maps_to, applies_when, is_required) values

  -- B.1 Departments
  ('dept.list', 'B.1', 'department', 10,
   'Which departments own or approve spending?',
   'interview.dept.list',
   'One per line. These are the units approval bands hang off, so name the '
   'ones that decide, not every team on the chart.',
   'text_list', null, 'department', null, true),

  -- B.2 Approvals
  ('approval.needed', 'B.2', 'approval_band', 20,
   'Does any document need approving before it takes effect?',
   'interview.approval.needed', null, 'boolean', null, null, null, true),

  ('approval.object_type', 'B.2', 'approval_band', 21,
   'Which document?',
   'interview.approval.object_type', null, 'choice',
   '["purchase_order","sales_order","purchase_invoice","journal"]'::jsonb,
   null, 'approval.needed', false),

  ('approval.currency', 'B.2', 'approval_band', 22,
   'In which currency are the thresholds set?',
   'interview.approval.currency', null, 'choice',
   '["GBP","EUR","USD"]'::jsonb, null, 'approval.needed', false),

  ('approval.threshold', 'B.2', 'approval_band', 23,
   'Above what value does it need approval?',
   'interview.approval.threshold',
   'In whole units of the currency above. Below this, no approval is asked '
   'for; above it, the band applies.',
   'money', null, 'approval_band', 'approval.needed', false),

  ('approval.role', 'B.2', 'approval_band', 24,
   'Which role approves it?',
   'interview.approval.role',
   'The role code, as it appears on Administration → Permissions. Leaving this '
   'blank and answering yes below puts the line manager in the chain instead.',
   'text', null, null, 'approval.needed', false),

  ('approval.line_manager', 'B.2', 'approval_band', 25,
   'Should the requester''s line manager be in the chain?',
   'interview.approval.line_manager', null, 'boolean', null, null,
   'approval.needed', false),

  -- B.3 Posting classes and account determination
  ('posting.item_classes', 'B.3', 'posting_class', 30,
   'Which kinds of item post to different accounts?',
   'interview.posting.item_classes',
   'One per line — finished goods, raw materials, consumables. A class exists '
   'because two things post differently, not because they are different things.',
   'text_list', null, 'posting_class', null, false),

  ('posting.party_classes', 'B.3', 'posting_class', 31,
   'And which kinds of trading partner?',
   'interview.posting.party_classes',
   'One per line — domestic, EU, intercompany.',
   'text_list', null, 'posting_class', null, false),

  ('posting.receipt_account', 'B.3', 'account_determination', 32,
   'Which account does a goods receipt debit?',
   'interview.posting.receipt_account',
   'The account code from your chart of accounts. Nothing falls into a '
   'suspense account: a posting with no rule behind it is refused, so this is '
   'asked rather than guessed.',
   'text', null, 'account_determination', null, false),

  -- B.4 Classification
  ('classification.axes', 'B.4', 'classification_axis', 40,
   'What do you need to classify items by, beyond their account?',
   'interview.classification.axes',
   'One per line — colour, size, grade. These are the axes reporting and '
   'search are cut along.',
   'text_list', null, 'classification_axis', null, false),

  ('classification.mandatory', 'B.4', 'classification_axis', 41,
   'Must every item carry a value on all of them?',
   'interview.classification.mandatory', null, 'boolean', null, null,
   'classification.axes', false),

  ('classification.values', 'B.4', 'classification_value', 42,
   'And the values on each axis?',
   'interview.classification.values',
   'Axis on the left, value on the right — COLOUR / Red. Add a row per value.',
   'text_pairs', null, 'classification_value', 'classification.axes', false),

  -- B.5 Code templates
  ('code.wanted', 'B.5', 'code_template', 50,
   'Should item codes be issued to a pattern?',
   'interview.code.wanted',
   'Rather than typed in by whoever creates the item.',
   'boolean', null, null, null, false),

  ('code.prefix', 'B.5', 'code_template', 51,
   'What should an item code start with?',
   'interview.code.prefix', 'A short literal, such as IT.',
   'text', null, 'code_template', 'code.wanted', false),

  ('code.digits', 'B.5', 'code_template', 52,
   'How many digits follow it?',
   'interview.code.digits', null, 'integer', null, null, 'code.wanted', false),

  -- B.6 Release areas
  ('release.areas', 'B.6', 'release_area', 60,
   'Which areas does stock get released to?',
   'interview.release.areas',
   'One per line — picking, packing, despatch.',
   'text_list', null, 'release_area', null, false),

  ('release.mode', 'B.6', 'release_area', 61,
   'Is stock pulled into them on demand, or pushed on a schedule?',
   'interview.release.mode', null, 'choice', '["pull","push"]'::jsonb, null,
   'release.areas', false),

  ('release.ageing_hours', 'B.6', 'release_area', 62,
   'After how many hours should stock sitting in one be flagged?',
   'interview.release.ageing_hours', null, 'integer', null, null,
   'release.areas', false)

on conflict (code) do update set
  section = excluded.section, surface = excluded.surface, seq = excluded.seq,
  prompt = excluded.prompt, prompt_key = excluded.prompt_key,
  help = excluded.help, answer_shape = excluded.answer_shape,
  choices = excluded.choices, maps_to = excluded.maps_to,
  applies_when = excluded.applies_when, is_required = excluded.is_required;

-- A code from something a person typed. Codes are what every branch of the
-- promoter resolves against, so "Finished Goods" and "finished goods" have to
-- become the same one thing before either reaches a change set.
create or replace function erp.slug_code(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(
           btrim(regexp_replace(upper(coalesce(p_text, '')), '[^A-Z0-9]+', '-', 'g'), '-'),
           '')
$$;

-- ── Running an interview ─────────────────────────────────────────────────────

create or replace function erp.start_interview(p_code text default null)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_id     uuid;
begin
  insert into erp.interview_session (tenant_id, code)
  values (v_tenant,
          coalesce(nullif(btrim(p_code), ''),
                   'interview-' || to_char(now(), 'YYYYMMDD-HH24MISS')))
  returning id into v_id;
  return v_id;
end;
$$;

-- The answer's shape is checked here rather than at the screen, because the
-- screen is not the only caller and a malformed answer would otherwise become
-- a malformed change-set item, which is a much later and much worse error.
create or replace function erp.answer_interview(
  p_session_id uuid, p_question_code text, p_answer jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  q        erp_ref.interview_question%rowtype;
  v_type   text := jsonb_typeof(p_answer);
  v_wrong  boolean;
begin
  if not exists (select 1 from erp.interview_session s
                  where s.tenant_id = v_tenant and s.id = p_session_id
                    and s.status = 'open') then
    raise exception 'ERPWARE_INTERVIEW_NOT_OPEN: % is not an open interview',
      p_session_id using errcode = '23503';
  end if;

  select * into q from erp_ref.interview_question where code = p_question_code;
  if not found then
    raise exception 'ERPWARE_UNKNOWN_QUESTION: %', p_question_code
      using errcode = '23503';
  end if;

  -- Assigned rather than written inline: plpgsql ends an IF condition at the
  -- first THEN token, and a CASE expression is full of them.
  v_wrong := case q.answer_shape
               when 'text'       then v_type <> 'string'
               when 'boolean'    then v_type <> 'boolean'
               when 'integer'    then v_type <> 'number'
               when 'money'      then v_type <> 'number'
               when 'choice'     then v_type <> 'string'
               when 'text_list'  then v_type <> 'array'
               when 'text_pairs' then v_type <> 'array'
               else false
             end;

  if v_wrong then
    raise exception
      'ERPWARE_ANSWER_SHAPE: % expects %, and was given %',
      p_question_code, q.answer_shape, v_type using errcode = '22023';
  end if;

  -- A choice question with a free-text answer is how a question bank becomes
  -- decoration.
  if q.answer_shape = 'choice'
     and not (p_answer #>> '{}' = any (
                select jsonb_array_elements_text(q.choices)))
  then
    raise exception 'ERPWARE_ANSWER_NOT_A_CHOICE: % is not one of %',
      p_answer #>> '{}', q.choices::text using errcode = '22023';
  end if;

  insert into erp.interview_answer (tenant_id, session_id, question_code, answer)
  values (v_tenant, p_session_id, p_question_code, p_answer)
  on conflict (tenant_id, session_id, question_code)
    do update set answer = excluded.answer, updated_at = now();

  return jsonb_build_object('question', p_question_code, 'recorded', true);
end;
$$;

-- The questions, with whatever has been answered so far and whether each one
-- applies given the answers before it.
create or replace function erp.interview_questions(p_session_id uuid)
returns table(code text, section text, surface text, seq integer, prompt text,
              prompt_key text, help text, answer_shape text, choices jsonb,
              maps_to text, is_required boolean, applies boolean, answer jsonb)
language sql
stable
set search_path = ''
as $$
  select q.code, q.section, q.surface, q.seq, q.prompt, q.prompt_key, q.help,
         q.answer_shape, q.choices, q.maps_to, q.is_required,
         -- A gated question applies once its gate has an answer that is not
         -- false and not an empty list.
         case
           when q.applies_when is null then true
           else coalesce((
             select case jsonb_typeof(ga.answer)
                      when 'boolean' then (ga.answer)::text = 'true'
                      when 'array'   then jsonb_array_length(ga.answer) > 0
                      else coalesce(ga.answer #>> '{}', '') <> ''
                    end
               from erp.interview_answer ga
              where ga.tenant_id = erp.require_tenant_id()
                and ga.session_id = p_session_id
                and ga.question_code = q.applies_when), false)
         end,
         a.answer
    from erp_ref.interview_question q
    left join erp.interview_answer a
      on a.tenant_id = erp.require_tenant_id()
     and a.session_id = p_session_id
     and a.question_code = q.code
   order by q.seq
$$;

-- ── Turning answers into diffs ───────────────────────────────────────────────
--
-- One change set and one proposal per Addendum B section that was answered,
-- because a section is the unit somebody reviews: "the approval rules" is a
-- decision, and "eleven items" is not.
--
-- This lives in erp_ai because that is where the boundary puts it. Promise 3 —
-- asserted by erp.assert_intelligence_boundary() — is that nothing on the
-- transaction path can reach the intelligence layer, and it is enforced by
-- following the call graph. A producer in erp.* that wrote proposals would be
-- one accidental call away from breaking that.

create or replace function erp_ai.propose_from_interview(p_session_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  s          erp.interview_session%rowtype;
  v_section  record;
  v_cs       uuid;
  v_prop     uuid;
  v_items    integer;
  v_total    integer := 0;
  v_out      jsonb := '[]'::jsonb;
  v_stamp    text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISS');
  a          jsonb;
  e          jsonb;
  v_code     text;
  v_ccy      text;
  v_role     text;
  v_lm       boolean;
  v_obj      text;
begin
  select * into s from erp.interview_session
   where tenant_id = v_tenant and id = p_session_id for update;

  if not found then
    raise exception 'ERPWARE_UNKNOWN_INTERVIEW: %', p_session_id using errcode = '23503';
  end if;
  if s.status <> 'open' then
    raise exception 'ERPWARE_INTERVIEW_NOT_OPEN: % is %', s.code, s.status
      using errcode = '23514';
  end if;

  if not exists (select 1 from erp.interview_answer
                  where tenant_id = v_tenant and session_id = p_session_id) then
    raise exception
      'ERPWARE_INTERVIEW_EMPTY: % has no answers, and a proposal with no diff '
      'behind it is the hollow thing this was built to avoid', s.code
      using errcode = '23514';
  end if;

  for v_section in
    select distinct q.section
      from erp.interview_answer ia
      join erp_ref.interview_question q on q.code = ia.question_code
     where ia.tenant_id = v_tenant and ia.session_id = p_session_id
       and q.maps_to is not null
     order by q.section
  loop
    v_cs := erp.create_change_set(
      format('interview-%s-%s', lower(replace(v_section.section, '.', '')), v_stamp),
      format('Onboarding interview — %s', v_section.section),
      format('Proposed from the answers given in interview %s.', s.code));
    v_items := 0;

    -- ── B.1 Departments ──────────────────────────────────────────────────
    if v_section.section = 'B.1' then
      select ia.answer into a from erp.interview_answer ia
       where ia.tenant_id = v_tenant and ia.session_id = p_session_id
         and ia.question_code = 'dept.list';

      for e in select jsonb_array_elements(coalesce(a, '[]'::jsonb)) loop
        v_code := erp.slug_code(e #>> '{}');
        continue when v_code is null;
        perform erp.add_change_set_item(v_cs, 'department', v_code,
          jsonb_build_object('code', v_code, 'name', btrim(e #>> '{}')));
        v_items := v_items + 1;
      end loop;
    end if;

    -- ── B.2 Approvals ────────────────────────────────────────────────────
    if v_section.section = 'B.2' then
      select (ia.answer #>> '{}') into v_obj from erp.interview_answer ia
       where ia.tenant_id = v_tenant and ia.session_id = p_session_id
         and ia.question_code = 'approval.object_type';
      select (ia.answer #>> '{}') into v_ccy from erp.interview_answer ia
       where ia.tenant_id = v_tenant and ia.session_id = p_session_id
         and ia.question_code = 'approval.currency';
      select (ia.answer #>> '{}') into v_role from erp.interview_answer ia
       where ia.tenant_id = v_tenant and ia.session_id = p_session_id
         and ia.question_code = 'approval.role';
      select coalesce((ia.answer)::text = 'true', false) into v_lm
        from erp.interview_answer ia
       where ia.tenant_id = v_tenant and ia.session_id = p_session_id
         and ia.question_code = 'approval.line_manager';
      select ia.answer into a from erp.interview_answer ia
       where ia.tenant_id = v_tenant and ia.session_id = p_session_id
         and ia.question_code = 'approval.threshold';

      -- A band with no way to find an approver is refused by
      -- erp.upsert_approval_band(), so it is refused here rather than promoted
      -- and rejected at the far end.
      if a is not null and (v_role is not null or v_lm) then
        -- One band per department named in B.1: an approval rule that names no
        -- department applies to nothing.
        for e in
          select d.value from jsonb_array_elements(
            coalesce((select ia.answer from erp.interview_answer ia
                       where ia.tenant_id = v_tenant
                         and ia.session_id = p_session_id
                         and ia.question_code = 'dept.list'), '[]'::jsonb)) d
        loop
          v_code := erp.slug_code(e #>> '{}');
          continue when v_code is null;
          perform erp.add_change_set_item(v_cs, 'approval_band',
            format('%s|%s|1', v_code, coalesce(v_obj, 'purchase_order')),
            jsonb_build_object(
              'department', v_code,
              'object_type', coalesce(v_obj, 'purchase_order'),
              'seq', 1,
              'lower_bound_minor', (a #>> '{}')::numeric * 100,
              'currency', coalesce(v_ccy, 'GBP'),
              'approver_role', v_role,
              'use_line_manager', v_lm));
          v_items := v_items + 1;
        end loop;
      end if;
    end if;

    -- ── B.3 Posting classes and determination ────────────────────────────
    if v_section.section = 'B.3' then
      for e in
        select jsonb_array_elements(coalesce((
          select ia.answer from erp.interview_answer ia
           where ia.tenant_id = v_tenant and ia.session_id = p_session_id
             and ia.question_code = 'posting.item_classes'), '[]'::jsonb))
      loop
        v_code := erp.slug_code(e #>> '{}');
        continue when v_code is null;
        perform erp.add_change_set_item(v_cs, 'posting_class',
          'item|' || v_code,
          jsonb_build_object('kind', 'item', 'code', v_code,
                             'name', btrim(e #>> '{}')));
        v_items := v_items + 1;
      end loop;

      for e in
        select jsonb_array_elements(coalesce((
          select ia.answer from erp.interview_answer ia
           where ia.tenant_id = v_tenant and ia.session_id = p_session_id
             and ia.question_code = 'posting.party_classes'), '[]'::jsonb))
      loop
        v_code := erp.slug_code(e #>> '{}');
        continue when v_code is null;
        perform erp.add_change_set_item(v_cs, 'posting_class',
          'party|' || v_code,
          jsonb_build_object('kind', 'party', 'code', v_code,
                             'name', btrim(e #>> '{}')));
        v_items := v_items + 1;
      end loop;

      select (ia.answer #>> '{}') into v_code from erp.interview_answer ia
       where ia.tenant_id = v_tenant and ia.session_id = p_session_id
         and ia.question_code = 'posting.receipt_account';

      if nullif(btrim(coalesce(v_code, '')), '') is not null then
        perform erp.add_change_set_item(v_cs, 'account_determination',
          'goods_receipt|-|-|-|-|-|-|-',
          jsonb_build_object('transaction_type', 'goods_receipt',
                             'account', btrim(v_code)));
        v_items := v_items + 1;
      end if;
    end if;

    -- ── B.4 Classification ───────────────────────────────────────────────
    if v_section.section = 'B.4' then
      select coalesce((ia.answer)::text = 'true', false) into v_lm
        from erp.interview_answer ia
       where ia.tenant_id = v_tenant and ia.session_id = p_session_id
         and ia.question_code = 'classification.mandatory';

      for e in
        select jsonb_array_elements(coalesce((
          select ia.answer from erp.interview_answer ia
           where ia.tenant_id = v_tenant and ia.session_id = p_session_id
             and ia.question_code = 'classification.axes'), '[]'::jsonb))
      loop
        v_code := erp.slug_code(e #>> '{}');
        continue when v_code is null;
        perform erp.add_change_set_item(v_cs, 'classification_axis', v_code,
          jsonb_build_object('code', v_code, 'name', btrim(e #>> '{}'),
                             'is_mandatory', coalesce(v_lm, false)));
        v_items := v_items + 1;
      end loop;

      for e in
        select jsonb_array_elements(coalesce((
          select ia.answer from erp.interview_answer ia
           where ia.tenant_id = v_tenant and ia.session_id = p_session_id
             and ia.question_code = 'classification.values'), '[]'::jsonb))
      loop
        continue when erp.slug_code(e ->> 'left') is null
                   or erp.slug_code(e ->> 'right') is null;
        perform erp.add_change_set_item(v_cs, 'classification_value',
          erp.slug_code(e ->> 'left') || '|' || erp.slug_code(e ->> 'right'),
          jsonb_build_object(
            'axis', erp.slug_code(e ->> 'left'),
            'code', erp.slug_code(e ->> 'right'),
            'name', btrim(e ->> 'right'),
            'abbreviation', left(erp.slug_code(e ->> 'right'), 4)));
        v_items := v_items + 1;
      end loop;
    end if;

    -- ── B.5 Code templates ───────────────────────────────────────────────
    if v_section.section = 'B.5' then
      select (ia.answer #>> '{}') into v_code from erp.interview_answer ia
       where ia.tenant_id = v_tenant and ia.session_id = p_session_id
         and ia.question_code = 'code.prefix';
      select ia.answer into a from erp.interview_answer ia
       where ia.tenant_id = v_tenant and ia.session_id = p_session_id
         and ia.question_code = 'code.digits';

      if nullif(btrim(coalesce(v_code, '')), '') is not null then
        perform erp.add_change_set_item(v_cs, 'code_template', 'ITEM',
          jsonb_build_object(
            'code', 'ITEM', 'name', 'Item code', 'casing', 'upper',
            'segments', jsonb_build_array(
              jsonb_build_object('kind', 'literal', 'value', upper(btrim(v_code))),
              jsonb_build_object('kind', 'sequence',
                                 'length', greatest(1, coalesce((a #>> '{}')::integer, 6))))));
        v_items := v_items + 1;
      end if;
    end if;

    -- ── B.6 Release areas ────────────────────────────────────────────────
    if v_section.section = 'B.6' then
      -- A release area belongs to a site, and the promoter refuses one it
      -- cannot place. Refusing here, where the message can say what to do
      -- about it, beats refusing at promotion where it reads as a failure of
      -- the change set rather than of the answer.
      if not exists (select 1 from erp.site st
                      where st.tenant_id = v_tenant and st.status = 'active') then
        raise exception
          'ERPWARE_INTERVIEW_NEEDS_SITE: release areas belong to a site and this '
          'organisation has none yet. Create a site first, or leave the release '
          'area questions unanswered.'
          using errcode = '23503';
      end if;

      select (ia.answer #>> '{}') into v_obj from erp.interview_answer ia
       where ia.tenant_id = v_tenant and ia.session_id = p_session_id
         and ia.question_code = 'release.mode';
      select ia.answer into a from erp.interview_answer ia
       where ia.tenant_id = v_tenant and ia.session_id = p_session_id
         and ia.question_code = 'release.ageing_hours';

      for e in
        select jsonb_array_elements(coalesce((
          select ia.answer from erp.interview_answer ia
           where ia.tenant_id = v_tenant and ia.session_id = p_session_id
             and ia.question_code = 'release.areas'), '[]'::jsonb))
      loop
        v_code := erp.slug_code(e #>> '{}');
        continue when v_code is null;
        perform erp.add_change_set_item(v_cs, 'release_area', v_code,
          jsonb_build_object(
            'code', v_code, 'name', btrim(e #>> '{}'),
            'replenishment_mode', coalesce(v_obj, 'pull'),
            'ageing_hours', greatest(1, coalesce((a #>> '{}')::integer, 72))));
        v_items := v_items + 1;
      end loop;
    end if;

    -- A section that produced nothing gets no proposal and no empty change set
    -- left behind to be found later and wondered about.
    if v_items = 0 then
      delete from erp.change_set where tenant_id = v_tenant and id = v_cs;
      continue;
    end if;

    insert into erp_ai.proposal (
      tenant_id, kind, title, rationale, change_set_id, status,
      produced_by, producer_label)
    values (
      v_tenant, 'onboarding_interview',
      format('Addendum B %s, from interview %s', v_section.section, s.code),
      format('Proposed from %s answer(s) given in interview %s. Every item '
             'below is a change-set item promoted through B6 like any other; '
             'nothing here writes configuration directly. Review the diff '
             'rather than this sentence.',
             (select count(*) from erp.interview_answer ia
               join erp_ref.interview_question q on q.code = ia.question_code
              where ia.tenant_id = v_tenant and ia.session_id = p_session_id
                and q.section = v_section.section), s.code),
      v_cs, 'proposed',
      -- Null on purpose. The person answered questions; the mapping from
      -- answers to a diff was made by the product, and recording them as the
      -- producer would block them from reviewing it under the self-approval
      -- rule for something they did not author.
      null, 'onboarding interview')
    returning id into v_prop;

    -- Explainability, §3.12: what was looked at, not just what was concluded.
    insert into erp_ai.proposal_evidence
      (tenant_id, proposal_id, source_kind, source_ref, observation)
    select v_tenant, v_prop, 'interview_answer', ia.question_code,
           format('%s — answered %s', q.prompt, ia.answer::text)
      from erp.interview_answer ia
      join erp_ref.interview_question q on q.code = ia.question_code
     where ia.tenant_id = v_tenant and ia.session_id = p_session_id
       and q.section = v_section.section;

    v_total := v_total + v_items;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'section', v_section.section, 'proposal_id', v_prop,
      'change_set_id', v_cs, 'items', v_items));
  end loop;

  if v_total = 0 then
    raise exception
      'ERPWARE_INTERVIEW_PROPOSES_NOTHING: % was answered but nothing it said '
      'turns into a change. Answering "no" to every gate is a valid interview '
      'and an empty proposal is not a useful one.', s.code
      using errcode = '23514';
  end if;

  update erp.interview_session
     set status = 'proposed', proposed_at = now(), updated_at = now()
   where id = p_session_id;

  return jsonb_build_object('interview', s.code, 'items', v_total,
                            'proposals', v_out);
end;
$$;

-- ── The doors ────────────────────────────────────────────────────────────────
--
-- B10 has had no public surface at all: erp_ai.apply_proposal() exists and
-- nothing in the product could reach it, so the intelligence layer was
-- unreachable end to end rather than merely unused. These are reads and one
-- producer; approving and promoting still happen through the change-set doors
-- that already exist, which is the point.

create or replace function public.erp_interview_questions(p_session_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure');
  return coalesce((
    select jsonb_agg(to_jsonb(q) order by q.seq)
      from erp.interview_questions(p_session_id) q), '[]'::jsonb);
end;
$$;

create or replace function public.erp_start_interview(p_code text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare v_id uuid;
begin
  perform erp.authorise('administration.configure');
  v_id := erp.start_interview(p_code);
  return jsonb_build_object('session_id', v_id);
end;
$$;

create or replace function public.erp_answer_interview(
  p_session_id uuid, p_question_code text, p_answer jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure');
  return erp.answer_interview(p_session_id, p_question_code, p_answer);
end;
$$;

create or replace function public.erp_propose_from_interview(p_session_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
begin
  perform erp.authorise('administration.configure');
  return erp_ai.propose_from_interview(p_session_id);
end;
$$;

create or replace function public.erp_proposals(p_status text default null)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare v_tenant uuid;
begin
  perform erp.authorise('administration.read');
  v_tenant := erp.require_tenant_id();

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'proposal_id', p.id, 'kind', p.kind::text, 'title', p.title,
             'rationale', p.rationale, 'status', p.status::text,
             'change_set_id', p.change_set_id,
             'change_set_code', cs.code, 'change_set_status', cs.status::text,
             'item_count', (select count(*) from erp.change_set_item i
                             where i.tenant_id = v_tenant
                               and i.change_set_id = p.change_set_id),
             'producer_label', p.producer_label,
             'created_at', p.created_at,
             -- §3.12 asks for explainability, which means what was inspected
             -- and not only what was concluded.
             'evidence', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'source_kind', ev.source_kind, 'source_ref', ev.source_ref,
                        'observation', ev.observation) order by ev.id)
                 from erp_ai.proposal_evidence ev
                where ev.tenant_id = v_tenant and ev.proposal_id = p.id),
               '[]'::jsonb))
           order by p.created_at desc)
      from erp_ai.proposal p
      left join erp.change_set cs
        on cs.tenant_id = p.tenant_id and cs.id = p.change_set_id
     where p.tenant_id = v_tenant
       and (p_status is null or p.status::text = p_status)), '[]'::jsonb);
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.erp_interview_questions(uuid)',
    'public.erp_start_interview(text)',
    'public.erp_answer_interview(uuid, text, jsonb)',
    'public.erp_propose_from_interview(uuid)',
    'public.erp_proposals(text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end;
$$;

insert into erp_meta.public_write_allowance (function_name, gate, rationale)
values
  ('erp_start_interview', 'erp.authorise',
   'Starts an onboarding interview. Writes erp.interview_session and nothing else.'),
  ('erp_answer_interview', 'erp.authorise',
   'Records one answer. Writes erp.interview_answer and nothing else.'),
  ('erp_propose_from_interview', 'erp.authorise',
   'Turns answers into change sets and proposals. Every change it suggests is '
   'a change-set item promoted through B6; it writes no configuration itself.')
on conflict (function_name) do update set
  gate = excluded.gate, rationale = excluded.rationale;

-- ── Prove it ─────────────────────────────────────────────────────────────────

select erp.apply_row_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();

select erp.assert_public_api_safe();
select erp.assert_isolation();
select erp.assert_audit_coverage();
select erp.assert_attribution_coverage();
-- The one that matters most here: nothing on the transaction path may reach
-- erp_ai, and this migration adds a function to erp_ai that calls back into erp.
select erp.assert_intelligence_boundary();
select erp.assert_configuration_promotable();
