set lock_timeout = '30s';

-- =============================================================================
-- 20260927100000  A count has a sheet
-- -----------------------------------------------------------------------------
-- PR10, M1b: node I1 of docs/spec/simplification-review.md, second half. The
-- lifecycle landed in M1a (20260927000000); this adds the document.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- "The base type `count` exists in reference data and no installer ever
-- creates a tenant document type from it, so a count has no number, no
-- lifecycle, no document authorisation and no printable sheet."
--
-- And the base type said two things that were not true of any count: that it
-- moves stock and reaches the ledger. What a count moves is posted by
-- erp.post_count(), task by task, through the movement and
-- erp.post_movement_finance(); a document on this base type posts nothing,
-- and a later milestone (I4) gives the variance an adjustment of its own.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * The count sheet, shipped as configuration from one helper,
--     erp.count_sheet_pack_items(): a lifecycle (count_sheet: draft, issued,
--     closed), a numbering rule (CNT-), a document type on base type count,
--     and an output template listing each place with a blank for its figure.
--     Installed by erp.configure_inventory() and offered as version 7 of
--     inventory-operations to an organisation on version 6.
--   * erp_ref.document_type 'count' posts nothing: affects_stock and
--     affects_finance are false, so no finding asks the sheet for a movement
--     type or a posting rule it must never have.
--   * One sheet per site a raise reaches (a programme on one site: one per
--     raise), opened through erp.open_document(), which is its document
--     authorisation. Each task raised is a line of it: count_task.document_id
--     and count_task.document_line_id. The sheet is issued once every place is
--     on it. An organisation with no count sheet type — one on version 6 —
--     raises its tasks as before, with no sheet.
--   * The sheet closes itself when the last of its tasks is posted or
--     cancelled: erp.close_count_sheet_when_finished(), called by
--     erp.move_count_task(), the one routine that moves a task. The close is
--     the system's move, derived from erp.count_sheet_is_finished() (decision
--     6, 20260922380000), so whoever posts the last count is not refused for
--     holding no inventory.count; by hand it is refused while a count is open.
--   * erp_render_count_sheet: the sheet rendered for printing, authorised by
--     inventory.count on the sheet's site — the permission that raised it —
--     rather than administration.configure, which the configuration preview
--     erp_render_output_template asks for.
--   * The registers that answer for it: the reversal route (a count sheet
--     posts nothing, so there is nothing to reverse), its coverage report,
--     and the transition driver register.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * A blind count. erp.count_programme has no setting for one, so the sheet
--     prints the expected quantity. Hiding it is a programme setting and a
--     template of its own, for when somebody asks.
--   * The screen: a Print button on the Counting screen. The door is
--     registered as waiting for it (erp_meta.api_only_door, pending_screen).
--     The client's DOOR_ONLY_TRANSITIONS (src/components/erp/available-
--     transitions.ts) and its test take count_sheet: issue and close in the
--     same pull request: src/lib/stage-records.test.ts holds that list to the
--     newest restatement of the driver register, which this is.
--   * The sheet's lines are the expectation when the count was raised. A task
--     counted again re-reads its expectation (erp.recount_task()); the line
--     does not follow, and a sheet printed after a recount shows the first.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The refusals this adds
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_COUNT_SHEET_NOT_FINISHED',
  'Closing a count sheet while a count on it is still open, waiting or approved and not yet posted.',
  'A count sheet closes when every count on it has been posted or cancelled; closed early, it would say the count was over while a place on it is still locked.',
  'Post or cancel the counts still on the sheet. The sheet closes itself with the last of them.');

select erp.register_refusal('CLOVEERP_COUNT_SHEET_LINES_ARE_ITS_COUNTS',
  'Adding a line to a count sheet by hand.',
  'Each line of a count sheet is a count the raise put on it, with a lock on its place; a line added by hand would be a place printed for counting that nothing counts.',
  'Raise a count for the place from Counting. It goes on a sheet of its own.');

select erp.register_refusal('CLOVEERP_COUNT_SHEET_IS_RAISED',
  'Opening a count sheet by hand.',
  'A count sheet is the counts a raise put on it, each with a lock on its place; one opened by hand has no counts, and would be issued with nothing on it and never close.',
  'Raise the programme from Counting. Its sheet is opened with its counts.');

select erp.register_refusal('CLOVEERP_NOT_A_COUNT_SHEET',
  'Printing something as a count sheet that is not one.',
  'Only a document raised by a count carries the places and the counts a count sheet prints.',
  'Open the count sheet from Counting and print it from there.');

select erp.register_refusal('CLOVEERP_COUNT_SHEET_HAS_NO_TEMPLATE',
  'Printing a count sheet in an organisation with no count sheet layout.',
  'The sheet is printed from an output template on base type count, and this organisation has none active.',
  'Restore the count sheet layout on the Output screen, or upgrade inventory operations.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The base type posts nothing
--
-- Read by erp.transition_document(), erp.post_document_stock(),
-- erp.post_document_finance(), erp.dead_configuration_report(),
-- erp.determination_coverage_report(), erp.inventory_configuration_report()
-- and the reversal coverage report. No organisation holds a document type on
-- it before this migration, so nothing it says has ever been acted on.
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.document_type
   set affects_stock = false,
       affects_finance = false,
       description = 'A count sheet: the places one raise put to be counted, each with a blank for '
                  || 'its figure. It posts nothing; each count posts its own variance through '
                  || 'erp.post_count() (20260927100000).'
 where code = 'count';

do $base$
begin
  if (select affects_stock or affects_finance from erp_ref.document_type where code = 'count')
     is distinct from false then
    raise exception 'CLOVEERP_ANCHOR_MOVED: base type count is missing or still claims to post';
  end if;
end
$base$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. A task is a line of its sheet
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp.count_task
  add column document_id uuid,
  add column document_line_id uuid,
  add constraint count_task_document_fkey
    foreign key (tenant_id, document_id) references erp.document (tenant_id, id) on delete restrict,
  add constraint count_task_document_line_fkey
    foreign key (tenant_id, document_line_id) references erp.document_line (tenant_id, id) on delete restrict,
  -- A line belongs to a sheet: one without the other is a task half on it.
  add constraint count_task_sheet_line_together
    check ((document_id is null) = (document_line_id is null));

create index count_task_document_idx on erp.count_task (tenant_id, document_id)
  where document_id is not null;
create unique index count_task_document_line_key on erp.count_task (tenant_id, document_line_id)
  where document_line_id is not null;

comment on column erp.count_task.document_id is
  'The count sheet this task is a line of (20260927100000); null for a task raised before its organisation had one.';
comment on column erp.count_task.document_line_id is
  'The line of the count sheet this task is (20260927100000); null with document_id.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. Two fields a count sheet prints
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.output_field (code, source, label_key, description, is_line, seq) values
  ('expected_quantity', 'line', 'output.field.expected_quantity',
   'What the stock ledger held at the place when the count was raised.', true, 232),
  ('counted_quantity', 'line', 'output.field.counted_quantity',
   'A blank, for the figure the counter writes down.', true, 234)
on conflict (code) do update
  set source = excluded.source, label_key = excluded.label_key,
      description = excluded.description, is_line = excluded.is_line, seq = excluded.seq;

insert into erp_ref.resource (key, locale, value, description) values
  ('output.field.expected_quantity', 'en', 'Expected', 'Starter Content Packs §9.3 output field label.'),
  ('output.field.expected_quantity', 'de', 'Erwartet', null),
  ('output.field.counted_quantity', 'en', 'Counted', 'Starter Content Packs §9.3 output field label.'),
  ('output.field.counted_quantity', 'de', 'Gezählt', null),
  ('output.block.counted_by', 'en', 'Counted by', 'Starter Content Packs §9.3 output block heading.'),
  ('output.block.counted_by', 'de', 'Gezählt von', null),
  ('output.template.count_sheet', 'en', 'Count sheet', 'Starter Content Packs §9.3 output template name.'),
  ('output.template.count_sheet', 'de', 'Zählliste', null)
on conflict (key, locale) do nothing;

-- The renderer resolves them. Deployed body, asserted needle.
do $render$
declare
  v_sig constant text := 'erp.render_output_template(text,uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$                    when 'supplier_item_code' then to_jsonb(l.supplier_item_code)
$o$;
  v_new constant text := $n$                    when 'supplier_item_code' then to_jsonb(l.supplier_item_code)
                    -- A count sheet's two (20260927100000): the line's
                    -- quantity is what was expected, and the figure counted
                    -- is a blank to write in.
                    when 'expected_quantity'  then to_jsonb(l.quantity)
                    when 'counted_quantity'   then 'null'::jsonb
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % supplier item code anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$render$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. The sheet, from one helper
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.count_sheet_pack_items()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  -- The count sheet (20260927100000), read by erp.configure_inventory() for a
  -- new install and by the upgrade register for an organisation on version 6,
  -- so the two cannot disagree. In the order a change set applies them: the
  -- lifecycle and the sequence before the type that names them.
  --
  -- The lifecycle is the raise's and the counts', not a person's. Issued by
  -- erp.raise_count_tasks() once every place is on the sheet, asking what
  -- raising asks; closed by erp.close_count_sheet_when_finished() when the
  -- last of its counts is posted or cancelled, derived from
  -- erp.count_sheet_is_finished(). No state is committed: a count sheet
  -- posts nothing, and is not a document posted.
  select jsonb_build_array(
    jsonb_build_object('kind', 'state_machine', 'key', 'count_sheet', 'payload',
      jsonb_build_object(
        'code', 'count_sheet', 'object_type', 'document', 'name', 'Count sheet',
        'states', jsonb_build_array(
          jsonb_build_object('code','draft','name','Draft','is_initial',true,'is_terminal',false,'is_committed',false,'sort_order',10),
          jsonb_build_object('code','issued','name','Issued','is_initial',false,'is_terminal',false,'is_committed',false,'sort_order',20),
          jsonb_build_object('code','closed','name','Closed','is_initial',false,'is_terminal',true,'is_committed',false,'sort_order',30)),
        'transitions', jsonb_build_array(
          jsonb_build_object('code','issue','name','Issue','from','draft','to','issued','required_permission','inventory.count','sort_order',10),
          jsonb_build_object('code','close','name','Close','from','issued','to','closed','required_permission','inventory.count','sort_order',20)))),
    jsonb_build_object('kind', 'numbering_rule', 'key', 'count_sheet', 'payload',
      jsonb_build_object('code','count_sheet','prefix','CNT-','pad_to',6,
                         'reset_period','yearly','next_value',1)),
    jsonb_build_object('kind', 'document_type', 'key', 'count_sheet', 'payload',
      jsonb_build_object('code','count_sheet','base_type','count',
                         'name','Count sheet','numbering_rule','count_sheet',
                         'state_machine','count_sheet',
                         'create_permission','inventory.count')),
    jsonb_build_object('kind', 'output_template', 'key', 'count_sheet', 'payload',
      jsonb_build_object(
        'code','count_sheet','name_key','output.template.count_sheet',
        'kind','document','base_type','count','page','A4',
        'blocks', jsonb_build_array(
          jsonb_build_object('kind','title','fields',jsonb_build_array('document_number')),
          jsonb_build_object('kind','issuer','fields',jsonb_build_array('entity_name')),
          jsonb_build_object('kind','summary','fields',jsonb_build_array('document_date','our_reference','line_count')),
          jsonb_build_object('kind','lines','fields',jsonb_build_array(
            'line_no','location','item_code','description','batch',
            'expected_quantity','uom','counted_quantity')),
          jsonb_build_object('kind','signature','label_key','output.block.counted_by')))))
$$;

comment on function erp.count_sheet_pack_items() is
  'The count sheet (20260927100000): its lifecycle, numbering rule, document type and output '
  'template, the items erp.configure_inventory() and the inventory-operations upgrade register both read.';

do $configure$
declare
  v_sig constant text := 'erp.configure_inventory(erp.costing_method,text,numeric,numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    || jsonb_build_array(erp.count_task_lifecycle_item()));$o$;
  v_new constant text := $n$    || jsonb_build_array(erp.count_task_lifecycle_item())
    -- The count sheet (20260927100000), from its one helper.
    || erp.count_sheet_pack_items());$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % count task lifecycle item found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$configure$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A6. The upgrade register: version 7 for an organisation on version 6
-- ─────────────────────────────────────────────────────────────────────────────

update erp_ref.module_installer
   set current_version = 7,
       description = description
         || ' Version 7 (20260927100000): a count has a sheet — numbered, authorised as a '
         || 'document and printable — and each task raised is a line of it.'
 where install_code = 'inventory-operations' and current_version = 6;

insert into erp_ref.module_upgrade_item (install_code, to_version, object_kind, object_key, payload, seq)
select 'inventory-operations', 7, i.value ->> 'kind', i.value ->> 'key', i.value -> 'payload',
       200 + 10 * i.ordinality::integer
  from jsonb_array_elements(erp.count_sheet_pack_items()) with ordinality as i(value, ordinality)
on conflict (install_code, to_version, object_kind, object_key)
  do update set payload = excluded.payload, seq = excluded.seq;

do $register$
begin
  if (select current_version from erp_ref.module_installer
       where install_code = 'inventory-operations') is distinct from 7 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: the inventory-operations installer is not at version 7';
  end if;
  if (select count(*) from erp_ref.module_upgrade_item ui
       join jsonb_array_elements(erp.count_sheet_pack_items()) i
         on i.value ->> 'kind' = ui.object_kind and i.value ->> 'key' = ui.object_key
        and i.value -> 'payload' = ui.payload
      where ui.install_code = 'inventory-operations' and ui.to_version = 7) <> 4
     or (select count(*) from erp_ref.module_upgrade_item ui
          where ui.install_code = 'inventory-operations' and ui.to_version = 7) <> 4 then
    raise exception 'CLOVEERP_UPGRADE_NOT_REGISTERED: version 7 of inventory-operations is not the four items the count sheet ships';
  end if;
end
$register$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A7. When a sheet is finished, and the routine that closes it
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.count_sheet_is_finished(p_document_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- A count sheet is finished when it carries counts and every one of them
  -- is posted or cancelled (20260927100000). Read by the routine that closes
  -- it, by the engine as the fact the close is derived from, and by
  -- erp.transition_document() to refuse the close by hand before then.
  select exists (select 1 from erp.count_task t
                  where t.tenant_id = erp.current_tenant_id() and t.document_id = p_document_id)
     and not exists (select 1 from erp.count_task t
                      where t.tenant_id = erp.current_tenant_id() and t.document_id = p_document_id
                        and t.status not in ('posted', 'cancelled'))
$$;

revoke all on function erp.count_sheet_is_finished(uuid) from public, anon;

comment on function erp.count_sheet_is_finished(uuid) is
  'True when a count sheet carries counts and every one is posted or cancelled (20260927100000).';

create or replace function erp.close_count_sheet_when_finished(p_document_id uuid)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_prev text;
begin
  -- Issued, and every count on it finished: the sheet closes. Called by
  -- erp.move_count_task() after a task is posted or cancelled; does nothing
  -- to a sheet with a count still in flight, one already closed, or one with
  -- no lifecycle. The move is the system's, derived from the fact, named in
  -- erp.deriving_move immediately before it and put back after, so whoever
  -- finished the last count is not refused for holding no inventory.count.
  if p_document_id is null then
    return false;
  end if;

  -- Two last counts finished at once each see the other still open under
  -- their own snapshot, and neither would close the sheet (found on
  -- review). The sheet's row is taken first, so the second to take it reads
  -- the first's post, committed, and closes it.
  perform 1 from erp.document d
   where d.tenant_id = erp.current_tenant_id() and d.id = p_document_id
     for update;

  if erp.object_current_state('document', p_document_id) is distinct from 'issued'
     or not erp.count_sheet_is_finished(p_document_id) then
    return false;
  end if;

  v_prev := coalesce(current_setting('erp.deriving_move', true), '');
  perform set_config('erp.deriving_move', p_document_id::text || ':close', true);
  perform erp.transition_document(p_document_id, 'close');
  perform set_config('erp.deriving_move', v_prev, true);
  return true;
end;
$$;

revoke all on function erp.close_count_sheet_when_finished(uuid) from public, anon;

comment on function erp.close_count_sheet_when_finished(uuid) is
  'Closes a count sheet when the last of its counts is posted or cancelled (20260927100000): '
  'the system''s move, derived from erp.count_sheet_is_finished().';

-- The fact the close is derived from, read again with the sheet's state
-- locked. Deployed body, asserted needle: one arm more in the document case.
do $derived$
declare
  v_sig constant text := 'erp.derived_move_fact(text,uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$             then 'erp.sales_order_is_settled'
$o$;
  v_new constant text := $n$             then 'erp.sales_order_is_settled'
           -- A count sheet's close, when the last of its counts is posted or
           -- cancelled (20260927100000), asked for by
           -- erp.close_count_sheet_when_finished().
           when dt.base_type_code = 'count' and p_transition_code = 'close'
            and erp.object_current_state('document', p_object_id) = 'issued'
            and erp.count_sheet_is_finished(p_object_id)
             then 'erp.count_sheet_is_finished'
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % sales order arm found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$derived$;

-- By hand, a count sheet is not closed over a count still in flight.
do $transition$
declare
  v_sig constant text := 'erp.transition_document(uuid,text,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);
$o$;
  v_new constant text := $n$  -- A count sheet closes with its last count (20260927100000):
  -- erp.close_count_sheet_when_finished() makes the move when the fact
  -- holds, and this stops it being made over a count still in flight.
  if dt.base_type_code = 'count' and p_transition_code = 'close'
     and not erp.count_sheet_is_finished(p_document_id) then
    raise exception
      'CLOVEERP_COUNT_SHEET_NOT_FINISHED: % still carries % count(s) not posted or cancelled',
      coalesce(d.document_number, p_document_id::text),
      (select count(*) from erp.count_task t
        where t.tenant_id = v_tenant and t.document_id = p_document_id
          and t.status not in ('posted', 'cancelled'))
      using errcode = '23514',
            hint = 'Post or cancel the counts still on the sheet. The sheet closes itself with the last of them.';
  end if;

  v_ctx := erp.document_transition_context(p_document_id, p_transition_code);
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % context anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$transition$;

-- The one routine that moves a task closes its sheet with the last of them.
do $move$
declare
  v_sig constant text := 'erp.move_count_task(uuid,text,erp.count_task_status,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$
  return p_to;
end;$o$;
  v_new constant text := $n$
  -- The sheet the task is a line of closes with the last of its counts
  -- (20260927100000). A task raised with no sheet has nothing to close.
  if p_to in ('posted', 'cancelled') then
    perform erp.close_count_sheet_when_finished(t.document_id)
       from erp.count_task t
      where t.tenant_id = v_tenant and t.id = p_task_id and t.document_id is not null;
  end if;

  return p_to;
end;$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % return anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$move$;

-- A count sheet's lines are the counts the raise put on it.
do $lines$
declare
  v_sig constant text := 'erp.add_document_line(uuid,uuid,numeric,bigint,text,date)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  perform erp.authorise(v_perm, d.entity_id, d.site_id, null,
                        'document', p_document_id);
$o$;
  v_new constant text := $n$  perform erp.authorise(v_perm, d.entity_id, d.site_id, null,
                        'document', p_document_id);

  -- Each line of a count sheet is a count, with a lock on its place, and
  -- erp.raise_count_tasks() writes them (20260927100000).
  if v_base = 'count' then
    raise exception
      'CLOVEERP_COUNT_SHEET_LINES_ARE_ITS_COUNTS: % is a count sheet, and its lines are the counts raised on it',
      d.document_number
      using errcode = '23514',
            hint = 'Raise a count for the place from Counting. It goes on a sheet of its own.';
  end if;
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % authorise anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$lines$;

-- An issued count sheet's lines stay what the raise put on them. A line is
-- written by the raise while its sheet is a draft; once issued, the doors
-- that amend a line, move its stock identity or price it would send a
-- counter to a place nobody counts, against an expectation nobody holds
-- (found on review). One trigger holds every door, not a guard in each.
create or replace function erp.protect_issued_count_sheet()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_doc    uuid := coalesce(new.document_id, old.document_id);
  v_tenant uuid := coalesce(new.tenant_id, old.tenant_id);
  v_number text;
begin
  select d.document_number into v_number
    from erp.document d
    join erp.document_type dt on dt.tenant_id = d.tenant_id and dt.id = d.document_type_id
   where d.tenant_id = v_tenant and d.id = v_doc and dt.base_type_code = 'count';

  if found
     and nullif(current_setting('erp.purge_tenant_id', true), '') is null
     and coalesce(erp.object_current_state('document', v_doc), 'draft') <> 'draft' then
    raise exception
      'CLOVEERP_COUNT_SHEET_LINES_ARE_ITS_COUNTS: % is issued, and its lines are the counts raised on it',
      coalesce(v_number, v_doc::text)
      using errcode = '23514',
            hint = 'Raise a count for the place from Counting. It goes on a sheet of its own.';
  end if;
  return coalesce(new, old);
end;
$$;

revoke all on function erp.protect_issued_count_sheet() from public, anon;

comment on function erp.protect_issued_count_sheet() is
  'Refuses any write to a line of an issued count sheet (20260927100000): the raise writes its '
  'lines while it is a draft, and nothing changes them after.';

drop trigger if exists t_document_line_count_sheet on erp.document_line;
create trigger t_document_line_count_sheet
  before insert or update or delete on erp.document_line
  for each row execute function erp.protect_issued_count_sheet();

-- A count's line holds no stock for anything: reserving it would hold
-- stock against a document that never consumes or releases it.
do $reserve$
declare
  v_sig constant text := 'erp.reserve_for_line(uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  select * into d from erp.document where tenant_id = v_tenant and id = l.document_id;
$o$;
  v_new constant text := $n$  select * into d from erp.document where tenant_id = v_tenant and id = l.document_id;

  -- A count sheet's line is a count, and reserves nothing (20260927100000).
  if exists (select 1 from erp.document_type dt
              where dt.tenant_id = v_tenant and dt.id = d.document_type_id
                and dt.base_type_code = 'count') then
    raise exception
      'CLOVEERP_COUNT_SHEET_LINES_ARE_ITS_COUNTS: % is a count sheet, and its lines are the counts raised on it',
      d.document_number
      using errcode = '23514',
            hint = 'Raise a count for the place from Counting. It goes on a sheet of its own.';
  end if;
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % document anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$reserve$;

-- A count sheet is opened by raising counts. One opened by hand has no
-- counts, is issued with nothing on it, and never closes (found on review).
-- The two doors that open a document of a type the caller names refuse it;
-- erp.raise_count_tasks() opens its sheets through erp.open_document().
do $create$
declare
  v_doors constant text[] := array[
    'public.erp_create_document(text,uuid,uuid,text,date,uuid,text,uuid)',
    $a$begin
  v_id := erp.open_document(p_type_code, p_party_id, p_entity_id,$a$,
    'erp.create_document_full(text,uuid,uuid,text,date,text,jsonb,text)',
    $a$begin
  v_id := erp.open_document(
    p_type_code,$a$];
  v_guard constant text := $g$begin
  -- A count sheet is opened by raising counts (20260927100000).
  if exists (select 1 from erp.document_type dt
              where dt.tenant_id = erp.current_tenant_id() and dt.code = p_type_code
                and dt.base_type_code = 'count') then
    raise exception
      'CLOVEERP_COUNT_SHEET_IS_RAISED: % is a count sheet, opened when its counts are raised',
      p_type_code
      using errcode = '23514',
            hint = 'Raise the programme from Counting. Its sheet is opened with its counts.';
  end if;
$g$;
  v_def text;
  v_old text;
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_doors, 1) / 2 loop
    v_def := pg_get_functiondef(v_doors[2*v_i - 1]::regprocedure);
    v_old := v_doors[2*v_i];
    v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % open anchor found % time(s)', v_doors[2*v_i - 1], v_hits;
    end if;
    execute replace(v_def, v_old, v_guard || substr(v_old, length('begin
') + 1));
  end loop;
end
$create$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A8. Raising opens the sheet, puts each task on it, and issues it
--
-- Where the organisation has a count sheet type. One on version 6 has none,
-- and raises as it did. One whose sheet lifecycle is not in force today is
-- told so, by the refusal erp.generate_count_tasks() already confines to its
-- programme. One sheet per site, because a document has one: a programme on
-- one site raises one sheet each time it is raised.
-- ─────────────────────────────────────────────────────────────────────────────

do $raise$
declare
  v_sig constant text := 'erp.raise_count_tasks(text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  v_lifecycle boolean;
begin$o$,
    $n$  v_lifecycle boolean;
  v_sheet_type text;
  v_sheet_dt   uuid;
  v_sheets     jsonb := '{}'::jsonb;
  v_sheet      uuid;
  v_line       uuid;
  v_line_nos   jsonb := '{}'::jsonb;
  v_line_no    integer;
begin$n$,
    $o$      using errcode = '23514',
            hint = 'Restore the count task lifecycle on the Configuration screen, or promote a version of it in force today.';
  end if;
$o$,
    $n$      using errcode = '23514',
            hint = 'Restore the count task lifecycle on the Configuration screen, or promote a version of it in force today.';
  end if;

  -- The count sheet (20260927100000), where the organisation has a type of
  -- one, decided once for the run like the lifecycle above.
  select dt.code, dt.id into v_sheet_type, v_sheet_dt
    from erp.document_type dt
   where dt.tenant_id = v_tenant and dt.base_type_code = 'count' and dt.status = 'active'
   order by (dt.site_id is not null), dt.code
   limit 1;

  if v_sheet_type is not null and not exists (
       select 1 from erp.document_type dt
         join erp.state_machine sm
           on sm.tenant_id = dt.tenant_id and sm.code = dt.state_machine_code
          and sm.object_type = 'document' and sm.status = 'active'
         join erp.state_machine_version smv
           on smv.tenant_id = sm.tenant_id and smv.state_machine_id = sm.id
          and smv.status = 'active'
          and daterange(smv.effective_from, smv.effective_to, '[)') @> current_date
        where dt.tenant_id = v_tenant and dt.id = v_sheet_dt) then
    raise exception 'CLOVEERP_COUNT_LIFECYCLE_NOT_IN_FORCE: the organisation''s count sheet lifecycle is not in force today, so programme % raises no count',
      pg.code
      using errcode = '23514',
            hint = 'Restore the count sheet lifecycle on the Configuration screen, or promote a version of it in force today.';
  end if;
$n$,
    $o$    insert into erp.count_task (
      tenant_id, count_programme_id, site_id, location_id, item_id, batch_id,
      expected_quantity, committed_quantity, status,
      owner_party_id, container_id, counts_container)
    values (v_tenant, pg.id, r.site_id, r.location_id, r.item_id, r.batch_id,
            r.quantity, v_committed, 'open',
            r.owner_party_id, r.container_id, r.counts_container)
    returning id into v_task;
$o$,
    $n$    -- The place goes on its site's sheet, opened for the first place the
    -- raise finds there through the door every document is opened by.
    v_sheet := null;
    v_line := null;
    if v_sheet_type is not null then
      v_sheet := (v_sheets ->> r.site_id::text)::uuid;
      if v_sheet is null then
        v_sheet := erp.open_document(v_sheet_type, null,
                                     (select s.entity_id from erp.site s
                                       where s.tenant_id = v_tenant and s.id = r.site_id),
                                     r.site_id);
        update erp.document
           set our_reference = pg.code, notes = pg.name, updated_at = now()
         where tenant_id = v_tenant and id = v_sheet;
        v_sheets := v_sheets || jsonb_build_object(r.site_id::text, v_sheet);
      end if;

      v_line_no := coalesce((v_line_nos ->> v_sheet::text)::integer, 0) + 10;
      v_line_nos := v_line_nos || jsonb_build_object(v_sheet::text, v_line_no);
      insert into erp.document_line (
        tenant_id, document_id, line_no, item_id, description, quantity, uom_id,
        batch_id, location_id, container_id, unit_price_minor, net_minor)
      values (
        v_tenant, v_sheet, v_line_no, r.item_id, erp.line_description(r.item_id, null),
        r.quantity, erp.item_line_uom(r.item_id, v_sheet_dt),
        r.batch_id, r.location_id, r.container_id, 0, 0)
      returning id into v_line;
    end if;

    insert into erp.count_task (
      tenant_id, count_programme_id, site_id, location_id, item_id, batch_id,
      expected_quantity, committed_quantity, status,
      owner_party_id, container_id, counts_container,
      document_id, document_line_id)
    values (v_tenant, pg.id, r.site_id, r.location_id, r.item_id, r.batch_id,
            r.quantity, v_committed, 'open',
            r.owner_party_id, r.container_id, r.counts_container,
            v_sheet, v_line)
    returning id into v_task;
$n$,
    $o$  return v_n;
end;$o$,
    $n$  -- Each sheet is issued once every place the raise found is on it.
  for v_sheet in select (e.value #>> '{}')::uuid from jsonb_each(v_sheets) e loop
    perform erp.transition_document(v_sheet, 'issue');
  end loop;

  return v_n;
end;$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$raise$;

comment on function erp.raise_count_tasks(text) is
  'Raises a count task for every place a programme selects, with its lock and, where the '
  'organisation has them, its lifecycle and its line on the site''s count sheet, which is '
  'numbered, opened through erp.open_document() and issued once every place is on it '
  '(20260927100000). Authorises inventory.count.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A9. The sheet printed, by whoever may count
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.render_count_sheet(p_document_id uuid, p_locale text default null)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tenant   uuid := erp.require_tenant_id();
  d          erp.document%rowtype;
  v_template text;
begin
  select doc.* into d
    from erp.document doc
    join erp.document_type dt on dt.tenant_id = doc.tenant_id and dt.id = doc.document_type_id
   where doc.tenant_id = v_tenant and doc.id = p_document_id and dt.base_type_code = 'count';
  if not found then
    raise exception 'CLOVEERP_NOT_A_COUNT_SHEET: % is not a count sheet in this organisation', p_document_id
      using errcode = '23503',
            hint = 'Open the count sheet from Counting and print it from there.';
  end if;

  -- What raising the sheet asked, on the sheet's own site: whoever may count
  -- there may print what they are to count. The configuration preview asks
  -- administration.configure, which a counter does not hold.
  perform erp.authorise('inventory.count', d.entity_id, d.site_id, null,
                        'document', p_document_id);

  select ot.code into v_template
    from erp.output_template ot
   where ot.tenant_id = v_tenant and ot.base_type_code = 'count'
     and ot.kind = 'document' and ot.status = 'active'
   order by (ot.code = 'count_sheet') desc, ot.code
   limit 1;
  if v_template is null then
    raise exception 'CLOVEERP_COUNT_SHEET_HAS_NO_TEMPLATE: this organisation has no count sheet layout to print % with',
      d.document_number
      using errcode = '23503',
            hint = 'Restore the count sheet layout on the Output screen, or upgrade inventory operations.';
  end if;

  return erp.render_output_template(v_template, p_document_id,
    coalesce(p_locale, erp.resolve_locale('document', d.entity_id)));
end;
$$;

revoke all on function erp.render_count_sheet(uuid, text) from public, anon;

comment on function erp.render_count_sheet(uuid, text) is
  'Renders a count sheet for printing through its organisation''s count sheet layout '
  '(20260927100000). Authorises inventory.count on the sheet''s site.';

create or replace function public.erp_render_count_sheet(p_document_id uuid, p_locale text default null)
returns jsonb
language sql
set search_path = ''
as $$ select erp.render_count_sheet(p_document_id, p_locale) $$;

revoke all on function public.erp_render_count_sheet(uuid, text) from public, anon;
grant execute on function public.erp_render_count_sheet(uuid, text) to authenticated, service_role;

comment on function public.erp_render_count_sheet(uuid, text) is
  'A count sheet, rendered for printing (20260927100000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_render_count_sheet', 'erp.render_count_sheet',
   'Renders a count sheet through the organisation''s count sheet layout and returns it; authorises inventory.count on the sheet''s site. Volatile for the access-log row erp.authorise() writes; the render is not stored.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

-- Until the Counting screen offers it.
insert into erp_meta.api_only_door (function_name, caller, intended_screen_path, reason) values
  ('erp_render_count_sheet', 'pending_screen', '/inventory/audit',
   'Renders the count sheet a raise opened, for the counters to take to the shelves. Belongs as Print beside each sheet on the Counting screen, which does not show sheets yet.')
on conflict (function_name) do update
  set caller = excluded.caller, intended_screen_path = excluded.intended_screen_path, reason = excluded.reason;

select erp_meta.add_help_actions('/inventory/audit', array['erp_render_count_sheet']);

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). A count sheet, shown and printed from the Counting screen (20260927100000).'
  from (values
    ('Count sheet'),
    ('Print the count sheet'),
    ('Every place this count was raised for, with a blank for the figure. The sheet closes itself when the last count on it is posted or cancelled.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- A10. The registers that answer for it
-- ─────────────────────────────────────────────────────────────────────────────

-- The driver register, restated whole as every change to it is: both of the
-- count sheet's moves are routines', so neither is a button
-- (src/components/erp/available-transitions.ts reads the newest restatement).
create or replace function erp.transition_driver_register()
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_agg(to_jsonb(x) order by x.machine_code, x.transition_code)
    from (values
      -- ── Procurement ───────────────────────────────────────────────────────
      ('requisition'::text,  'submit'::text,           'screen'::text, ''::text),
      ('requisition',        'approve',                'screen', ''),
      ('requisition',        'reject',                 'screen', ''),
      -- Ordered because an order was raised from all of it (20260922360000).
      -- The routine's move takes its authority from that fact, whatever
      -- permission the organisation puts on the move (PR4 decision 6, D8,
      -- 20260922380000); the permission governs only a move made by hand.
      ('requisition',        'order',                  'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('requisition',        'cancel',                 'screen', ''),
      ('requisition',        'cancel_submitted',       'screen', ''),

      ('purchase_order',     'submit',                 'screen', ''),
      ('purchase_order',     'approve',                'screen', ''),
      -- Approved with its requisition, by the conversion that raises it and
      -- by nothing else (20260922380000).
      ('purchase_order',     'inherit_approval',       'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('purchase_order',     'reject',                 'screen', ''),
      ('purchase_order',     'send',                   'screen', ''),
      ('purchase_order',     'receive_partial',        'routine', 'erp.advance_orders_for_receipt(uuid)'),
      -- The receipt makes it, and a person may, with a reason, when nothing
      -- more is coming (20260922360000).
      ('purchase_order',     'receive_rest',           'screen', ''),
      ('purchase_order',     'receive_all',            'routine', 'erp.advance_orders_for_receipt(uuid)'),
      -- The bill makes it (erp.close_order_when_settled), and a person may,
      -- with a reason, when the bill is kept elsewhere (20260922360000). The
      -- bill's close takes its authority from erp.order_is_settled(), whatever
      -- permission the organisation puts on the move (PR4 decision 6, D8,
      -- 20260922380000); the permission governs only the close by hand.
      ('purchase_order',     'close',                  'screen', ''),
      ('purchase_order',     'cancel',                 'screen', ''),
      ('purchase_order',     'cancel_approved',        'screen', ''),

      ('goods_receipt',      'post',                   'screen', ''),
      ('goods_receipt',      'cancel',                 'screen', ''),

      ('purchase_invoice',   'register',               'screen', ''),
      ('purchase_invoice',   'dispute',                'screen', ''),
      ('purchase_invoice',   'resolve',                'screen', ''),
      ('purchase_invoice',   'pay',                    'routine', 'erp.settle_paid_document(uuid,text)'),
      ('purchase_invoice',   'cancel',                 'screen', ''),

      ('purchase_credit_note', 'issue',                'screen', ''),
      ('purchase_credit_note', 'cancel',               'screen', ''),

      -- ── Sales ─────────────────────────────────────────────────────────────
      ('quotation',          'send',                   'screen', ''),
      ('quotation',          'accept',                 'routine', 'erp.convert_document(uuid,uuid,uuid,jsonb,text)'),
      ('quotation',          'decline',                'screen', ''),
      ('quotation',          'expire',                 'screen', ''),

      ('sales_order',        'submit',                 'screen', ''),
      ('sales_order',        'approve',                'screen', ''),
      ('sales_order',        'reject',                 'screen', ''),
      ('sales_order',        'pick',                   'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch',               'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch_part',          'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch_part_picked',   'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'despatch_rest',          'routine', 'erp.advance_orders_for_delivery(uuid)'),
      ('sales_order',        'invoice',                'routine', 'erp.advance_orders_for_invoice(uuid)'),
      ('sales_order',        'close',                  'screen', ''),
      ('sales_order',        'cancel',                 'screen', ''),
      ('sales_order',        'cancel_confirmed',       'screen', ''),

      ('delivery',           'post',                   'screen', ''),
      ('delivery',           'cancel',                 'screen', ''),

      ('sales_invoice',      'issue',                  'routine', 'erp.issue_sales_invoice(uuid,uuid,uuid)'),
      ('sales_invoice',      'settle',                 'routine', 'erp.settle_paid_document(uuid,text)'),
      ('sales_invoice',      'credit',                 'routine', 'erp.credit_invoices_for_credit_note(uuid)'),
      ('sales_invoice',      'cancel',                 'screen', ''),

      ('sales_credit_note',  'issue',                  'screen', ''),
      ('sales_credit_note',  'cancel',                 'screen', ''),

      -- ── Commercial ────────────────────────────────────────────────────────
      ('commercial_quote',   'submit',                 'screen', ''),
      ('commercial_quote',   'approve',                'screen', ''),
      ('commercial_quote',   'reject',                 'screen', ''),
      ('commercial_quote',   'issue',                  'screen', ''),
      ('commercial_quote',   'accept',                 'screen', ''),
      ('commercial_quote',   'decline',                'screen', ''),
      ('commercial_quote',   'expire',                 'screen', ''),
      ('commercial_quote',   'supersede_draft',        'screen', ''),
      ('commercial_quote',   'supersede_approved',     'screen', ''),
      ('commercial_quote',   'supersede_issued',       'screen', ''),

      -- ── Inventory ─────────────────────────────────────────────────────────
      ('transfer_order',     'approved',               'screen', ''),
      ('transfer_order',     'issued',                 'screen', ''),
      ('transfer_order',     'in_transit',             'screen', ''),
      ('transfer_order',     'received',               'screen', ''),
      ('transfer_order',     'closed',                 'screen', ''),
      ('transfer_order',     'draft_to_discrepancy',   'screen', ''),
      ('transfer_order',     'approved_to_discrepancy','screen', ''),
      ('transfer_order',     'issued_to_discrepancy',  'screen', ''),
      ('transfer_order',     'in_transit_to_discrepancy', 'screen', ''),
      ('transfer_order',     'received_to_discrepancy','screen', ''),
      ('transfer_order',     'discrepancy_to_received','screen', ''),
      ('transfer_order',     'draft_to_cancelled',     'screen', ''),
      ('transfer_order',     'approved_to_cancelled',  'screen', ''),
      ('transfer_order',     'issued_to_cancelled',    'screen', ''),
      ('transfer_order',     'in_transit_to_cancelled','screen', ''),
      ('transfer_order',     'received_to_cancelled',  'screen', ''),

      ('stock_adjustment',   'approve',                'screen', ''),
      ('stock_adjustment',   'post',                   'screen', ''),
      ('stock_adjustment',   'cancel',                 'screen', ''),
      ('stock_adjustment',   'approved_to_cancelled',  'screen', ''),

      -- ── The count sheet (20260927100000) ──────────────────────────────────
      -- Issued by the raise that opens it, once every place is on it; closed
      -- by the last of its counts to be posted or cancelled, derived from
      -- erp.count_sheet_is_finished() whatever permission the organisation
      -- puts on the move. Neither is a button.
      ('count_sheet',        'issue',                  'routine', 'erp.raise_count_tasks(text)'),
      ('count_sheet',        'close',                  'routine', 'erp.close_count_sheet_when_finished(uuid)'),

      -- ── The base content pack's own document lifecycles ───────────────────
      -- Installed by applying the base pack rather than by a module installer
      -- (20260903160000, Starter Content Packs §5.1): the five nothing else
      -- creates, less the transfer order above, which the inventory installer
      -- now ships identically. None of them is left to a door, so the document
      -- page draws every move each one declares.
      ('works_order',          'firmed',                    'screen', ''),
      ('works_order',          'released',                  'screen', ''),
      ('works_order',          'in_progress',               'screen', ''),
      ('works_order',          'completed',                 'screen', ''),
      ('works_order',          'closed',                    'screen', ''),
      ('works_order',          'planned_to_held',           'screen', ''),
      ('works_order',          'firmed_to_held',            'screen', ''),
      ('works_order',          'released_to_held',          'screen', ''),
      ('works_order',          'in_progress_to_held',       'screen', ''),
      ('works_order',          'completed_to_held',         'screen', ''),
      ('works_order',          'held_to_released',          'screen', ''),
      ('works_order',          'planned_to_cancelled',      'screen', ''),
      ('works_order',          'firmed_to_cancelled',       'screen', ''),
      ('works_order',          'released_to_cancelled',     'screen', ''),
      ('works_order',          'in_progress_to_cancelled',  'screen', ''),
      ('works_order',          'completed_to_cancelled',    'screen', ''),
      ('works_order',          'planned_to_scrapped',       'screen', ''),
      ('works_order',          'firmed_to_scrapped',        'screen', ''),
      ('works_order',          'released_to_scrapped',      'screen', ''),
      ('works_order',          'in_progress_to_scrapped',   'screen', ''),
      ('works_order',          'completed_to_scrapped',     'screen', ''),
      ('count',                'in_progress',               'screen', ''),
      ('count',                'counted',                   'screen', ''),
      ('count',                'under_review',              'screen', ''),
      ('count',                'approved',                  'screen', ''),
      ('count',                'posted',                    'screen', ''),
      ('count',                'scheduled_to_recount',      'screen', ''),
      ('count',                'in_progress_to_recount',    'screen', ''),
      ('count',                'counted_to_recount',        'screen', ''),
      ('count',                'under_review_to_recount',   'screen', ''),
      ('count',                'approved_to_recount',       'screen', ''),
      ('count',                'recount_to_in_progress',    'screen', ''),
      ('count',                'scheduled_to_cancelled',    'screen', ''),
      ('count',                'in_progress_to_cancelled',  'screen', ''),
      ('count',                'counted_to_cancelled',      'screen', ''),
      ('count',                'under_review_to_cancelled', 'screen', ''),
      ('count',                'approved_to_cancelled',     'screen', ''),
      ('return',               'authorised',                'screen', ''),
      ('return',               'received',                  'screen', ''),
      ('return',               'inspected',                 'screen', ''),
      ('return',               'dispositioned',             'screen', ''),
      ('return',               'closed',                    'screen', ''),
      ('return',               'requested_to_refused',      'screen', ''),
      ('return',               'authorised_to_refused',     'screen', ''),
      ('return',               'received_to_refused',       'screen', ''),
      ('return',               'inspected_to_refused',      'screen', ''),
      ('return',               'dispositioned_to_refused',  'screen', ''),
      ('supplier_invoice',     'matched',                   'screen', ''),
      ('supplier_invoice',     'approved',                  'screen', ''),
      ('supplier_invoice',     'posted',                    'screen', ''),
      ('supplier_invoice',     'received_to_disputed',      'screen', ''),
      ('supplier_invoice',     'matched_to_disputed',       'screen', ''),
      ('supplier_invoice',     'approved_to_disputed',      'screen', ''),
      ('supplier_invoice',     'disputed_to_matched',       'screen', ''),
      ('supplier_invoice',     'received_to_rejected',      'screen', ''),
      ('supplier_invoice',     'matched_to_rejected',       'screen', ''),
      ('supplier_invoice',     'approved_to_rejected',      'screen', '')
    ) as x(machine_code, transition_code, driver, detail)
$$;

revoke all on function erp.transition_driver_register() from public, anon;

-- The reversal register: a count sheet posts nothing, so nothing is reversed.
-- A route of its own rather than no row, so the refusal a person meets says
-- what to do instead, and a claim the coverage report can hold to account.
do $route$
declare
  v_sig constant text := 'erp.document_reversal_route()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_from constant text := $o$      ('count', 'not_installed',$o$;
  v_to   constant text := $o$    ) as v(base_type_code, route, next_action, rationale)$o$;
  v_new  constant text := $n$      ('count', 'posts_nothing',
       'A count sheet posts nothing, so there is nothing to reverse. Each count on it posts its own variance through erp.post_count(), dated where the movement is; a variance posted in error is put right by counting the place again or by a stock adjustment on its own date.',
       'The sheet lists the places one raise put to be counted (20260927100000). erp_ref.document_type says a count moves no stock and reaches no ledger, and erp.document_reversal_coverage_report() holds the claim: the day a count sheet type names a movement type or a posting rule, this row is reported.')
$n$;
  v_s integer := strpos(v_def, v_from);
  v_e integer := strpos(v_def, v_to);
begin
  if v_s = 0 or v_e = 0 or v_e < v_s
     or strpos(substr(v_def, v_s + length(v_from)), v_from) > 0
     or strpos(substr(v_def, v_s, v_e - v_s), $x$undone where the movement is.')$x$) = 0 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % count row not found as the last row', v_sig;
  end if;
  execute left(v_def, v_s - 1) || v_new || substr(v_def, v_e);
end
$route$;

-- Its coverage report knows the route, and holds it to its claim.
do $coverage$
declare
  v_sig constant text := 'erp.document_reversal_coverage_report()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$   where r.route not in ('reversal', 'credit_note', 'memorandum',
                         'is_itself_a_reversal', 'not_installed')$o$,
    $n$   where r.route not in ('reversal', 'credit_note', 'memorandum',
                         'is_itself_a_reversal', 'not_installed', 'posts_nothing')$n$,
    $o$   where r.route = 'not_installed'
$o$,
    $n$   where r.route = 'not_installed'

  union all
  -- 10. `posts_nothing` claimed for a kind that says it posts, or of which an
  --     organisation holds a type that names a movement type or a posting
  --     rule (20260927100000). The claim is about the base type and about
  --     every organisation's configuration of it.
  select 'a kind is registered as posting nothing and posts',
         coalesce(dt.code, r.base_type_code),
         case when dt.code is null
              then format('erp_ref.document_type %s declares affects_stock %s and affects_finance %s',
                          r.base_type_code, bt.affects_stock, bt.affects_finance)
              else format('erp.document_type %s names movement type %s and posting rule %s',
                          dt.code, coalesce(dt.stock_movement_type, 'none'),
                          coalesce(dt.posting_rule_code, 'none')) end
    from erp.document_reversal_route() r
    join erp_ref.document_type bt on bt.code = r.base_type_code
    left join erp.document_type dt
      on dt.base_type_code = r.base_type_code and dt.status = 'active'
     and (dt.stock_movement_type is not null or dt.posting_rule_code is not null)
   where r.route = 'posts_nothing'
     and (bt.affects_stock or bt.affects_finance or dt.id is not null)
$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$coverage$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A11. The suites that pinned what this moves
-- ─────────────────────────────────────────────────────────────────────────────

-- The count task lifecycle suite reads the installer's version.
do $lifecycle_suite$
declare
  v_sig constant text := 'erp_test.count_lifecycle_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$          where mi.install_code = 'inventory-operations') = 6,
    'the upgrade item is the helper''s payload, as version 6';$o$,
    $n$          -- 7 since 20260927100000, when the count sheet joined it; the
          -- lifecycle is still version 6's item.
          where mi.install_code = 'inventory-operations') = 7
    and exists (select 1 from erp_ref.module_upgrade_item ui
                 where ui.install_code = 'inventory-operations' and ui.to_version = 6
                   and ui.object_key = 'count_task_lifecycle'),
    'the upgrade item is the helper''s payload, as version 6';$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$lifecycle_suite$;

-- An organisation put back and upgraded arrives at inventory-operations 7.
do $adjust_suite$
declare
  v_sig constant text := 'erp_test.stock_adjustment_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$              -- 6 since 20260927000000: the count task's lifecycle joined the installer.
              where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') = 6;$o$;
  v_new constant text := $n$              -- 6 since 20260927000000: the count task's lifecycle joined the installer;
              -- 7 since 20260927100000, the count sheet.
              where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') = 7;$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % version anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$adjust_suite$;

do $transfer_suite$
declare
  v_sig constant text := 'erp_test.site_transfer_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$        -- And 6 since 20260927000000, when the count task's lifecycle joined it.
        and (select i.installer_version from erp.module_installation i
              where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') = 6;$o$,
    $n$        -- And 6 since 20260927000000, when the count task's lifecycle joined it;
        -- 7 since 20260927100000, the count sheet.
        and (select i.installer_version from erp.module_installation i
              where i.tenant_id = v_tenant and i.install_code = 'inventory-operations') = 7;$n$,
    $o$organisation now at version %s (6 rather than 4 since the stock adjustment and the count task''s lifecycle joined the same installer)$o$,
    $n$organisation now at version %s (7 rather than 4 since the stock adjustment, the count task''s lifecycle and the count sheet joined the same installer)$n$];
  v_hits integer;
begin
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$transfer_suite$;
-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The proof: erp_test.count_sheet_suite
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.count_sheet_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  v_hex    text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1       uuid := gen_random_uuid();
  a2       uuid := gen_random_uuid();
  r        record;
  res      jsonb;
  v_lines  jsonb;
  v_tok    text;
  v_second uuid;
  csf uuid; csp uuid; csi uuid;
  v_uom uuid; v_site uuid; v_site2 uuid; v_recv uuid; v_recv2 uuid; v_sup uuid; v_grn uuid; v_grn2 uuid;
  i_a uuid; i_b uuid; i_c uuid; i_d uuid; i_e uuid;
  t_a uuid; t_b uuid; t_c uuid; t_d uuid; t_e uuid;
  v_sheet uuid; v_sheet2 uuid;
  v_n integer; v_n2 integer; v_n3 integer;
  v_status text; v_err text; v_err2 text; v_err3 text; v_err4 text; v_l uuid; v_hint text; v_fact text; v_num text;
  v_planned text;
  v_fixture text;
begin
  -- 1. The helper is what both routes ship.
  return query select 'a new organisation and an upgraded one are given the same count sheet',
    (select count(*) from erp_ref.module_upgrade_item ui
       join jsonb_array_elements(erp.count_sheet_pack_items()) i
         on i.value ->> 'kind' = ui.object_kind and i.value ->> 'key' = ui.object_key
        and i.value -> 'payload' = ui.payload
      where ui.install_code = 'inventory-operations' and ui.to_version = 7) = 4
    and (select mi.current_version from erp_ref.module_installer mi
          where mi.install_code = 'inventory-operations') = 7
    and strpos(pg_get_functiondef('erp.configure_inventory(erp.costing_method,text,numeric,numeric)'::regprocedure),
               'erp.count_sheet_pack_items()') > 0,
    (select string_agg(ui.object_kind || ' ' || ui.object_key, ', ' order by ui.seq)
       from erp_ref.module_upgrade_item ui
      where ui.install_code = 'inventory-operations' and ui.to_version = 7);

  -- 2. The base type posts nothing, and the reversal register says so.
  return query select 'a count posts nothing, and its reversal route says there is nothing to reverse',
    (select not bt.affects_stock and not bt.affects_finance
       from erp_ref.document_type bt where bt.code = 'count')
    and (select r2.route from erp.document_reversal_route() r2 where r2.base_type_code = 'count') = 'posts_nothing'
    and not exists (select 1 from erp.document_reversal_coverage_report()),
    coalesce((select string_agg(c.finding || ' [' || c.reference || ']', '; ')
                from erp.document_reversal_coverage_report() c), 'no finding');

  begin
    v_fixture := 'provisioning';
    select * into r from erp.provision_tenant(
      'zz-csh-' || v_hex, 'Count sheet suite',
      'a@zz-csh-' || v_hex || '.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    res := public.erp_invite_principal('second@zz-csh-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');

    v_fixture := 'installing';
    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    csi := erp.configure_inventory('average');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;

    -- 3. Installing inventory installs the sheet.
    return query select 'installing inventory installs the count sheet: its type, sequence, lifecycle and layout',
      exists (select 1 from erp.document_type dt
                join erp.numbering_rule nr on nr.id = dt.numbering_rule_id and nr.prefix = 'CNT-'
               where dt.tenant_id = r.tenant_id and dt.code = 'count_sheet' and dt.status = 'active'
                 and dt.base_type_code = 'count' and dt.state_machine_code = 'count_sheet'
                 and dt.create_permission = 'inventory.count'
                 and dt.stock_movement_type is null and dt.posting_rule_code is null)
      and exists (select 1 from erp.state_machine sm
                   join erp.state_machine_version v
                     on v.tenant_id = sm.tenant_id and v.state_machine_id = sm.id and v.status = 'active'
                  where sm.tenant_id = r.tenant_id and sm.code = 'count_sheet'
                    and sm.object_type = 'document' and sm.status = 'active')
      and exists (select 1 from erp.output_template ot
                   where ot.tenant_id = r.tenant_id and ot.code = 'count_sheet'
                     and ot.base_type_code = 'count' and ot.status = 'active'),
      (select string_agg(format('%s on %s, %s', dt.code, dt.base_type_code, dt.state_machine_code), '; ')
         from erp.document_type dt where dt.tenant_id = r.tenant_id and dt.base_type_code = 'count');

    v_fixture := 'the stock';
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'MAIN', 'Main', 'warehouse', 'active') returning id into v_site;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status)
    values (r.tenant_id, r.entity_id, 'NORTH', 'North', 'warehouse', 'active') returning id into v_site2;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site, 'RECV', 'Goods in', 'receiving', 'active') returning id into v_recv;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status)
    values (r.tenant_id, v_site2, 'RECV-N', 'Goods in, north', 'receiving', 'active') returning id into v_recv2;
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'A', 'Counted and posted', v_uom, 'active') returning id into i_a;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'B', 'Counted and posted second', v_uom, 'active') returning id into i_b;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'C', 'Cancelled, the last on its sheet', v_uom, 'active') returning id into i_c;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'D', 'On the other site''s sheet', v_uom, 'active') returning id into i_d;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'E', 'Raised before the sheet', v_uom, 'active') returning id into i_e;

    v_grn := erp.open_document('goods_receipt', v_sup, null, v_site);
    perform erp.add_document_line(v_grn, i_a, 100, 100, 'A');
    perform erp.add_document_line(v_grn, i_b, 100, 100, 'B');
    perform erp.add_document_line(v_grn, i_c, 100, 100, 'C');
    perform erp.add_document_line(v_grn, i_e, 100, 100, 'E');
    perform erp.transition_document(v_grn, 'post');
    v_grn2 := erp.open_document('goods_receipt', v_sup, null, v_site2);
    perform erp.add_document_line(v_grn2, i_d, 100, 100, 'D');
    perform erp.transition_document(v_grn2, 'post');

    -- Every count within tolerance and nobody to approve it: recorded is
    -- approved, and posted by the same person, as an organisation not yet
    -- live may.
    insert into erp.count_programme (tenant_id, code, name, kind, selector,
                                     tolerance_absolute, tolerance_pct, approval_chain_code, status)
    values (r.tenant_id, 'zz_before', 'Raised on version 6', 'cycle',
            '{"==": [{"var": "item_code"}, "E"]}'::jsonb, 1000, 0, null, 'active'),
           (r.tenant_id, 'zz_sheet', 'Raised with a sheet', 'cycle',
            '{"or": [{"==": [{"var": "item_code"}, "A"]}, {"==": [{"var": "item_code"}, "B"]},
                     {"==": [{"var": "item_code"}, "C"]}, {"==": [{"var": "item_code"}, "D"]}]}'::jsonb,
            1000, 0, null, 'active');

    -- 4. An organisation on version 6 has no count sheet: put back as one.
    v_fixture := 'putting the organisation back to version 6';
    update erp.document_type set status = 'inactive'
     where tenant_id = r.tenant_id and code = 'count_sheet';
    update erp.output_template set status = 'inactive'
     where tenant_id = r.tenant_id and code = 'count_sheet';
    update erp.state_machine set status = 'inactive'
     where tenant_id = r.tenant_id and code = 'count_sheet';
    update erp.module_installation i set installer_version = 6
     where i.tenant_id = r.tenant_id and i.install_code = 'inventory-operations';

    v_fixture := 'raising on version 6';
    v_n := erp.raise_count_tasks('zz_before');
    select t.id into t_e from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_e;
    select count(*) into v_n2 from erp.document d
      join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = r.tenant_id and dt.base_type_code = 'count';
    return query select 'an organisation on version 6 raises its counts with no sheet, as it did',
      v_n = 1 and t_e is not null and v_n2 = 0
      and (select t.document_id is null and t.document_line_id is null
             from erp.count_task t where t.id = t_e)
      and erp.object_current_state('count_task', t_e) = 'open',
      format('%s task(s) raised, %s sheet(s)', v_n, v_n2);

    -- 5. The upgrade to version 7 installs the sheet.
    v_fixture := 'upgrading to version 7';
    select string_agg(p.object_kind || ' ' || p.object_key, ', ' order by p.seq)
      into v_planned
      from erp.plan_module_upgrade('inventory-operations') p;
    res := erp.upgrade_module_configuration('inventory-operations');
    return query select 'the upgrade to version 7 installs the count sheet',
      strpos(coalesce(v_planned, ''), 'document_type count_sheet') > 0
      and strpos(coalesce(v_planned, ''), 'output_template count_sheet') > 0
      and (res ->> 'to_version')::integer = 7 and (res ->> 'promoted')::boolean
      and (select i.installer_version from erp.module_installation i
            where i.tenant_id = r.tenant_id and i.install_code = 'inventory-operations') = 7
      and exists (select 1 from erp.document_type dt
                   where dt.tenant_id = r.tenant_id and dt.code = 'count_sheet' and dt.status = 'active')
      and exists (select 1 from erp.output_template ot
                   where ot.tenant_id = r.tenant_id and ot.code = 'count_sheet' and ot.status = 'active')
      and not exists (select 1 from erp.plan_module_upgrade('inventory-operations')),
      format('planned %s; %s', coalesce(v_planned, 'nothing'), res::text);

    -- 6. A task raised before the sheet still moves, and closes nothing.
    v_fixture := 'posting E';
    v_status := erp.record_count(t_e, 100)::text;
    perform erp.post_count(t_e);
    return query select 'a task raised with no sheet is still counted and posted after the upgrade',
      v_status = 'approved'
      and (select t.status::text from erp.count_task t where t.id = t_e) = 'posted'
      and (select t.document_id from erp.count_task t where t.id = t_e) is null,
      (select t.status::text from erp.count_task t where t.id = t_e);

    -- 7. Raising opens one numbered, issued sheet per site, and each task is
    --    a line of it.
    v_fixture := 'raising with a sheet';
    v_n := erp.raise_count_tasks('zz_sheet');
    select t.id into t_a from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_a;
    select t.id into t_b from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_b;
    select t.id into t_c from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_c;
    select t.id into t_d from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_d;
    select t.document_id into v_sheet from erp.count_task t where t.id = t_a;
    select t.document_id into v_sheet2 from erp.count_task t where t.id = t_d;
    select d.document_number into v_num from erp.document d where d.id = v_sheet;
    select count(*) into v_n2 from erp.document d
      join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = r.tenant_id and dt.base_type_code = 'count';
    -- Each task is its line: the same item, place and expectation, and no
    -- line without a task.
    select count(*) into v_n3
      from erp.count_task t
      join erp.document_line l
        on l.tenant_id = t.tenant_id and l.id = t.document_line_id and l.document_id = t.document_id
     where t.tenant_id = r.tenant_id and t.count_programme_id =
           (select p.id from erp.count_programme p where p.tenant_id = r.tenant_id and p.code = 'zz_sheet')
       and l.item_id = t.item_id and l.location_id is not distinct from t.location_id
       and l.quantity = t.expected_quantity;
    return query select 'raising a programme opens one numbered count sheet per site, issued, and each task is its line',
      v_n = 4 and v_n2 = 2 and v_sheet is not null and v_sheet2 is not null and v_sheet <> v_sheet2
      and v_num like 'CNT-%'
      and (select count(distinct t.document_id) from erp.count_task t
            where t.id in (t_a, t_b, t_c)) = 1
      and v_n3 = 4
      and (select count(*) from erp.document_line l
            where l.tenant_id = r.tenant_id and l.document_id in (v_sheet, v_sheet2)) = 4
      and erp.object_current_state('document', v_sheet) = 'issued'
      and erp.object_current_state('document', v_sheet2) = 'issued'
      and (select d.site_id = v_site and d.our_reference = 'zz_sheet'
             from erp.document d where d.id = v_sheet)
      and (select string_agg(l.transition_code, ',' order by l.occurred_at, l.id)
             from erp.state_transition_log l
            where l.tenant_id = r.tenant_id and l.object_type = 'document' and l.object_id = v_sheet
              and l.transition_code is not null) = 'issue',
      format('%s task(s), %s sheet(s), %s is %s, %s task(s) matching their line',
             v_n, v_n2, coalesce(v_num, 'no sheet'),
             coalesce(erp.object_current_state('document', v_sheet), 'in no state'), v_n3);

    -- 8. A raise that finds nothing new opens no empty sheet.
    v_n := erp.raise_count_tasks('zz_sheet');
    select count(*) into v_n2 from erp.document d
      join erp.document_type dt on dt.id = d.document_type_id
     where d.tenant_id = r.tenant_id and dt.base_type_code = 'count';
    return query select 'raising again over places already in flight opens no empty sheet',
      v_n = 0 and v_n2 = 2, format('%s task(s), %s sheet(s)', v_n, v_n2);

    -- 9. The sheet renders for printing, through the door whoever counts may
    --    use, and through the renderer the configuration preview uses.
    v_fixture := 'rendering the sheet';
    res := public.erp_render_count_sheet(v_sheet, 'en');
    select b into v_lines from jsonb_array_elements(res -> 'blocks') b where b ->> 'kind' = 'lines';
    return query select 'the count sheet renders every place with its expectation and a blank to write the count',
      res ->> 'template' = 'count_sheet' and res ->> 'kind' = 'document'
      and (res ->> 'document_id')::uuid = v_sheet
      and jsonb_array_length(v_lines -> 'rows') = 3
      and exists (select 1 from jsonb_array_elements(v_lines -> 'columns') c
                   where c ->> 'field' = 'counted_quantity' and c ->> 'label' = 'Counted')
      and exists (select 1 from jsonb_array_elements(v_lines -> 'columns') c
                   where c ->> 'field' = 'expected_quantity' and c ->> 'label' = 'Expected')
      and not exists (select 1 from jsonb_array_elements(v_lines -> 'rows') x
                       where x ? 'counted_quantity')
      and not exists (select 1 from jsonb_array_elements(v_lines -> 'rows') x
                       where (x ->> 'expected_quantity')::numeric is distinct from 100
                          or x ->> 'location' is distinct from 'RECV')
      and exists (select 1 from jsonb_array_elements(res -> 'blocks') b
                   cross join lateral jsonb_array_elements(b -> 'fields') f
                  where b ->> 'kind' = 'title' and f ->> 'value' = v_num)
      and erp.render_output_template('count_sheet', v_sheet, 'en') -> 'blocks' = res -> 'blocks',
      left(coalesce(v_lines::text, res::text), 300);

    -- 10. Nothing but a count sheet prints as one, and nobody adds a line
    --     to one by hand.
    begin
      perform public.erp_render_count_sheet(v_grn, 'en');
      v_err := 'rendered';
    exception when others then v_err := left(sqlerrm, 160); end;
    begin
      perform erp.add_document_line(v_sheet, i_e, 5, 0, 'by hand');
      v_err2 := 'added';
    exception when others then v_err2 := left(sqlerrm, 160); end;
    return query select 'a goods receipt does not print as a count sheet, and a sheet takes no line by hand',
      v_err like 'CLOVEERP_NOT_A_COUNT_SHEET:%'
      and v_err2 like 'CLOVEERP_COUNT_SHEET_LINES_ARE_ITS_COUNTS:%',
      v_err || ' / ' || v_err2;

    -- 10b. No other door changes an issued sheet's line, reserves stock on
    --      it, or opens a sheet by hand (found on review).
    select t.document_line_id into v_l from erp.count_task t
     where t.tenant_id = erp.current_tenant_id() and t.document_id = v_sheet
     order by t.created_at, t.id limit 1;
    begin
      perform public.erp_amend_document_line(v_l, 7, 'by hand');
      v_err := 'amended';
    exception when others then v_err := left(sqlerrm, 160); end;
    begin
      perform public.erp_set_line_stock_identity(v_l, null,
        (select lo.id from erp.location lo
          where lo.tenant_id = erp.current_tenant_id() and lo.site_id = v_site
            and lo.id is distinct from (select l.location_id from erp.document_line l where l.id = v_l)
          order by lo.code limit 1),
        null);
      v_err2 := 'moved';
    exception when others then v_err2 := left(sqlerrm, 160); end;
    begin
      perform public.erp_reserve_for_line(v_l, null);
      v_err3 := 'reserved';
    exception when others then v_err3 := left(sqlerrm, 160); end;
    begin
      perform public.erp_create_document('count_sheet', null, v_site, null, null,
        (select s.entity_id from erp.site s where s.id = v_site), null, null);
      v_err4 := 'opened';
    exception when others then v_err4 := left(sqlerrm, 160); end;
    return query select 'an issued count sheet''s line is not amended, moved or reserved, and no sheet is opened by hand',
      v_err like 'CLOVEERP_COUNT_SHEET_LINES_ARE_ITS_COUNTS:%'
      and v_err2 like 'CLOVEERP_COUNT_SHEET_LINES_ARE_ITS_COUNTS:%'
      and v_err3 like 'CLOVEERP_COUNT_SHEET_LINES_ARE_ITS_COUNTS:%'
      and v_err4 like 'CLOVEERP_COUNT_SHEET_IS_RAISED:%'
      and (select l.quantity from erp.document_line l where l.id = v_l) = 100,
      v_err || ' / ' || v_err2 || ' / ' || v_err3 || ' / ' || v_err4;

    -- 11. The sheet closes when its last task is posted or cancelled, and
    --     not before, by hand or otherwise.
    v_fixture := 'finishing the sheet';
    perform erp.record_count(t_a, 100);
    perform erp.post_count(t_a);
    perform erp.record_count(t_b, 99);
    perform erp.post_count(t_b);
    v_status := erp.object_current_state('document', v_sheet);
    begin
      perform erp.transition_document(v_sheet, 'close');
      v_err := 'closed';
    exception when others then v_err := left(sqlerrm, 160); end;
    perform public.erp_cancel_count_task(t_c, 'The bay was emptied for a refit');
    select l.guard_data #>> '{derived,fact}' into v_fact
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'document' and l.object_id = v_sheet
       and l.transition_code = 'close';
    return query select 'a count sheet closes itself when its last count is posted or cancelled, and not before',
      v_status = 'issued'
      and v_err like 'CLOVEERP_COUNT_SHEET_NOT_FINISHED:%'
      and erp.object_current_state('document', v_sheet) = 'closed'
      and v_fact = 'erp.count_sheet_is_finished'
      and erp.object_current_state('document', v_sheet2) = 'issued',
      format('after two posted %s; close by hand: %s; after the cancel %s, derived from %s; the other site''s %s',
             v_status, v_err, erp.object_current_state('document', v_sheet),
             coalesce(v_fact, 'nothing'), erp.object_current_state('document', v_sheet2));

    perform erp.record_count(t_d, 100);
    perform erp.post_count(t_d);
    return query select 'the other site''s sheet closes with its own last count',
      erp.object_current_state('document', v_sheet2) = 'closed',
      coalesce(erp.object_current_state('document', v_sheet2), 'in no state');

    -- 12. Reversing a count sheet says there is nothing to reverse.
    begin
      perform erp.reverse_document_posting(v_sheet, 'Counted the wrong bay');
      v_err := 'reversed';
    exception when others then
      get stacked diagnostics v_hint = pg_exception_hint;
      v_err := left(sqlerrm, 160);
    end;
    return query select 'a count sheet is not reversed, and the refusal says why',
      v_err like 'CLOVEERP_DOCUMENT_NOT_REVERSIBLE:%'
      and v_hint like 'A count sheet posts nothing%',
      v_err || ' / ' || coalesce(v_hint, 'no hint');

    -- 13. The reversal register holds the claim: a count sheet type that
    --     posted would be reported.
    update erp.document_type set posting_rule_code = 'stock_adjustment'
     where tenant_id = r.tenant_id and code = 'count_sheet';
    select count(*) into v_n from erp.document_reversal_coverage_report() c
     where c.finding = 'a kind is registered as posting nothing and posts' and c.reference = 'count_sheet';
    update erp.document_type set posting_rule_code = null
     where tenant_id = r.tenant_id and code = 'count_sheet';
    return query select 'a count sheet type that named a posting rule would be reported by the reversal register',
      v_n = 1 and not exists (select 1 from erp.document_reversal_coverage_report()),
      format('%s finding(s) while it named one', v_n);

    -- 14. The configuration checks, with a count sheet installed.
    select count(*) into v_n from erp.dead_configuration_report() c
     where c.reference like '%count\_sheet%' or c.reference = 'count'
        or c.detail like '%count\_sheet%';
    select count(*) into v_n2 from erp.undriven_transition_report() c
     where c.reference like 'count\_sheet%';
    select count(*) into v_n3 from erp.reachable_configuration_report() c
     where c.reference like 'count\_sheet%';
    begin
      v_err := erp.assert_every_transition_is_driven();
      v_err := erp_test.assert_reachable_configuration();
      v_err := erp_test.assert_no_state_side_doors();
      v_err := erp.assert_every_posting_can_be_undone();
      v_err := erp.assert_no_dead_configuration();
      v_err := 'passed';
    exception when others then v_err := 'refused: ' || left(sqlerrm, 200); end;
    return query select 'dead configuration, the driver register, reachability (X2), side doors (X3) and reversal all pass with a count sheet installed',
      v_n = 0 and v_n2 = 0 and v_n3 = 0 and v_err = 'passed',
      format('%s dead, %s undriven, %s unreachable; %s', v_n, v_n2, v_n3, v_err);

    raise exception 'CLOVEERP_SUITE_UNDO';
  exception when others then
    if sqlerrm <> 'CLOVEERP_SUITE_UNDO' then
      case_name := 'the suite ran to its end';
      passed := false; detail := left(v_fixture || ': ' || sqlerrm, 300);
      return next;
    end if;
  end;

  perform set_config('request.jwt.claims', '', true);
  case_name := 'the suite leaves nothing behind';
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-csh-' || v_hex);
  detail := 'the organisation, its counts and their sheets rolled back';
  return next;
end;
$function$;

revoke all on function erp_test.count_sheet_suite() from public, anon;

create or replace function erp_test.assert_count_sheet_suite()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false))
    into v_failed, v_total, v_detail
    from erp_test.count_sheet_suite() s;
  -- Failures first, so a suite that stopped part way says where.
  if v_failed > 0 then
    raise exception 'CLOVEERP_COUNT_SHEET_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A count with no sheet has no number, no document authorisation and nothing to print. Read the case that failed.';
  end if;
  if v_total <> 17 then
    raise exception 'CLOVEERP_COUNT_SHEET_SUITE_SHRANK: % case(s), expected 17', v_total
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_count_sheet_suite() from public, anon;

comment on function erp_test.assert_count_sheet_suite() is
  'A raise opens one numbered count sheet per site and each task is its line; the sheet renders for '
  'printing, closes with its last count, posts nothing and reverses nothing; an organisation on '
  'version 6 raises with no sheet and takes one from the upgrade (20260927100000).';

-- The generators, which are idempotent and run at the end of every migration.

select erp.apply_row_security();
select erp.apply_platform_internal_security();
select erp.apply_append_only_guards();
select erp.apply_attribution_triggers();
select erp.apply_audit_coverage();
select erp.apply_live_config_guards();
select erp.apply_execute_grants();

select erp.assert_isolation();
select erp.assert_public_api_safe();
select erp.assert_no_public_execute();
select erp.assert_no_legacy_refusal_prefix();
select erp.assert_refusals_name_next_action();
select erp.assert_diagnostics_registered();
select erp.assert_ci_coverage();
select erp.assert_suite_verdicts_strict();
select erp.assert_enforcement_gates_are_read();
select erp.assert_resource_coverage('en');
select erp.assert_resource_coverage_de();
-- Every move every lifecycle declares still has something that fires it, in
-- whatever database this runs against, before it commits.
select erp.assert_every_transition_is_driven();
