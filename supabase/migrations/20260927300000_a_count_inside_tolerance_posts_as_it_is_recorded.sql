set lock_timeout = '30s';

-- =============================================================================
-- 20260927300000  A count inside tolerance posts as it is recorded
-- -----------------------------------------------------------------------------
-- PR10, M2b: node I3 of docs/spec/simplification-review.md, "auto-post counts
-- inside tolerance", on top of M2a (20260927200000), which gave a count's
-- variance a stock adjustment of its own.
--
-- ── WHAT WAS WRONG ───────────────────────────────────────────────────────────
--
-- A count inside its programme's tolerance approved itself and then waited:
-- somebody who may adjust stock had to press Post, one count at a time, and
-- nothing scheduled it. In a live organisation it cost more than a press. It
-- cost a second person, because CLOVEERP_COUNT_SELF_POSTING (20260914070000)
-- refused the counter's own post of a variance the organisation's own
-- tolerance had already called immaterial. And the variance was dated the day
-- Post was pressed, not the day the count was taken.
--
-- ── WHAT THIS CHANGES ────────────────────────────────────────────────────────
--
--   * erp.record_count() posts a count inside its tolerance as it records it,
--     in the same step, through erp.post_count(): a variance through its
--     stock adjustment, dated the day it was counted; no variance with no
--     adjustment; an organisation with no stock adjustment type by the
--     movement it always wrote. It returns posted.
--   * The post is the system's move, not the counter's. It is derived from
--     erp.count_is_within_tolerance() (decision 6, 20260922380000), which
--     erp.derived_move_fact() reads again with the task locked: approved
--     because inside tolerance, with no approval request, recorded in this
--     transaction, and the site's policy says post. The counter holds
--     inventory.count and not inventory.adjust, so under the fact
--     erp.post_count() asks nothing of the person and erp.raise_count_
--     adjustment() opens the adjustment with erp.create_document(), as
--     erp.firm_planned_order() does; the adjustment's own approve and post
--     were already derived (20260927200000).
--   * CLOVEERP_COUNT_SELF_POSTING gives way inside tolerance: the counter's
--     own count posts itself, live or not. Its refusal text says so.
--   * A per-site policy, inventory.count_posting, declared and resolved as
--     production.policy (20260924500000) and procurement.policy
--     (20260923100000) are, and proposed as a change from the Stock audit
--     screen with erp_propose_count_posting_policy, as the production
--     policy is from the Manufacturing screen:
--       within_tolerance            post (default) or hold. Hold leaves every
--                                   count inside tolerance approved for
--                                   somebody to post, exactly as before.
--       self_post_within_tolerance  true (default), or false: once live, the
--                                   counter's own count with a variance
--                                   waits for somebody else, as the
--                                   self-posting rule would have had it.
--   * Unattended posting is bounded across counts, not only per count
--     (found on review: a counter who may only count could raise a place
--     again after it posted and record it short again, and write stock off
--     one tolerance at a time). Once live, the variance the system has
--     posted at the same place — item, location, batch, owner, handling unit
--     — since the later of the last post there by a person and thirty days
--     back, with this count's added, must be inside the programme's
--     tolerance by the same rule, against what this count expected. A count
--     programme carries no cycle or frequency, so the window is the thirty
--     days. Past it the count is held for a second person, not refused.
--     count_task.posted_by_system says which posts were the system's, and
--     posted_at is now the moment of the post, so a person's post orders
--     against the system's inside one transaction as well as across two.
--   * A count held for any reason carries it: count_task.post_held_reason.
--   * A negative count is refused (CLOVEERP_COUNT_QUANTITY_NEGATIVE); it
--     would post a loss of more than was there (found on review).
--   * A refused post keeps the count. Only a conflict that clears by itself
--     (40001, 40P01, 55P03) refuses the record, by
--     CLOVEERP_COUNT_AUTOPOST_FAILED with the conflict's own SQLSTATE, and in
--     DETAIL, so it is tried again and a scanner's queued count is applied
--     on the next drain. Any other refusal — no place, no ledger, a closed
--     period, a lifecycle changed — leaves the count recorded and approved,
--     held for somebody to post, with the refusal's SQLSTATE and message in
--     post_held_reason, and record_count returns approved. This reverses the
--     first draft, which refused the record for every failure: that choice
--     was the coordinator's, not the user's, and on a device it lost the
--     count for good, because the drain marks a refused action conflicted.
--   * The policy fails closed: only the JSON string "post" posts, and only
--     JSON true (or nothing said, when the default true applies) lets the
--     counter's own post. The proposal door refuses a company that is not
--     the site's (CLOVEERP_POLICY_SCOPE_DISAGREES).
--   * The tolerance is in units, or a share of the units expected, with no
--     threshold by value; the decision and the screen say so.
--   * The decision is recorded in erp_meta.policy_decision
--     (count_posts_within_tolerance).
--   * The suites that walked a count inside tolerance to Post are re-pinned;
--     those about the post itself hold by policy in their fixture.
--     erp_test.count_autopost_suite is the proof.
--
-- ── WHAT IS NOT HERE, AND WHY ────────────────────────────────────────────────
--
--   * Outside tolerance nothing changes. The count waits for its approver,
--     the counter may still approve their own (20260914070000), and the post
--     is by hand, where CLOVEERP_COUNT_SELF_POSTING still stands. Posting on
--     approval, with the approver as the second person, is M2c.
--   * A count held by the policy, or approved by its chain, is posted by
--     hand and dated the day it is posted, as before (design D4).
--   * The fact holds only in the transaction that recorded the count, so a
--     count held yesterday is not posted by the system today because the
--     policy has changed since. Held counts wait for Post; nothing sweeps them.
--   * No configuration ships through an installer or an upgrade: the policy
--     is reference data with a default, and an organisation needs no row for
--     it. inventory-operations stays at version 7.
--   * erp.transition_driver_register() is not restated. The count task
--     lifecycle is not in it (20260927000000), and the stock adjustment's
--     rows are unchanged: its approve and post are still made by
--     erp.post_count() through erp.raise_count_adjustment().
--     erp.lifecycle_column_writer_register() is unchanged:
--     erp.move_count_task() is still the only writer.
--   * erp.jsonb_matches_schema() does not enforce an enum or a property's
--     type, so the proposal door checks each key itself, and the fact reads
--     the value as JSON and holds on anything it does not recognise.
--   * Each variance the system posts takes an ADJ number inside the counter's
--     transaction. The stock adjustment type's numbering rule is not
--     gapless, so erp.next_document_number() locks its row until the record
--     commits: counters recording variances at once queue on it, one record
--     at a time. Not changed here; a gapless rule would take a provisional
--     number instead.
--   * The Stock audit screen's copy and its proposal form are in the client,
--     in the same pull request; the words are seeded here.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A1. The refusals this adds, and the one it narrows
-- ─────────────────────────────────────────────────────────────────────────────

select erp.register_refusal('CLOVEERP_COUNT_AUTOPOST_FAILED',
  'Recording a count inside its tolerance while another transaction held what its post needed.',
  'A count inside its tolerance posts as it is recorded. When the post meets a conflict that clears by itself — a serialisation failure, a deadlock, a lock not granted in time — the count is not recorded, so that it is recorded again rather than left half done. Any other refusal of the post keeps the count, approved, for somebody to post, with the refusal on the task.',
  'Record the count again. The conflict is another transaction''s and passes; a scanner''s queued count is applied again on the next drain.');

select erp.register_refusal('CLOVEERP_COUNT_QUANTITY_NEGATIVE',
  'Recording a count of less than nothing.',
  'A count is what was found in the place, and nothing found is nought. A negative figure would be posted as a loss of more than was there and take the stock below zero.',
  'Count the place again and record what is there: nought or more.');

select erp.register_refusal('CLOVEERP_POLICY_SCOPE_DISAGREES',
  'Proposing a policy for a site under a company the site does not belong to.',
  'A site''s policy belongs to the site''s own company. Naming another company as well leaves it unclear which of the two was meant, and the proposal would be stored under the one that was not written.',
  'Name the site alone, or the site with its own company.');

-- Narrowed, not removed: outside tolerance, and inside it where the site's
-- policy holds the counter's own, the rule stands as it was.
select erp.register_refusal('CLOVEERP_COUNT_SELF_POSTING',
  'Posting the variance of a count you recorded yourself, once the organisation is live.',
  'A count is one person''s word, and correcting the stock by it is somebody else''s. A count inside its tolerance is not posted by the counter but by the system as it is recorded, because the tolerance is the organisation''s own decision about what is immaterial; the site''s count posting policy can withdraw that and hold such counts for a second person as well.',
  'Ask somebody else who may adjust stock to post the count. Nobody writes their own count into the stock once the organisation is live.');

-- ─────────────────────────────────────────────────────────────────────────────
-- A1b. A count says whether the system posted it, and why it did not
-- ─────────────────────────────────────────────────────────────────────────────

alter table erp.count_task
  add column posted_by_system boolean not null default false,
  add column post_held_reason text;

comment on column erp.count_task.posted_by_system is
  'True when the count was posted by the system as it was recorded, inside its tolerance '
  '(20260927300000); false for a count posted by a person, and for every count posted before. '
  'A person''s post at a place starts afresh the variance the system may post there unattended.';
comment on column erp.count_task.post_held_reason is
  'Why a count inside its tolerance was not posted as it was recorded and waits for somebody to post '
  'it (20260927300000): the site''s policy, the counter''s own, the variance posted unattended at the '
  'place adding up past the tolerance, or the post refused, with its SQLSTATE and message. Null when '
  'it posted, or was never inside tolerance.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A2. The policy
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.config_type
  (code, domain, module_code, name_key, description, value_schema,
   max_scope_level, is_singleton, default_value, consequence) values
  ('inventory.count_posting', 'policy', 'inventory',
   'config.inventory.count_posting',
   'Whether a count inside its programme''s tolerance posts itself as it is '
   'recorded or waits for somebody to post it, and whether, once the '
   'organisation is live, the counter''s own count inside tolerance posts itself.',
   jsonb_build_object('type','object','additionalProperties',false,
     'properties', jsonb_build_object(
       'within_tolerance', jsonb_build_object('type','string','enum',
         jsonb_build_array('post','hold')),
       'self_post_within_tolerance', jsonb_build_object('type','boolean'))),
   'site', true,
   jsonb_build_object('within_tolerance', 'post', 'self_post_within_tolerance', true),
   'hold leaves every count inside tolerance approved and unposted until somebody '
   'who may adjust stock posts it, and nothing schedules that; '
   'self_post_within_tolerance false does the same for a counter''s own count once '
   'the organisation is live, so a counter who counts alone leaves every one of '
   'them waiting for a second person.')
on conflict (code) do nothing;

do $policy_type$
begin
  if (select ct.default_value from erp_ref.config_type ct where ct.code = 'inventory.count_posting')
     is distinct from '{"within_tolerance": "post", "self_post_within_tolerance": true}'::jsonb then
    raise exception 'CLOVEERP_ANCHOR_MOVED: inventory.count_posting is declared already, and not as 20260927300000 declares it';
  end if;
end
$policy_type$;

insert into erp_ref.resource (key, locale, value, description) values
  ('config.inventory.count_posting', 'en', 'Count posting policy',
   'The name of the inventory.count_posting configuration type.'),
  ('config.inventory.count_posting', 'de', 'Richtlinie zum Buchen von Zählungen',
   'Der Name des Konfigurationstyps inventory.count_posting.')
on conflict (key, locale) do nothing;

create or replace function erp.count_posting_policy(p_entity_id uuid default null,
                                                    p_site_id uuid default null)
returns jsonb
language sql
stable
set search_path = ''
as $$
  -- The count posting policy in force at an entity and site (20260927300000),
  -- layered key by key as the production and procurement policies are: the
  -- product's defaults, then what the organisation set, then its entity,
  -- then its site. A key a narrower value leaves out reads as the broader
  -- one's.
  select coalesce(ct.default_value, '{}'::jsonb)
      || coalesce(erp.config_value('inventory.count_posting', null, null, null, null), '{}'::jsonb)
      || case when p_entity_id is null then '{}'::jsonb
              else coalesce(erp.config_value('inventory.count_posting', null, null, p_entity_id, null), '{}'::jsonb) end
      || case when p_site_id is null then '{}'::jsonb
              else coalesce(erp.config_value('inventory.count_posting', null, null, p_entity_id, p_site_id), '{}'::jsonb) end
    from erp_ref.config_type ct
   where ct.code = 'inventory.count_posting'
$$;

revoke all on function erp.count_posting_policy(uuid, uuid) from public, anon;

comment on function erp.count_posting_policy(uuid, uuid) is
  'inventory.count_posting at an entity and site, over its defaults (20260927300000). '
  'Read by erp.count_is_within_tolerance(), the fact erp.record_count() posts a count '
  'inside tolerance from.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A3. The fact a count's post, as it is recorded, is derived from
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.count_post_hold_reason(p_task_id uuid)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  t        erp.count_task%rowtype;
  pg       erp.count_programme%rowtype;
  v        jsonb;
  v_entity uuid;
  v_expect numeric;
  v_since  timestamptz;
  v_prior  numeric;
  v_n      integer;
  v_cum    numeric;
begin
  -- Why a count may not be posted by the system as it is recorded, or null
  -- when it may (20260927300000). erp.count_is_within_tolerance() is its
  -- null, the fact the post is derived from; erp.record_count() writes the
  -- reason on a count it holds. Everything fails closed: a value the policy
  -- door would have refused holds, and so does anything this cannot read.
  select * into t from erp.count_task
   where tenant_id = erp.current_tenant_id() and id = p_task_id;
  if not found then
    return 'not_a_count: no such count in this organisation';
  end if;

  -- Approved because inside tolerance, not because an approver agreed, and
  -- recorded in this transaction: a count held yesterday is not posted by
  -- the system today because the policy has changed since.
  if t.status <> 'approved' or not coalesce(t.within_tolerance, false)
     or t.approval_request_id is not null or t.counted_at is distinct from now() then
    return 'not_recorded_inside_tolerance: only a count approved by its tolerance, as it is recorded, posts itself';
  end if;

  select s.entity_id into v_entity from erp.site s
   where s.tenant_id = t.tenant_id and s.id = t.site_id;
  v := erp.count_posting_policy(v_entity, t.site_id);

  -- Only the exact "post" posts.
  if (v -> 'within_tolerance') is distinct from '"post"'::jsonb then
    return 'held_by_policy: the site''s count posting policy holds counts inside tolerance for somebody to post';
  end if;

  -- A count with no variance moves nothing: no rule below has anything to
  -- bound, and the self-posting rule never covered it.
  if coalesce(t.variance, 0) = 0 then
    return null;
  end if;

  -- Before go-live one person counts and posts, as the approval rules allow
  -- (20260914062000); both bounds below are a live organisation's.
  if not erp.tenant_is_live(t.tenant_id) then
    return null;
  end if;

  -- The counter's own: posts only on JSON true, or with nothing said and the
  -- default true applying. A string, a null or anything else holds.
  if t.counted_by is not distinct from erp.current_principal_id()
     and (v ? 'self_post_within_tolerance')
     and (v -> 'self_post_within_tolerance') is distinct from 'true'::jsonb then
    return 'held_own_count: the site''s count posting policy holds the counter''s own count for somebody else to post';
  end if;

  -- Unattended posting is bounded across counts, not per count: otherwise a
  -- place counted again after it posted, short each time by just inside the
  -- tolerance, is written down by as much as anyone likes without a second
  -- person. The variance the system has posted at the same place — item,
  -- location, batch, owner and handling unit — since the later of the last
  -- post there by a person and the programme's window, with this one added,
  -- must itself be inside the programme's tolerance, by the same rule the
  -- count is judged by and against what this count expected. A count
  -- programme carries no cycle or frequency of its own, so the window is the
  -- thirty days the rule falls back to.
  select * into pg from erp.count_programme p
   where p.tenant_id = t.tenant_id and p.id = t.count_programme_id;

  select max(p.posted_at) into v_since
    from erp.count_task p
   where p.tenant_id = t.tenant_id and p.id <> t.id
     and p.status = 'posted' and not p.posted_by_system
     and p.item_id = t.item_id
     and p.location_id is not distinct from t.location_id
     and p.batch_id is not distinct from t.batch_id
     and p.owner_party_id is not distinct from t.owner_party_id
     and p.container_id is not distinct from t.container_id;
  v_since := greatest(coalesce(v_since, '-infinity'::timestamptz), now() - interval '30 days');

  select coalesce(sum(o.variance), 0), count(*) into v_prior, v_n
    from erp.count_task o
   where o.tenant_id = t.tenant_id and o.id <> t.id
     and o.status = 'posted' and o.posted_by_system
     and o.posted_at > v_since
     and o.item_id = t.item_id
     and o.location_id is not distinct from t.location_id
     and o.batch_id is not distinct from t.batch_id
     and o.owner_party_id is not distinct from t.owner_party_id
     and o.container_id is not distinct from t.container_id;

  v_cum := v_prior + t.variance;
  v_expect := t.expected_quantity + t.movement_during - t.committed_quantity;
  if not (abs(v_cum) <= pg.tolerance_absolute
          or (v_expect <> 0 and abs(v_cum) * 100.0 / abs(v_expect) <= pg.tolerance_pct)) then
    return format('held_cumulative: with %s count(s) at this place posted by the system since %s, '
                  'the variance comes to %s, outside the programme''s tolerance of %s or %s per cent',
                  v_n, v_since, trim_scale(v_cum), trim_scale(pg.tolerance_absolute),
                  trim_scale(pg.tolerance_pct));
  end if;

  return null;
end;
$$;

revoke all on function erp.count_post_hold_reason(uuid) from public, anon;

comment on function erp.count_post_hold_reason(uuid) is
  'Why a count task may not be posted by the system as it is recorded, or null when it may '
  '(20260927300000): not approved by its tolerance in this transaction, the site''s '
  'inventory.count_posting holding it or the counter''s own, or, once live, the variance posted '
  'unattended at the place since a person last posted there (thirty days at most) adding up past '
  'the programme''s tolerance. Fails closed.';

create or replace function erp.count_is_within_tolerance(p_task_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  -- The fact a count's post as it is recorded is derived from
  -- (20260927300000): erp.count_post_hold_reason() finds nothing to hold it
  -- for. Read by erp.derived_move_fact() with the task's state locked, and by
  -- erp.post_count() to decide whether the post is the person's or the
  -- system's.
  select erp.count_post_hold_reason(p_task_id) is null
$$;

revoke all on function erp.count_is_within_tolerance(uuid) from public, anon;

comment on function erp.count_is_within_tolerance(uuid) is
  'True when a count task, recorded in this transaction inside its tolerance with no approval, '
  'may be posted by the system as it is recorded: erp.count_post_hold_reason() is null '
  '(20260927300000). The fact the count''s post is derived from.';

-- The count task's post, read again with its state locked. Deployed body,
-- asserted needle: one arm more in the count task case.
do $derived$
declare
  v_sig constant text := 'erp.derived_move_fact(text,uuid,text)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$             then 'erp.scan_confirms'
$o$;
  v_new constant text := $n$             then 'erp.scan_confirms'
           -- A count's post as it is recorded (20260927300000), asked for by
           -- erp.record_count() when the count is inside its tolerance and
           -- the site's count posting policy says post.
           when p_transition_code = 'post'
            and t.status = 'approved'
            and erp.count_is_within_tolerance(t.id)
             then 'erp.count_is_within_tolerance'
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % scanner arm found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$derived$;

-- ─────────────────────────────────────────────────────────────────────────────
-- A4. The post: the person's, or the system's
--
-- erp.post_count() keeps its door, its guards and its route to the ledger.
-- Where the post is derived from the count being inside its tolerance, it
-- asks nothing of the person — the counter holds inventory.count, not
-- inventory.adjust — and the self-posting rule, which the fact has already
-- applied as the policy says, is not asked again.
-- ─────────────────────────────────────────────────────────────────────────────

do $post$
declare
  v_sig constant text := 'erp.post_count(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  v_ccy     char(3);
begin$o$,
    $n$  v_ccy     char(3);
  v_system  boolean;
begin$n$,
    $o$  perform erp.authorise('inventory.adjust', null, t.site_id, null,
                        'count_task', p_task_id);
$o$,
    $n$  -- The system's post, as the count is recorded inside its tolerance
  -- (20260927300000): erp.record_count() names the move, and the fact is
  -- read again here with the task locked. It asks nothing of the person,
  -- as the adjustment it raises does not; every other post is the person's.
  v_system := erp.derived_move_fact('count_task', p_task_id, 'post') is not null;
  if not v_system then
    perform erp.authorise('inventory.adjust', null, t.site_id, null,
                          'count_task', p_task_id);
  end if;
$n$,
    $o$  if t.counted_by is not null
     and t.counted_by = erp.current_principal_id()
     and erp.tenant_is_live(v_tenant) then$o$,
    $n$  --
  -- Not asked of the system's post (20260927300000): the count is inside its
  -- tolerance, and the fact it posts from has applied the site's count
  -- posting policy, which may hold the counter's own for somebody else.
  if not v_system
     and t.counted_by is not null
     and t.counted_by = erp.current_principal_id()
     and erp.tenant_is_live(v_tenant) then$n$];
  v_hits integer;
begin
  -- Both posts, with and without a variance, say who made them, at the
  -- moment they were made, so that a person's post orders against the
  -- system's in one transaction as in two (20260927300000).
  v_hits := (length(v_def) - length(replace(v_def, 'set posted_at = now(), updated_at = now()', '')))
            / length('set posted_at = now(), updated_at = now()');
  if v_hits <> 2 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % posted_at found % time(s)', v_sig, v_hits;
  end if;
  v_def := replace(v_def, 'set posted_at = now(), updated_at = now()',
                   'set posted_at = clock_timestamp(), posted_by_system = v_system, updated_at = now()');
  for v_i in 1 .. array_length(v_pairs, 1) / 2 loop
    v_hits := (length(v_def) - length(replace(v_def, v_pairs[2*v_i - 1], ''))) / length(v_pairs[2*v_i - 1]);
    if v_hits <> 1 then
      raise exception 'CLOVEERP_ANCHOR_MOVED: % anchor % found % time(s)', v_sig, v_i, v_hits;
    end if;
    v_def := replace(v_def, v_pairs[2*v_i - 1], v_pairs[2*v_i]);
  end loop;
  execute v_def;
end
$post$;

comment on function erp.post_count(uuid) is
  'Posts an approved count: a variance through a stock adjustment of its own, raised, approved from '
  'the count''s approval and posted by erp.raise_count_adjustment() under COUNT_VARIANCE, against the '
  'owner''s position and in the handling unit counted, costed only when the company owns the stock '
  '(20260927200000); by a movement of its own, as before, in an organisation with no active stock '
  'adjustment type or one whose type writes another movement than count_adjustment. A count with no '
  'variance posts with no adjustment. Authorises inventory.adjust, and once the organisation is live '
  'the counter does not post their own variance; neither is asked of the system''s post, which '
  'erp.record_count() makes of a count inside its tolerance under the site''s inventory.count_posting '
  '(20260927300000).';

-- The adjustment the system's post raises is opened by the system too: the
-- door every document is opened by asks inventory.adjust of the person, and
-- the counter does not hold it. erp.firm_planned_order() is the precedent.
do $raise$
declare
  v_sig constant text := 'erp.raise_count_adjustment(uuid)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  v_doc := erp.open_document('stock_adjustment', null, s.entity_id, t.site_id,
                             null, null, null);
$o$;
  v_new constant text := $n$  --
  -- Unless the post is the system's, as the count is recorded inside its
  -- tolerance (20260927300000): then the adjustment is opened the way that
  -- door opens it, less the person's permission, under the fact the post is
  -- derived from, read again here with the task locked.
  if erp.derived_move_fact('count_task', p_task_id, 'post') is not null then
    v_doc := erp.create_document('stock_adjustment', s.entity_id, t.site_id, null,
                                 null, null, null);
  else
    v_doc := erp.open_document('stock_adjustment', null, s.entity_id, t.site_id,
                               null, null, null);
  end if;
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % open anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$raise$;

comment on function erp.raise_count_adjustment(uuid) is
  'Raises the stock adjustment that is an approved count''s variance, approves it from the count''s '
  'own approval and posts it through erp.post_adjustment_lines() (20260927200000). Not a door: '
  'erp.post_count() calls it, after asking inventory.adjust and applying the self-posting rule, or, '
  'for the system''s post as a count inside tolerance is recorded, under the fact it is derived '
  'from, when it opens the adjustment without asking the person (20260927300000).';

-- ─────────────────────────────────────────────────────────────────────────────
-- A5. The count posts as it is recorded
-- ─────────────────────────────────────────────────────────────────────────────

do $record$
declare
  v_sig constant text := 'erp.record_count(uuid,numeric)';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  v_scanned boolean;
begin$o$,
    $n$  v_scanned boolean;
  v_msg     text;
  v_state   text;
  v_hint    text;
  v_held    text;
begin$n$,
    $o$  select * into pg from erp.count_programme where id = t.count_programme_id;
$o$,
    $n$  -- Nought or more (20260927300000): a negative figure would post a loss
  -- of more than was there and take the stock below zero.
  if p_quantity < 0 then
    raise exception 'CLOVEERP_COUNT_QUANTITY_NEGATIVE: % counted for %, and a count is nought or more',
      trim_scale(p_quantity),
      coalesce((select i.code from erp.item i where i.tenant_id = v_tenant and i.id = t.item_id), p_task_id::text)
      using errcode = '22003',
            hint = 'Count the place again and record what is there: nought or more.';
  end if;
  select * into pg from erp.count_programme where id = t.count_programme_id;
$n$,
    $o$  perform set_config('erp.deriving_move', '', true);

  return v_status;$o$,
    $n$  perform set_config('erp.deriving_move', '', true);

  -- Inside its tolerance, the count posts as it is recorded (20260927300000),
  -- as the system's move, derived from erp.count_is_within_tolerance(): the
  -- tolerance is the organisation's own decision about what is immaterial,
  -- and a second person on it buys little and costs one press per place.
  -- It is held for somebody to post instead, with the reason on the task,
  -- when the site's count posting policy holds it or the counter's own, or
  -- when what the system has posted unattended at the place would add up
  -- past the tolerance. A count approved by an approver, or outside its
  -- tolerance, is posted by hand as before.
  --
  -- A post refused by a conflict that clears by itself refuses the record,
  -- so it is recorded again, and a scanner's count is applied again on the
  -- next drain. Any other refusal keeps the count, recorded and approved,
  -- for somebody to post, with the refusal's code and message on the task:
  -- a figure somebody went and counted is not thrown away.
  if v_status = 'approved' and v_ok and v_req is null then
    perform set_config('erp.deriving_move', p_task_id::text || ':post', true);
    if erp.derived_move_fact('count_task', p_task_id, 'post') is not null then
      begin
        perform erp.post_count(p_task_id);
        v_status := 'posted';
      exception when others then
        get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate,
                                v_hint = pg_exception_hint;
        perform set_config('erp.deriving_move', '', true);
        if v_state in ('40001', '40P01', '55P03') then
          raise exception 'CLOVEERP_COUNT_AUTOPOST_FAILED: the count of % is inside its tolerance and posts as it is recorded, but its post met a conflict, so it is not recorded: %',
            coalesce((select i.code from erp.item i where i.tenant_id = v_tenant and i.id = t.item_id), p_task_id::text),
            v_msg
            using errcode = v_state,
                  detail = format('SQLSTATE %s from the post, a conflict that clears by itself.', v_state),
                  hint = 'Record the count again. The conflict is another transaction''s and passes; a scanner''s queued count is applied again on the next drain.';
        end if;
        v_held := format('post_refused: %s %s', v_state, v_msg);
      end;
    else
      v_held := erp.count_post_hold_reason(p_task_id);
    end if;
    perform set_config('erp.deriving_move', '', true);
    if v_held is not null then
      update erp.count_task
         set post_held_reason = left(v_held, 1000), updated_at = now()
       where tenant_id = v_tenant and id = p_task_id;
    end if;
  end if;

  return v_status;$n$];
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
$record$;

comment on function erp.record_count(uuid, numeric) is
  'Records a counted quantity against an open count task and says where it left the task. A variance '
  'inside either the programme''s absolute tolerance or its percentage one is within tolerance, and '
  'the count is posted as it is recorded, as the system''s move, unless the site''s '
  'inventory.count_posting holds it or what the system has posted unattended at the place would add '
  'up past the tolerance, when the reason is kept on the task (20260927300000). A post refused by a '
  'transient conflict refuses the record; any other refusal keeps the count approved, with the '
  'refusal on the task. A negative figure is refused. '
  'Outside both it goes to the programme''s approval chain, or stops at counted where it has none.';

comment on function public.erp_record_count(uuid, numeric) is
  'Records a counted quantity against an open count task and says where it left the task: posted, '
  'when it is inside its tolerance and the site''s count posting policy lets it post as it is '
  'recorded (20260927300000); approved, when the policy holds it or an approval chain approved it '
  'as raised; waiting for approval, or counted, outside tolerance.';

-- ─────────────────────────────────────────────────────────────────────────────
-- A6. The policy is proposed as a change, from the Stock audit screen
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp.propose_count_posting_policy(
  p_entity_code text, p_site_code text, p_value jsonb, p_change_set_id uuid)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_tenant uuid := erp.require_tenant_id();
  v_entity text := p_entity_code;
  ct       erp_ref.config_type%rowtype;
  v_key    text;
  v_cs     uuid := p_change_set_id;
begin
  perform erp.authorise('administration.configure', null, null, null, 'change_set', p_change_set_id);

  select * into ct from erp_ref.config_type c where c.code = 'inventory.count_posting';
  if p_value is null or jsonb_typeof(p_value) <> 'object' or p_value = '{}'::jsonb
     or not erp.jsonb_matches_schema(ct.value_schema::json, p_value) then
    raise exception 'CLOVEERP_POLICY_VALUE_INVALID: the count posting policy does not fit its declared shape'
      using errcode = '22023',
            hint = 'Inside tolerance a count is post or hold, and whether the counter''s own posts itself is yes or no; give one or both.';
  end if;
  for v_key in select jsonb_object_keys(p_value) loop
    if not ((v_key = 'within_tolerance' and p_value ->> v_key in ('post', 'hold'))
            or (v_key = 'self_post_within_tolerance' and jsonb_typeof(p_value -> v_key) = 'boolean')) then
      raise exception 'CLOVEERP_POLICY_VALUE_INVALID: the count posting policy does not fit its declared shape'
        using errcode = '22023',
              hint = 'Inside tolerance a count is post or hold, and whether the counter''s own posts itself is yes or no; give one or both.';
    end if;
  end loop;

  if p_site_code is not null then
    select e.code into v_entity
      from erp.site s join erp.entity e on e.id = s.entity_id
     where s.tenant_id = v_tenant and s.code = p_site_code;
    if v_entity is null then
      raise exception 'CLOVEERP_UNKNOWN_SITE: % is not a site of this organisation', p_site_code
        using errcode = '23503', hint = 'erp_sites() lists the sites by code; a site policy belongs to the site''s company.';
    end if;
    if p_entity_code is not null and p_entity_code is distinct from v_entity then
      raise exception 'CLOVEERP_POLICY_SCOPE_DISAGREES: % belongs to %, not to %', p_site_code, v_entity, p_entity_code
        using errcode = '22023', hint = 'Name the site alone, or the site with its own company.';
    end if;
  elsif p_entity_code is not null and not exists (select 1 from erp.entity e where e.tenant_id = v_tenant and e.code = p_entity_code) then
    raise exception 'CLOVEERP_UNKNOWN_ENTITY: % is not a company of this organisation', p_entity_code
      using errcode = '23503', hint = 'erp_entities() lists the companies by code.';
  end if;

  if v_cs is null then
    v_cs := erp.create_change_set(
      'count-posting-policy-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS-US'),
      'Count posting policy',
      'Whether a count inside its tolerance posts itself as it is recorded, and whether the counter''s own does once the organisation is live.');
  end if;

  return erp.add_change_set_item(v_cs, 'config',
    format('inventory.count_posting|%s|%s', coalesce(v_entity, '*'), coalesce(p_site_code, '*')),
    jsonb_strip_nulls(jsonb_build_object(
      'config_type', 'inventory.count_posting', 'value', p_value,
      'entity', v_entity, 'site', p_site_code)),
    'upsert', null, 'proposed from the Stock audit screen');
end;
$$;

revoke all on function erp.propose_count_posting_policy(text, text, jsonb, uuid) from public, anon;

comment on function erp.propose_count_posting_policy(text, text, jsonb, uuid) is
  'Proposes the count posting policy for the organisation, a company or a site, as an '
  'item of a change set (20260927300000).';

create or replace function public.erp_propose_count_posting_policy(
  p_entity_code text, p_site_code text, p_value jsonb, p_change_set_id uuid)
returns uuid
language sql
set search_path = ''
as $$
  select erp.propose_count_posting_policy(p_entity_code, p_site_code, p_value, p_change_set_id)
$$;

revoke all on function public.erp_propose_count_posting_policy(text, text, jsonb, uuid) from public, anon;
grant execute on function public.erp_propose_count_posting_policy(text, text, jsonb, uuid) to authenticated, service_role;

comment on function public.erp_propose_count_posting_policy(text, text, jsonb, uuid) is
  'Proposes whether a count inside its tolerance posts itself as it is recorded, and whether the '
  'counter''s own does once the organisation is live, for the organisation, a company or a site, as '
  'an item of a change set. Authorises administration.configure (20260927300000).';

insert into erp_meta.public_write_allowance (function_name, gate, rationale) values
  ('erp_propose_count_posting_policy', 'erp.propose_count_posting_policy',
   'Proposes whether a count inside its tolerance posts itself as it is recorded, and whether the counter''s own does once the organisation is live, as a change-set item; authorises administration.configure.')
on conflict (function_name) do update set gate = excluded.gate, rationale = excluded.rationale;

select erp_meta.add_help_actions('/inventory/audit', array['erp_propose_count_posting_policy']);

-- ─────────────────────────────────────────────────────────────────────────────
-- A7. The words the Stock audit screen says for it (src/routes/inventory/audit.tsx,
--     src/lib/modules.tsx)
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_ref.resource (key, locale, value, description)
select erp_ref.ui_key(v.text), 'en', v.text,
       'A screen string, rendered through ui(). The count posting policy and the count that posts as it is recorded, on the Stock audit screen (20260927300000).'
  from (values
    ('A place nobody has counted shows as never counted rather than as agreeing. A count inside its tolerance corrects the stock as it is recorded, through a stock adjustment with a reason; one outside it corrects nothing until it is agreed and posted.'),
    ('Raise tasks from a counting programme and record what was found. A count inside its tolerance posts as it is recorded; one outside it is agreed by its approver and then posted.'),
    ('What the counter found in the place. The difference is worked out from it, and a count inside its tolerance posts as it is recorded, unless the site''s count posting policy holds it.'),
    ('A count outside its programme''s tolerance waits for the approving role to agree. Agreed, it is posted by somebody who may adjust stock; refused, it stays as it was found and is not posted.'),
    ('Correct the stock by a difference that was agreed, or one the site''s count posting policy holds. Once the organisation is live, somebody other than the person who counted it posts it.'),
    ('Post a count agreed by its approver, or one the count posting policy holds. A count inside its tolerance posts itself as it is recorded.'),
    ('Propose the count posting policy'),
    ('Whether a count inside its tolerance posts itself as it is recorded or waits for somebody to post it, and whether the counter''s own does once the organisation is live. The tolerance is the counting programme''s, in units or a share of the units expected, with no threshold by value. Proposed as a change like any other configuration.'),
    ('Leave unchosen to set the policy for the whole organisation.'),
    ('Leave unchosen to apply the policy across the whole company.'),
    ('A count inside tolerance'),
    ('Posts as it is recorded'),
    ('Waits for somebody to post it'),
    ('Hold waits for somebody who may adjust stock to post each count, as outside tolerance. Left unchosen, the broader setting applies.'),
    ('The counter''s own count inside tolerance'),
    ('Posts itself'),
    ('Waits for somebody else'),
    ('Once the organisation is live. Waits leaves the counter''s own count for a second person, as every count outside tolerance is. Left unchosen, the broader setting applies.')
  ) as v(text)
on conflict (key, locale) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- A8. The decision, in the register it is read from
-- ─────────────────────────────────────────────────────────────────────────────

insert into erp_meta.policy_decision (code, title, spec_reference, decision, rationale, status, evidence)
values (
  'count_posts_within_tolerance',
  'A count inside its tolerance posts as it is recorded, the counter''s own included',
  'docs/spec/simplification-review.md I3',
  'A count inside its programme''s tolerance is posted by the system as it is recorded, in the same '
  'step, even when the counter posts nothing else and even once the organisation is live: '
  'CLOVEERP_COUNT_SELF_POSTING gives way inside tolerance. inventory.count_posting, per organisation, '
  'company or site, can hold every such count for somebody to post (within_tolerance hold), or only '
  'the counter''s own (self_post_within_tolerance false). The tolerance is in units, or a share of the '
  'units expected, with no threshold by value. Once live, what the system posts unattended at one '
  'place is bounded across counts by the same tolerance, from the last post there by a person or '
  'thirty days back, whichever is later; past it the count is held for a second person, with the '
  'reason on the task. Outside tolerance nothing changes: the approver agrees, somebody posts, and '
  'the counter does not post their own. A post refused by a transient conflict refuses the record; '
  'any other refusal keeps the count approved for somebody to post.',
  'The tolerance is the organisation''s own decision about what is immaterial, and in a live '
  'organisation it changes only through a change set somebody else approves. A second person on a '
  'variance already declared immaterial bought little control and cost one press per place, and the '
  'free-hand stock adjustment already let a counter who may adjust stock write their own variance. '
  'A counter who shades counts inside the tolerance is seen by the count accuracy report; an '
  'organisation that wants the second person anyway keeps it by policy.',
  'accepted',
  'erp.count_is_within_tolerance() is the fact erp.record_count() posts from and '
  'erp.derived_move_fact() reads; erp_test.count_autopost_suite() proves the default, hold, the '
  'counter''s own held, the bound across counts at a place and its reset by a person''s post, '
  'outside tolerance unchanged, a refused post keeping the count, a transient one refusing it, '
  'consigned, batch-tracked and packed stock, and an organisation with no stock adjustment type '
  '(20260927300000).')
on conflict (code) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- A9. The suites whose expectations this moves
--
-- A count inside tolerance used to stop at approved and wait for Post. It
-- posts as it is recorded now. Suites that walk a count through its life
-- are re-pinned to say so. Suites that are about the post itself — what a
-- post writes, the two routes compared — hold counts inside tolerance by
-- the policy in their fixture, the way an organisation keeps today's
-- behaviour, and are otherwise unchanged.
-- ─────────────────────────────────────────────────────────────────────────────

-- count_tolerance_suite, case 2: five short on ten thousand passes and posts.
do $tolerance_suite$
declare
  v_sig constant text := 'erp_test.count_tolerance_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  passed := v_status = 'approved' and v_within;$o$;
  v_new constant text := $n$  -- Posted as it is recorded since 20260927300000, inside tolerance.
  passed := v_status = 'posted' and v_within;$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % case 2 anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$tolerance_suite$;

-- count_lifecycle_suite: case 3 posts as it is recorded, by the system's
-- move; case 6 is a count approved and not yet posted, which only a site
-- that holds can make inside tolerance, so its fixture holds from there on.
do $lifecycle_suite$
declare
  v_sig constant text := 'erp_test.count_lifecycle_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$    -- 3. Within tolerance: recorded and approved, then posted.
    v_fixture := 'recording and posting A';
    v_status := erp.record_count(t_a, 101)::text;
    perform erp.post_count(t_a);
$o$,
    $n$    -- 3. Within tolerance: recorded, approved and posted in one step, the
    --    post the system's (20260927300000).
    v_fixture := 'recording and posting A';
    v_status := erp.record_count(t_a, 101)::text;
$n$,
    $o$      v_status = 'approved' and v_log = 'record_approved,post'
$o$,
    $n$      v_status = 'posted' and v_log = 'record_approved,post'
      and (select l.guard_data #>> '{derived,fact}' from erp.state_transition_log l
            where l.tenant_id = r.tenant_id and l.object_type = 'count_task' and l.object_id = t_a
              and l.transition_code = 'post') = 'erp.count_is_within_tolerance'
$n$,
    $o$    v_fixture := 'raising over D';
    perform erp.record_count(t_d, 100);
$o$,
    $n$    v_fixture := 'raising over D';
    -- Held for somebody to post from here (20260927300000): inside
    -- tolerance, only a site that holds leaves a count approved.
    perform erp.set_config_value('inventory.count_posting',
      jsonb_build_object('within_tolerance', 'hold'), null, null, r.entity_id, null,
      'the count lifecycle suite: a count approved and not yet posted');
    perform erp.record_count(t_d, 100);
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
$lifecycle_suite$;

-- count_sheet_suite: a count inside tolerance posts as it is recorded, so the
-- sheet closes on the record of its last count.
do $sheet_suite$
declare
  v_sig constant text := 'erp_test.count_sheet_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$    v_status := erp.record_count(t_e, 100)::text;
    perform erp.post_count(t_e);
    return query select 'a task raised with no sheet is still counted and posted after the upgrade',
      v_status = 'approved'
$o$,
    $n$    -- Posted as it is recorded (20260927300000).
    v_status := erp.record_count(t_e, 100)::text;
    return query select 'a task raised with no sheet is still counted and posted after the upgrade',
      v_status = 'posted'
$n$,
    $o$    perform erp.record_count(t_a, 100);
    perform erp.post_count(t_a);
    perform erp.record_count(t_b, 99);
    perform erp.post_count(t_b);
$o$,
    $n$    -- Each posted as it is recorded (20260927300000).
    perform erp.record_count(t_a, 100);
    perform erp.record_count(t_b, 99);
$n$,
    $o$    perform erp.record_count(t_d, 100);
    perform erp.post_count(t_d);
    return query select 'the other site''s sheet closes with its own last count',$o$,
    $n$    -- Its last count posts as it is recorded, so the record closes the
    -- sheet (20260927300000).
    perform erp.record_count(t_d, 100);
    return query select 'the other site''s sheet closes with its own last count, as it is recorded',$n$];
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
$sheet_suite$;

-- count_adjustment_suite compares the post's two routes from one state, so
-- its counts are recorded first and posted each way after: the fixture
-- holds counts inside tolerance, as an organisation may.
do $adjustment_suite$
declare
  v_sig constant text := 'erp_test.count_adjustment_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$    -- Every count inside tolerance, so every task is approved as it is
    -- recorded and is Post's to finish.
    v_fixture := 'raising and recording the counts';
$o$;
  v_new constant text := $n$    -- Every count inside tolerance, so every task is approved as it is
    -- recorded and, held by the count posting policy, is Post's to finish:
    -- recorded once, and posted by each route from the same state
    -- (20260927300000).
    v_fixture := 'raising and recording the counts';
    perform erp.set_config_value('inventory.count_posting',
      jsonb_build_object('within_tolerance', 'hold'), null, null, null, null,
      'the count adjustment suite posts each count both ways');
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % fixture anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$adjustment_suite$;

-- identity_policy_suite is about what a count of a handling unit or of
-- consigned stock posts: its counts are recorded and then posted by hand, so
-- its fixture holds counts inside tolerance.
do $identity_suite$
declare
  v_sig constant text := 'erp_test.identity_policy_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_old constant text := $o$  values (v_tenant, 'zz_hu_count', 'Identity suite count', v_site, 'cycle', 'true'::jsonb, 5, 100, 'active')
  returning id into v_prog;
$o$;
  v_new constant text := $n$  values (v_tenant, 'zz_hu_count', 'Identity suite count', v_site, 'cycle', 'true'::jsonb, 5, 100, 'active')
  returning id into v_prog;
  -- Recorded, then posted by hand, as the cases below read the post
  -- (20260927300000).
  perform erp.set_config_value('inventory.count_posting',
    jsonb_build_object('within_tolerance', 'hold'), null, null, null, null,
    'the identity policy suite posts its counts by hand');
$n$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % programme anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$identity_suite$;

-- fifo_is_costed_from_its_layers_suite, case 2: the count that finds stock
-- posts as it is recorded, and is costed the same.
do $fifo_suite$
declare
  v_sig constant text := 'erp_test.fifo_is_costed_from_its_layers_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$    v_got := erp.record_count(v_task, 22)::text;
    perform erp.post_count(v_task);
$o$,
    $n$    -- Posted as it is recorded, inside tolerance (20260927300000).
    v_got := erp.record_count(v_task, 22)::text;
$n$,
    $o$    passed := coalesce(v_got = 'approved' and v_unit = 500 and v_cost = 1000$o$,
    $n$    passed := coalesce(v_got = 'posted' and v_unit = 500 and v_cost = 1000$n$];
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
$fifo_suite$;

-- inventory_suite, in a live organisation: a count inside tolerance posts as
-- it is recorded, the variance of one the administrator counted included,
-- where it used to wait for the second administrator.
do $inventory_suite$
declare
  v_sig constant text := 'erp_test.inventory_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  return query select 'a count that agrees with the adjusted expectation is clean',
    v_status = 'approved'
$o$,
    $n$  return query select 'a count that agrees with the adjusted expectation is clean',
    v_status = 'posted'
$n$,
    $o$  v_var := erp.post_count(v_task);
  return query select 'and posting a zero variance writes no movement',$o$,
    $n$  -- Posted as it was recorded (20260927300000).
  v_var := (select t.variance from erp.count_task t
             where t.id = v_task and t.status = 'posted' and t.adjustment_document_id is null);
  return query select 'and posting a zero variance writes no movement',$n$,
    $o$  return query select 'a variance inside both tolerances approves itself',
    v_status = 'approved'
$o$,
    $n$  return query select 'a variance inside both tolerances approves and posts itself',
    v_status = 'posted'
$n$,
    $o$  -- Posted by the second administrator: whoever counted does not post the
  -- variance once the organisation is live (20260914070000).
  perform set_config('request.jwt.claims', json_build_object('sub',a2)::text, true);
  v_var := erp.post_count(v_task);
  perform set_config('request.jwt.claims', json_build_object('sub',a1)::text, true);
$o$,
    $n$  -- Posted as it was recorded, by the system's move, though the
  -- organisation is live and the administrator counted it: inside
  -- tolerance the self-posting rule gives way (20260927300000). Outside
  -- it, the second administrator still posts.
  v_var := (select t.variance from erp.count_task t
             where t.id = v_task and t.status = 'posted' and t.counted_by = erp.current_principal_id()
               and erp.tenant_is_live(t.tenant_id));
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
$inventory_suite$;

-- device_drain_suite: a zero-variance count drained from the scanner is
-- inside tolerance, and posts as it is applied.
do $drain_suite$
declare
  v_sig constant text := 'erp_test.device_drain_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$    and (select t.status::text from erp.count_task t where t.id = v_ctask) = 'approved'
$o$,
    $n$    -- Posted as it is applied, inside tolerance (20260927300000).
    and (select t.status::text from erp.count_task t where t.id = v_ctask) = 'posted'
$n$,
    $o$    (select a.applied_result from erp.device_action a where a.id = k2) = 'approved'
$o$,
    $n$    (select a.applied_result from erp.device_action a where a.id = k2) = 'posted'
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
$drain_suite$;

-- recount_suite, cases 5 and 6: the reopened count, inside tolerance on its
-- new figure, posts as it is recorded, and settling the old refusal again
-- leaves it posted.
do $recount_suite$
declare
  v_sig constant text := 'erp_test.recount_suite()';
  v_def text := pg_get_functiondef(v_sig::regprocedure);
  v_pairs constant text[] := array[
    $o$  passed := v_status = 'approved' and v_within;
  detail := format('counted 1245 of 1250 under CYCLE_A: %s, within_tolerance %s', v_status, v_within);$o$,
    $n$  -- Posted as it is recorded, inside tolerance (20260927300000).
  passed := v_status = 'posted' and v_within;
  detail := format('counted 1245 of 1250 under CYCLE_A: %s, within_tolerance %s', v_status, v_within);$n$,
    $o$  passed := v_status = 'approved';
  detail := format('after settling the old request a second time the task is %s', v_status);$o$,
    $n$  passed := v_status = 'posted';
  detail := format('after settling the old request a second time the task is %s', v_status);$n$];
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
$recount_suite$;

-- ─────────────────────────────────────────────────────────────────────────────
-- B1. The proof: erp_test.count_autopost_suite
--
-- One organisation, three sites: one on the product's default, one whose
-- policy holds every count inside tolerance, one whose policy holds the
-- counter's own. A counter who holds inventory.count and nothing that adjusts
-- stock, two administrators. Counted before and after go-live, inside and
-- outside tolerance, with the post refused, on a task raised before the
-- lifecycle, and in an organisation with no stock adjustment type. The four
-- ledgers and ownership are asked to agree after every case.
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function erp_test.count_books_agree()
returns text
language plpgsql
set search_path = ''
as $$
begin
  -- The stock ledger, the inventory valuation against the general ledger, the
  -- subledger against its control accounts, the inventory's own sanity and
  -- ownership, in the current organisation (20260927300000). 'passed', or
  -- what refused.
  perform erp.assert_stock_reconciles();
  perform erp.assert_inventory_reconciles();
  perform erp.assert_subledger_reconciles();
  perform erp.assert_inventory_sane();
  perform erp.assert_ownership_carried();
  return 'passed';
exception when others then
  return left(sqlerrm, 200);
end;
$$;

revoke all on function erp_test.count_books_agree() from public, anon;

comment on function erp_test.count_books_agree() is
  'Whether the stock ledger, inventory valuation, subledger, inventory sanity and ownership agree in '
  'the current organisation: ''passed'', or the refusal (20260927300000). For the count suites.';

create or replace function erp_test.count_autopost_suite()
 returns table(case_name text, passed boolean, detail text)
 language plpgsql
 set search_path to ''
as $function$
declare
  v_hex     text := substr(md5(gen_random_uuid()::text), 1, 8);
  a1        uuid := gen_random_uuid();
  a2        uuid := gen_random_uuid();
  a3        uuid := gen_random_uuid();
  r         record;
  res       jsonb;
  v_tok     text; v_tok3 text;
  v_second  uuid; v_counter uuid;
  p1 uuid; p2 uuid; p3 uuid;
  csf uuid; csp uuid; csi uuid; v_cs uuid;
  v_uom uuid; v_sup uuid; v_grn uuid; v_ecode text;
  s_main uuid; s_hold uuid; s_strict uuid;
  i_a uuid; i_b uuid; i_c uuid; i_o uuid; i_n uuid; i_l uuid; i_r uuid;
  i_h uuid; i_h0 uuid; i_s1 uuid; i_s2 uuid; i_s0 uuid;
  i_k uuid; i_bt uuid; i_p uuid; i_w uuid; i_t uuid;
  v_recv uuid; v_bat uuid; v_case uuid; v_line uuid; v_detail text; j1 uuid; j2 uuid;
  t_a uuid; t_b uuid; t_c uuid; t_o uuid; t_n uuid; t_l uuid; t_r uuid;
  t_h uuid; t_h0 uuid; t_s1 uuid; t_s2 uuid; t_s0 uuid;
  t_k uuid; t_bt uuid; t_p uuid; t_w1 uuid; t_w2 uuid; t_w3 uuid; t_t uuid;
  v_req uuid; v_task uuid; v_doc uuid;
  v_status text; v_status2 text; v_status3 text;
  v_log text; v_guard jsonb; v_guard2 jsonb;
  v_err text; v_err2 text; v_err3 text; v_state text; v_hint text;
  v_fact text; v_fact2 text;
  v_books text;
  v_n integer; v_n2 integer; v_n3 integer; v_locks integer;
  v_mark bigint;
  v_fixture text;
begin
  -- 1. The policy is declared, defaulting to post, and something reads it.
  return query select 'inventory.count_posting is declared at site scope, defaulting to post with the counter''s own included, read where it acts, and recorded as a decision',
    exists (select 1 from erp_ref.config_type ct
             where ct.code = 'inventory.count_posting' and ct.domain = 'policy'
               and ct.module_code = 'inventory' and ct.max_scope_level::text = 'site' and ct.is_singleton
               and ct.default_value = '{"within_tolerance": "post", "self_post_within_tolerance": true}'::jsonb
               and erp.jsonb_matches_schema(ct.value_schema::json, ct.default_value)
               and ct.value_schema -> 'additionalProperties' = 'false'::jsonb
               and ct.value_schema #> '{properties,within_tolerance,enum}' = '["post", "hold"]'::jsonb
               and ct.value_schema #>> '{properties,self_post_within_tolerance,type}' = 'boolean'
               and length(coalesce(ct.consequence, '')) > 40)
    and not exists (select 1 from erp.dead_configuration_report() c where c.reference = 'inventory.count_posting')
    and exists (select 1 from erp_meta.policy_decision d
                 where d.code = 'count_posts_within_tolerance' and d.status = 'accepted'
                   and coalesce(d.evidence, '') like '%erp_test.count_autopost_suite%'),
    'declared, read by erp.count_posting_policy(), and accepted in the policy register';

  begin
    v_fixture := 'provisioning';
    select * into r from erp.provision_tenant(
      'zz-cap-' || v_hex, 'Count autopost suite',
      'a@zz-cap-' || v_hex || '.test', 'Suite Admin');
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform erp.claim_invitation(r.admin_token);
    p1 := erp.current_principal_id();
    res := public.erp_invite_principal('second@zz-cap-' || v_hex || '.test', 'Second Admin');
    v_second := (res ->> 'app_user_id')::uuid; v_tok := res ->> 'token';
    perform erp.grant_role(v_second, 'administrator', null, null, 'co-administrator');
    res := public.erp_invite_principal('counter@zz-cap-' || v_hex || '.test', 'Stock Counter');
    v_counter := (res ->> 'app_user_id')::uuid; v_tok3 := res ->> 'token';
    perform erp.grant_role(v_counter, 'stock_counter', null, null, 'counts the shelves');

    v_fixture := 'installing';
    csf := erp.configure_finance();
    csp := erp.configure_procurement(100000000);
    csi := erp.configure_inventory('average');
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.claim_invitation(v_tok);
    p2 := erp.current_principal_id();
    perform erp.approve_change_set(csf); perform erp.promote_change_set(csf);
    perform erp.approve_change_set(csp); perform erp.promote_change_set(csp);
    perform erp.approve_change_set(csi); perform erp.promote_change_set(csi);
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform erp.claim_invitation(v_tok3);
    p3 := erp.current_principal_id();
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    -- Not live while the fixture is written; live from case 5.
    update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
    select e.code into v_ecode from erp.entity e where e.id = r.entity_id;

    v_fixture := 'the sites, the stock and the policies';
    insert into erp.uom (tenant_id, code, name, uom_class, decimals, is_base, status)
    values (r.tenant_id, 'EA', 'Each', 'quantity', 0, true, 'active') returning id into v_uom;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status) values
      (r.tenant_id, r.entity_id, 'MAIN', 'On the default', 'warehouse', 'active') returning id into s_main;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status) values
      (r.tenant_id, r.entity_id, 'HOLD', 'Holds every count inside tolerance', 'warehouse', 'active') returning id into s_hold;
    insert into erp.site (tenant_id, entity_id, code, name, site_type, status) values
      (r.tenant_id, r.entity_id, 'STRICT', 'Holds the counter''s own', 'warehouse', 'active') returning id into s_strict;
    insert into erp.location (tenant_id, site_id, code, name, location_type, status) values
      (r.tenant_id, s_main, 'RECV', 'Goods in', 'receiving', 'active'),
      (r.tenant_id, s_hold, 'RECV', 'Goods in', 'receiving', 'active'),
      (r.tenant_id, s_strict, 'RECV', 'Goods in', 'receiving', 'active');
    insert into erp.party (tenant_id, code, name, status)
    values (r.tenant_id, 'SUP', 'Supplier', 'active') returning id into v_sup;
    insert into erp.party_role (tenant_id, party_id, role_kind, status)
    values (r.tenant_id, v_sup, 'supplier', 'active');
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'A',  'Posts before go-live', v_uom, 'active') returning id into i_a;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'B',  'The counter''s own, live', v_uom, 'active') returning id into i_b;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'C',  'An administrator''s own, live', v_uom, 'active') returning id into i_c;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'O',  'Outside tolerance', v_uom, 'active') returning id into i_o;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'N',  'Its post is refused', v_uom, 'active') returning id into i_n;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'L',  'Raised before the lifecycle', v_uom, 'active') returning id into i_l;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'R',  'On the old route', v_uom, 'active') returning id into i_r;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'H',  'Held by policy', v_uom, 'active') returning id into i_h;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'H0', 'Held by policy, no variance', v_uom, 'active') returning id into i_h0;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'S1', 'The counter''s own before go-live', v_uom, 'active') returning id into i_s1;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'S2', 'The counter''s own, held', v_uom, 'active') returning id into i_s2;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'S0', 'The counter''s own, no variance', v_uom, 'active') returning id into i_s0;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'K',  'Consigned', v_uom, 'active') returning id into i_k;
    insert into erp.item (tenant_id, code, name, stock_uom_id, is_batch_controlled, status) values
      (r.tenant_id, 'BT', 'Tracked by batch', v_uom, true, 'active') returning id into i_bt;
    insert into erp.item (tenant_id, code, name, stock_uom_id, item_class, status) values
      (r.tenant_id, 'P',  'Packed in a case', v_uom, 'ZZCAP', 'active') returning id into i_p;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'W',  'Counted short again and again', v_uom, 'active') returning id into i_w;
    insert into erp.item (tenant_id, code, name, stock_uom_id, status) values
      (r.tenant_id, 'T',  'Its post meets a conflict', v_uom, 'active') returning id into i_t;
    select l.id into v_recv from erp.location l
     where l.tenant_id = r.tenant_id and l.site_id = s_main and l.code = 'RECV';

    v_grn := erp.open_document('goods_receipt', v_sup, null, s_main);
    perform erp.add_document_line(v_grn, i_a, 100, 100, 'A');
    perform erp.add_document_line(v_grn, i_b, 100, 100, 'B');
    perform erp.add_document_line(v_grn, i_c, 100, 100, 'C');
    perform erp.add_document_line(v_grn, i_o, 100, 100, 'O');
    perform erp.add_document_line(v_grn, i_n, 100, 100, 'N');
    perform erp.add_document_line(v_grn, i_l, 100, 100, 'L');
    perform erp.add_document_line(v_grn, i_r, 100, 100, 'R');
    perform erp.add_document_line(v_grn, i_w, 100, 100, 'W');
    perform erp.add_document_line(v_grn, i_t, 100, 100, 'T');
    perform erp.transition_document(v_grn, 'post');
    -- Five the supplier owns; six in one batch; three in a case, counted by
    -- the case.
    v_grn := erp.open_document('goods_receipt', v_sup, null, s_main);
    update erp.document set stock_owner_party_id = v_sup where id = v_grn;
    perform erp.add_document_line(v_grn, i_k, 5, 100, 'K, consigned');
    perform erp.transition_document(v_grn, 'post');
    v_bat := erp.create_batch(i_bt, 'ZZ-CAP-B-' || v_hex);
    insert into erp.container_identity_policy (tenant_id, code, name, item_class, site_id,
      device_task_code, identity_level, count_method, effective_from)
    values (r.tenant_id, 'ZZ-CAP-CASE', 'Count the suite''s packed product by the case', 'ZZCAP', s_main,
            'count', 'case', 'by_container', current_date - 1);
    v_case := erp.create_handling_unit(s_main, v_recv, 'case', null, 'ZZ-CAP-' || v_hex, i_p);
    v_grn := erp.open_document('goods_receipt', v_sup, null, s_main);
    v_line := erp.add_document_line(v_grn, i_bt, 6, 300, 'BT');
    update erp.document_line set location_id = v_recv, batch_id = v_bat where id = v_line;
    v_line := erp.add_document_line(v_grn, i_p, 3, 250, 'P');
    update erp.document_line set location_id = v_recv, container_id = v_case where id = v_line;
    perform erp.transition_document(v_grn, 'post');
    v_grn := erp.open_document('goods_receipt', v_sup, null, s_hold);
    perform erp.add_document_line(v_grn, i_h, 100, 100, 'H');
    perform erp.add_document_line(v_grn, i_h0, 100, 100, 'H0');
    perform erp.transition_document(v_grn, 'post');
    v_grn := erp.open_document('goods_receipt', v_sup, null, s_strict);
    perform erp.add_document_line(v_grn, i_s1, 100, 100, 'S1');
    perform erp.add_document_line(v_grn, i_s2, 100, 100, 'S2');
    perform erp.add_document_line(v_grn, i_s0, 100, 100, 'S0');
    perform erp.transition_document(v_grn, 'post');

    -- Per site, as the Stock audit screen proposes it; nothing for MAIN.
    perform erp.set_config_value('inventory.count_posting',
      jsonb_build_object('within_tolerance', 'hold'),
      null, null, r.entity_id, s_hold, 'the count autopost suite');
    perform erp.set_config_value('inventory.count_posting',
      jsonb_build_object('self_post_within_tolerance', false),
      null, null, r.entity_id, s_strict, 'the count autopost suite');

    -- CYCLE_A as the inventory installer ships it: inside two units or one
    -- and a half per cent, and a chain for anything outside.
    v_fixture := 'raising';
    perform erp.raise_count_tasks('cycle_a');
    select t.id into t_a  from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_a;
    select t.id into t_b  from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_b;
    select t.id into t_c  from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_c;
    select t.id into t_o  from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_o;
    select t.id into t_n  from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_n;
    select t.id into t_l  from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_l;
    select t.id into t_r  from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_r;
    select t.id into t_h  from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_h;
    select t.id into t_h0 from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_h0;
    select t.id into t_s1 from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_s1;
    select t.id into t_s2 from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_s2;
    select t.id into t_s0 from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_s0;
    select t.id into t_k  from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_k;
    select t.id into t_bt from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_bt;
    select t.id into t_p  from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_p;
    select t.id into t_w1 from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_w;
    select t.id into t_t  from erp.count_task t where t.tenant_id = r.tenant_id and t.item_id = i_t;
    -- A task raised before its organisation took the lifecycle is one with
    -- no lifecycle instance.
    delete from erp.object_state os
     where os.tenant_id = r.tenant_id and os.object_type = 'count_task' and os.object_id = t_l;

    -- 2. The fixture, and the policy as each site reads it.
    return query select 'the fixture: seventeen counts on a lifecycle but one, consigned, batch and packed among them, a counter who cannot adjust stock, and each site reads its own policy over the default',
      (select count(*) from erp.count_task t where t.tenant_id = r.tenant_id and t.status = 'open') = 17
      and (select count(*) from erp.object_state os
            where os.tenant_id = r.tenant_id and os.object_type = 'count_task') = 16
      and (select t.owner_party_id from erp.count_task t where t.id = t_k) = v_sup
      and (select t.batch_id from erp.count_task t where t.id = t_bt) = v_bat
      and (select t.container_id = v_case and t.counts_container from erp.count_task t where t.id = t_p)
      and (select pg.tolerance_absolute from erp.count_programme pg
            where pg.tenant_id = r.tenant_id and pg.code = 'cycle_a') = 2
      and (select pg.approval_chain_code from erp.count_programme pg
            where pg.tenant_id = r.tenant_id and pg.code = 'cycle_a') is not null
      and p3 = v_counter
      and exists (select 1 from erp.user_role g
                    join erp.role_permission rp on rp.role_id = g.role_id
                   where g.app_user_id = p3 and rp.permission_code = 'inventory.count')
      and not exists (select 1 from erp.user_role g
                        join erp.role_permission rp on rp.role_id = g.role_id
                       where g.app_user_id = p3 and rp.permission_code = 'inventory.adjust')
      and erp.count_posting_policy(r.entity_id, s_main)
            = '{"within_tolerance": "post", "self_post_within_tolerance": true}'::jsonb
      and erp.count_posting_policy(r.entity_id, s_hold)
            = '{"within_tolerance": "hold", "self_post_within_tolerance": true}'::jsonb
      and erp.count_posting_policy(r.entity_id, s_strict)
            = '{"within_tolerance": "post", "self_post_within_tolerance": false}'::jsonb,
      format('MAIN %s; HOLD %s; STRICT %s',
             erp.count_posting_policy(r.entity_id, s_main),
             erp.count_posting_policy(r.entity_id, s_hold),
             erp.count_posting_policy(r.entity_id, s_strict));

    -- 3. By default a count inside tolerance posts as it is recorded: through
    --    its adjustment, by the system's move, its lock released.
    v_fixture := 'recording A';
    v_status := erp.record_count(t_a, 101)::text;
    select string_agg(l.transition_code, ',' order by l.occurred_at, l.id) into v_log
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'count_task' and l.object_id = t_a
       and l.transition_code is not null;
    select l.guard_data -> 'derived' into v_guard from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'count_task' and l.object_id = t_a
       and l.transition_code = 'post';
    select count(*) into v_locks from erp.count_lock l
     where l.tenant_id = r.tenant_id and l.count_task_id = t_a and l.released_at is null;
    v_books := erp_test.count_books_agree();
    return query select 'by default a count inside tolerance posts as it is recorded, through its adjustment, as the system''s move',
      v_status = 'posted' and v_log = 'record_approved,post'
      and v_guard ->> 'fact' = 'erp.count_is_within_tolerance'
      and (select t.status::text || ' ' || (t.posted_at is not null)::text from erp.count_task t where t.id = t_a) = 'posted true'
      and erp.object_current_state('document',
            (select t.adjustment_document_id from erp.count_task t where t.id = t_a)) = 'posted'
      and (select sum(b.quantity) from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = i_a) = 101
      and v_locks = 0 and v_books = 'passed'
      and coalesce(current_setting('erp.deriving_move', true), '') = '',
      format('recorded %s; history %s; derived %s; %s live lock(s); books %s',
             v_status, v_log, coalesce(v_guard::text, 'nothing'), v_locks, v_books);

    -- 4. Before go-live the self-posting rule does not apply, so a site that
    --    holds the counter's own still posts it.
    v_fixture := 'recording S1';
    v_status := erp.record_count(t_s1, 99)::text;
    v_books := erp_test.count_books_agree();
    return query select 'before go-live, a site that holds the counter''s own count still posts it, because the rule it follows does not apply yet',
      v_status = 'posted'
      and (select t.counted_by from erp.count_task t where t.id = t_s1) = p1
      and (select sum(b.quantity) from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = i_s1) = 99
      and v_books = 'passed',
      format('recorded %s; books %s', v_status, v_books);

    -- Live from here.
    update erp.environment set is_live = true where tenant_id = r.tenant_id and is_self;

    -- 5. Live, the counter's own count inside tolerance posts itself, though
    --    the counter may not adjust stock: the post and the adjustment's
    --    moves are derived, recorded against the counter as not permitted.
    v_fixture := 'the counter recording B';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_status := erp.record_count(t_b, 98)::text;
    select l.guard_data -> 'derived' into v_guard from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'count_task' and l.object_id = t_b
       and l.transition_code = 'post';
    select l.guard_data -> 'derived' into v_guard2 from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'document'
       and l.object_id = (select t.adjustment_document_id from erp.count_task t where t.id = t_b)
       and l.transition_code = 'approve';
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_books := erp_test.count_books_agree();
    return query select 'live, the counter''s own count inside tolerance posts itself, though the counter may not adjust stock',
      erp.tenant_is_live(r.tenant_id)
      and v_status = 'posted'
      and (select t.counted_by from erp.count_task t where t.id = t_b) = p3
      and v_guard ->> 'fact' = 'erp.count_is_within_tolerance'
      and v_guard ->> 'permission' = 'inventory.adjust'
      and (v_guard ->> 'actor_permitted')::boolean is false
      and v_guard2 ->> 'fact' = 'erp.count_task_is_approved'
      and (select sum(b.quantity) from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = i_b) = 98
      and v_books = 'passed',
      format('recorded %s; post derived %s; adjustment approve derived %s; books %s',
             v_status, coalesce(v_guard::text, 'nothing'), coalesce(v_guard2 ->> 'fact', 'nothing'), v_books);

    -- 6. Live, an administrator's own count inside tolerance posts itself:
    --    CLOVEERP_COUNT_SELF_POSTING gives way inside tolerance.
    v_fixture := 'recording C';
    v_status := erp.record_count(t_c, 102)::text;
    v_books := erp_test.count_books_agree();
    return query select 'live, an administrator''s own count inside tolerance posts itself: the self-posting rule gives way inside tolerance',
      v_status = 'posted'
      and (select t.counted_by from erp.count_task t where t.id = t_c) = p1
      and (select t.status::text from erp.count_task t where t.id = t_c) = 'posted'
      and (select sum(b.quantity) from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = i_c) = 102
      and v_books = 'passed',
      format('recorded %s; books %s', v_status, v_books);

    -- 7. A site whose policy holds leaves every count inside tolerance
    --    approved for somebody to post, its variance and its want of one
    --    alike, and the system's post is not derivable for either.
    v_fixture := 'the counter recording H and H0';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_status := erp.record_count(t_h, 99)::text;
    v_status2 := erp.record_count(t_h0, 100)::text;
    -- Held, it is posted by hand as before, and not by the counter, who may
    -- not adjust stock.
    begin
      perform erp.post_count(t_h);
      v_err := 'posted';
    exception when others then v_err := left(sqlerrm, 200); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    perform set_config('erp.deriving_move', t_h::text || ':post', true);
    v_fact := erp.derived_move_fact('count_task', t_h, 'post');
    perform set_config('erp.deriving_move', t_h0::text || ':post', true);
    v_fact2 := erp.derived_move_fact('count_task', t_h0, 'post');
    perform set_config('erp.deriving_move', '', true);
    select count(*) into v_locks from erp.count_lock l
     where l.tenant_id = r.tenant_id and l.count_task_id in (t_h, t_h0) and l.released_at is null;
    select count(*) into v_n from erp.count_task t
     where t.id in (t_h, t_h0) and t.status = 'approved' and t.posted_at is null and t.adjustment_document_id is null;
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.post_count(t_h);
    perform erp.post_count(t_h0);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_books := erp_test.count_books_agree();
    return query select 'a site whose policy holds leaves every count inside tolerance approved for somebody to post, and it posts by hand as before',
      v_status = 'approved' and v_status2 = 'approved' and v_n = 2 and v_locks = 2
      and v_fact is null and v_fact2 is null
      and v_err like 'CLOVEERP_PERMISSION_DENIED:%'
      and (select string_agg(t.status::text || ':' || (t.adjustment_document_id is not null)::text, ',' order by t.variance)
             from erp.count_task t where t.id in (t_h, t_h0)) = 'posted:true,posted:false'
      and (select sum(b.quantity) from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = i_h) = 99
      and v_books = 'passed',
      format('recorded %s and %s; %s held, %s live lock(s); derivable %s / %s; the counter posting it: %s; books %s',
             v_status, v_status2, v_n, v_locks, coalesce(v_fact, 'no'), coalesce(v_fact2, 'no'), v_err, v_books);

    -- 8. A site that holds the counter's own: live, their count with a
    --    variance waits, and they may not post it; somebody else does. With
    --    no variance the rule never applied, and it posts.
    v_fixture := 'recording S2 and S0';
    v_status := erp.record_count(t_s2, 99)::text;
    v_status2 := erp.record_count(t_s0, 100)::text;
    perform set_config('erp.deriving_move', t_s2::text || ':post', true);
    v_fact := erp.derived_move_fact('count_task', t_s2, 'post');
    perform set_config('erp.deriving_move', '', true);
    begin
      perform erp.post_count(t_s2);
      v_err := 'posted';
    exception when others then v_err := left(sqlerrm, 200); end;
    v_status3 := (select t.status::text from erp.count_task t where t.id = t_s2);
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.post_count(t_s2);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_books := erp_test.count_books_agree();
    return query select 'a site that holds the counter''s own leaves it for somebody else once live, and posts one with no variance',
      v_status = 'approved' and v_fact is null
      and v_err like 'CLOVEERP_COUNT_SELF_POSTING:%' and v_status3 = 'approved'
      and (select t.status::text from erp.count_task t where t.id = t_s2) = 'posted'
      and v_status2 = 'posted'
      and (select t.adjustment_document_id from erp.count_task t where t.id = t_s0) is null
      and (select sum(b.quantity) from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = i_s2) = 99
      and v_books = 'passed',
      format('recorded %s, derivable %s; the counter posting it: %s; no variance recorded %s; books %s',
             v_status, coalesce(v_fact, 'no'), v_err, v_status2, v_books);

    -- 9. Outside tolerance nothing changes: it waits for its approver, the
    --    counter may approve it, the counter may not post it, somebody else
    --    posts it, and the system's post is not derivable for it.
    v_fixture := 'recording O';
    v_status := erp.record_count(t_o, 50)::text;
    select t.approval_request_id into v_req from erp.count_task t where t.id = t_o;
    select tk.id into v_task from erp.approval_task tk
     where tk.tenant_id = r.tenant_id and tk.approval_request_id = v_req
       and tk.status = 'pending' and tk.assignee_user_id = p1
     limit 1;
    perform erp.decide_approval_task(v_task, true, 'the shelf was checked');
    v_status2 := (select t.status::text from erp.count_task t where t.id = t_o);
    perform set_config('erp.deriving_move', t_o::text || ':post', true);
    v_fact := erp.derived_move_fact('count_task', t_o, 'post');
    perform set_config('erp.deriving_move', '', true);
    begin
      perform erp.post_count(t_o);
      v_err := 'posted';
    exception when others then v_err := left(sqlerrm, 200); end;
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.post_count(t_o);
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select string_agg(l.transition_code, ',' order by l.occurred_at, l.id) into v_log
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'count_task' and l.object_id = t_o
       and l.transition_code is not null;
    v_books := erp_test.count_books_agree();
    return query select 'outside tolerance nothing changes: it waits, is approved, is not posted by its counter, and is posted by somebody else',
      v_status = 'pending_approval' and v_status2 = 'approved' and v_fact is null
      and v_err like 'CLOVEERP_COUNT_SELF_POSTING:%'
      and v_log = 'record_pending,approve,post'
      and (select l.guard_data -> 'derived' from erp.state_transition_log l
            where l.tenant_id = r.tenant_id and l.object_type = 'count_task' and l.object_id = t_o
              and l.transition_code = 'post') is null
      and (select sum(b.quantity) from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = i_o) = 50
      and v_books = 'passed',
      format('recorded %s, then %s; derivable %s; the counter posting it: %s; history %s; books %s',
             v_status, v_status2, coalesce(v_fact, 'no'), v_err, v_log, v_books);

    -- 10a–c. The system's post of stock the company does not own, of a
    --        batch and of a case: each posts as it is recorded, against the
    --        owner, the batch or the case, and the books agree after each.
    v_fixture := 'the counter recording K, consigned';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_status := erp.record_count(t_k, 4)::text;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_books := erp_test.count_books_agree();
    return query select 'the system''s post of consigned stock posts against the owner''s position, with no cost and no journal',
      v_status = 'posted'
      and exists (select 1 from erp.stock_movement m
                   join erp.count_task t on t.tenant_id = m.tenant_id and t.adjustment_document_id = m.document_id
                  where t.id = t_k and m.owner_party_id = v_sup and m.cost_minor is null and m.quantity = 1)
      and not exists (select 1 from erp.journal j
                       join erp.event ev on ev.tenant_id = j.tenant_id and ev.id = j.source_event_id
                       join erp.stock_movement m on m.tenant_id = ev.tenant_id and m.movement_uid = ev.aggregate_id
                       join erp.count_task t on t.tenant_id = m.tenant_id and t.adjustment_document_id = m.document_id
                      where t.id = t_k)
      and (select sum(b.quantity) from erp.stock_balance b
            where b.tenant_id = r.tenant_id and b.item_id = i_k and b.owner_party_id = v_sup) = 4
      and v_books = 'passed',
      format('recorded %s; books %s', v_status, v_books);

    v_fixture := 'the counter recording BT, by batch';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_status := erp.record_count(t_bt, 5)::text;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_books := erp_test.count_books_agree();
    return query select 'the system''s post of a batch posts in that batch, costed, and the books agree',
      v_status = 'posted'
      and exists (select 1 from erp.stock_movement m
                   join erp.count_task t on t.tenant_id = m.tenant_id and t.adjustment_document_id = m.document_id
                  where t.id = t_bt and m.batch_id = v_bat and m.quantity = 1 and m.cost_minor > 0)
      and (select sum(b.quantity) from erp.stock_balance b
            where b.tenant_id = r.tenant_id and b.item_id = i_bt and b.batch_id = v_bat) = 5
      and v_books = 'passed',
      format('recorded %s; books %s', v_status, v_books);

    v_fixture := 'the counter recording P, by the case';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_status := erp.record_count(t_p, 4)::text;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_books := erp_test.count_books_agree();
    return query select 'the system''s post of a count by the case posts in the case, and the books agree',
      v_status = 'posted'
      and exists (select 1 from erp.stock_movement m
                   join erp.count_task t on t.tenant_id = m.tenant_id and t.adjustment_document_id = m.document_id
                  where t.id = t_p and m.container_id = v_case and m.to_location_id = v_recv and m.quantity = 1)
      and (select sum(b.quantity) from erp.stock_balance b
            where b.tenant_id = r.tenant_id and b.item_id = i_p and b.container_id = v_case) = 4
      and v_books = 'passed',
      format('recorded %s; books %s', v_status, v_books);

    -- 10. A negative figure is refused, and nothing is recorded.
    v_fixture := 'the counter recording N below nothing';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_err := null; v_hint := null;
    begin
      perform erp.record_count(t_n, -1);
      v_err := 'recorded';
    exception when others then
      get stacked diagnostics v_err = message_text, v_hint = pg_exception_hint;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    return query select 'a count of less than nothing is refused, and says to count again',
      v_err like 'CLOVEERP_COUNT_QUANTITY_NEGATIVE:%' and v_hint like 'Count the place again%'
      and (select t.status::text || ' ' || coalesce(t.counted_quantity::text, 'uncounted')
             from erp.count_task t where t.id = t_n) = 'open uncounted'
      and (select sum(b.quantity) from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = i_n) = 100,
      coalesce(v_err, 'nothing');

    -- 11. A post refused for good keeps the count: recorded and approved,
    --     held for somebody to post, with the refusal's code and message on
    --     the task, and nothing written to either ledger.
    v_fixture := 'recording N, whose post is refused';
    update erp.count_task set location_id = null where id = t_n;
    select coalesce(max(m.id), 0) into v_mark from erp.stock_movement m;
    v_status := erp.record_count(t_n, 101)::text;
    select count(*) into v_locks from erp.count_lock l
     where l.tenant_id = r.tenant_id and l.count_task_id = t_n and l.released_at is null;
    select string_agg(l.transition_code, ',' order by l.occurred_at, l.id) into v_log
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'count_task' and l.object_id = t_n
       and l.transition_code is not null;
    select count(*) into v_n2 from erp.stock_movement m
     where m.tenant_id = r.tenant_id and m.id > v_mark;
    select count(*) into v_n3 from erp.document d
     where d.tenant_id = r.tenant_id and d.attributes ->> 'count_task_id' = t_n::text;
    v_books := erp_test.count_books_agree();
    return query select 'a post refused for good keeps the count recorded and approved for somebody to post, with the refusal on the task',
      v_status = 'approved'
      and (select t.status::text || ' ' || trim_scale(t.counted_quantity)::text from erp.count_task t where t.id = t_n) = 'approved 101'
      and (select t.post_held_reason from erp.count_task t where t.id = t_n) like 'post_refused: 23502 CLOVEERP_COUNT_HAS_NO_PLACE:%'
      and v_log = 'record_approved'
      and v_locks = 1 and v_n2 = 0 and v_n3 = 0
      and coalesce(current_setting('erp.deriving_move', true), '') = ''
      and v_books = 'passed',
      format('recorded %s; held for %s; history %s; %s live lock(s), %s movement(s), %s adjustment(s); books %s',
             v_status, left(coalesce((select t.post_held_reason from erp.count_task t where t.id = t_n), 'nothing'), 120),
             v_log, v_locks, v_n2, v_n3, v_books);
    update erp.count_task set location_id = v_recv where id = t_n;

    -- 12. A post that meets a conflict that clears by itself refuses the
    --     record, keeping the conflict's code so it is tried again. The post
    --     is stubbed to meet one, within the block.
    v_fixture := 'recording T, whose post meets a conflict';
    v_err := null; v_state := null; v_detail := null; v_status := null;
    begin
      execute $stub$
        create or replace function erp.raise_count_adjustment(p_task_id uuid)
        returns uuid
        language plpgsql
        set search_path = ''
        as $body$
        begin
          -- A stub for erp_test.count_autopost_suite, rolled back with it.
          raise exception 'could not serialize access due to concurrent update' using errcode = '40001';
        end
        $body$
      $stub$;
      perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
      begin
        perform erp.record_count(t_t, 99);
        v_err := 'recorded';
      exception when others then
        get stacked diagnostics v_err = message_text, v_state = returned_sqlstate, v_detail = pg_exception_detail;
      end;
      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
      v_status := (select t.status::text || ' ' || coalesce(t.counted_quantity::text, 'uncounted')
                     from erp.count_task t where t.id = t_t);
      raise exception 'CLOVEERP_ROUTE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_ROUTE_UNDO' then v_err := 'stopped: ' || left(sqlerrm, 200); end if;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    return query select 'a post that meets a transient conflict refuses the record with the conflict''s own code, so it is recorded again',
      v_err like 'CLOVEERP_COUNT_AUTOPOST_FAILED:%' and v_state = '40001'
      and v_detail like 'SQLSTATE 40001%' and v_status = 'open uncounted',
      format('%s [%s] %s; task %s', left(coalesce(v_err, 'nothing'), 140), v_state, v_detail, v_status);

    -- 13. A task raised before the lifecycle posts as it is recorded too, by
    --     its column.
    v_fixture := 'the counter recording L';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_status := erp.record_count(t_l, 101)::text;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_books := erp_test.count_books_agree();
    return query select 'a task raised before its organisation took the lifecycle posts as it is recorded, by its column',
      v_status = 'posted'
      and (select t.status::text from erp.count_task t where t.id = t_l) = 'posted'
      and erp.object_current_state('document',
            (select t.adjustment_document_id from erp.count_task t where t.id = t_l)) = 'posted'
      and not exists (select 1 from erp.state_transition_log l
                       where l.object_type = 'count_task' and l.object_id = t_l and l.transition_code is not null)
      and (select sum(b.quantity) from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = i_l) = 101
      and v_books = 'passed',
      format('recorded %s; books %s', v_status, v_books);

    -- 14. An organisation with no stock adjustment type posts as it is
    --     recorded by the movement the post always wrote. Rolled back.
    v_fixture := 'recording R with no stock adjustment type';
    v_err := null; v_status := null; v_n := null; v_n2 := null; v_books := null;
    begin
      -- Retyped as an organisation not yet live may, within the block.
      update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
      update erp.document_type set status = 'inactive'
       where tenant_id = r.tenant_id and code = 'stock_adjustment';
      select coalesce(max(m.id), 0) into v_mark from erp.stock_movement m;
      perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
      v_status := erp.record_count(t_r, 99)::text;
      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
      select count(*),
             count(*) filter (where m.reason_code = 'count_variance' and m.document_id is null
                                and m.movement_type = 'count_adjustment' and m.quantity = 1
                                and m.cost_minor > 0)
        into v_n, v_n2
        from erp.stock_movement m where m.tenant_id = r.tenant_id and m.id > v_mark;
      v_state := (select t.status::text || ' ' || coalesce(t.adjustment_document_id::text, 'no adjustment')
                    from erp.count_task t where t.id = t_r);
      v_books := erp_test.count_books_agree();
      raise exception 'CLOVEERP_ROUTE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_ROUTE_UNDO' then v_err := left(sqlerrm, 200); end if;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    return query select 'an organisation with no stock adjustment type posts a count inside tolerance as it is recorded, by the movement it always did',
      v_err is null and v_status = 'posted' and v_n = 1 and v_n2 = 1
      and v_state = 'posted no adjustment' and v_books = 'passed'
      and (select dt.status::text from erp.document_type dt
            where dt.tenant_id = r.tenant_id and dt.code = 'stock_adjustment') = 'active'
      and erp.tenant_is_live(r.tenant_id),
      coalesce('stopped: ' || v_err,
        format('recorded %s; %s movement(s), %s by the old route and costed; task %s; books %s',
               v_status, v_n, v_n2, v_state, v_books));

    -- 15. The policy is proposed as a change, per site, and a value outside
    --     its shape is refused.
    v_fixture := 'proposing the policy';
    begin
      perform public.erp_propose_count_posting_policy(v_ecode, 'MAIN',
        jsonb_build_object('within_tolerance', 'sometimes'), null);
      v_err := 'proposed';
    exception when others then v_err := left(sqlerrm, 160); end;
    begin
      perform public.erp_propose_count_posting_policy(v_ecode, 'MAIN',
        jsonb_build_object('self_post_within_tolerance', 'yes'), null);
      v_err2 := 'proposed';
    exception when others then v_err2 := left(sqlerrm, 160); end;
    v_cs := public.erp_propose_count_posting_policy(v_ecode, 'MAIN',
      jsonb_build_object('within_tolerance', 'hold', 'self_post_within_tolerance', false), null);
    begin
      perform public.erp_propose_count_posting_policy('ZZ-NOT-ITS-COMPANY', 'MAIN',
        jsonb_build_object('within_tolerance', 'hold'), null);
      v_err3 := 'proposed';
    exception when others then v_err3 := left(sqlerrm, 160); end;
    return query select 'the count posting policy is proposed per site as a change, and a value outside its shape, or a site under another company, is refused',
      v_err like 'CLOVEERP_POLICY_VALUE_INVALID:%' and v_err2 like 'CLOVEERP_POLICY_VALUE_INVALID:%'
      and v_err3 like 'CLOVEERP_POLICY_SCOPE_DISAGREES:%'
      and exists (select 1 from erp.change_set_item i
                   where i.id = v_cs and i.object_key = format('inventory.count_posting|%s|MAIN', v_ecode))
      and erp.count_posting_policy(r.entity_id, s_main)
            = '{"within_tolerance": "post", "self_post_within_tolerance": true}'::jsonb,
      v_err || ' / ' || v_err2 || ' / ' || v_err3;

    -- 16. Counted short again and again: once live, what the system posts
    --     unattended at a place is bounded across counts. The first round
    --     posts; the second, which would take the place past the tolerance
    --     in all, is held for a second person with its reason, and the
    --     ledger shows only the first.
    v_fixture := 'the counter counting W short twice';
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    v_status := erp.record_count(t_w1, (select t.expected_quantity + t.movement_during - t.committed_quantity
                                          from erp.count_task t where t.id = t_w1) - 2)::text;
    perform public.erp_raise_count_tasks('cycle_a');
    select t.id into t_w2 from erp.count_task t
     where t.tenant_id = r.tenant_id and t.item_id = i_w and t.status = 'open';
    v_status2 := erp.record_count(t_w2, (select t.expected_quantity + t.movement_during - t.committed_quantity
                                           from erp.count_task t where t.id = t_w2) - 2)::text;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    select count(*) into v_n from erp.stock_movement m
     where m.tenant_id = r.tenant_id and m.item_id = i_w and m.reason_code = 'COUNT_VARIANCE';
    select count(*) into v_locks from erp.count_lock l
     where l.tenant_id = r.tenant_id and l.count_task_id = t_w2 and l.released_at is null;
    v_books := erp_test.count_books_agree();
    return query select 'counted short again at the same place, the round that would take it past the tolerance in all is held for a second person, and the ledger shows only the first',
      v_status = 'posted' and v_status2 = 'approved'
      and (select t.post_held_reason from erp.count_task t where t.id = t_w2) like 'held_cumulative: with 1 count(s)%comes to -4,%'
      and (select t.posted_by_system from erp.count_task t where t.id = t_w1)
      and v_n = 1 and v_locks = 1
      and (select sum(b.quantity) from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = i_w) = 98
      and v_books = 'passed',
      format('rounds %s, %s; held for %s; %s movement(s); books %s', v_status, v_status2,
             left(coalesce((select t.post_held_reason from erp.count_task t where t.id = t_w2), 'nothing'), 140),
             v_n, v_books);

    -- 17. A person's post at the place starts the bound afresh: the held
    --     round is posted by the second administrator, and the next round
    --     posts itself again.
    v_fixture := 'posting W by hand and counting it again';
    perform set_config('request.jwt.claims', json_build_object('sub', a2)::text, true);
    perform erp.post_count(t_w2);
    perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
    perform public.erp_raise_count_tasks('cycle_a');
    select t.id into t_w3 from erp.count_task t
     where t.tenant_id = r.tenant_id and t.item_id = i_w and t.status = 'open';
    v_status := erp.record_count(t_w3, (select t.expected_quantity + t.movement_during - t.committed_quantity
                                          from erp.count_task t where t.id = t_w3) - 2)::text;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    v_books := erp_test.count_books_agree();
    return query select 'a person''s post at the place starts the bound afresh, and the next count inside tolerance posts itself',
      v_status = 'posted'
      and (select string_agg(t.posted_by_system::text, ',' order by t.posted_at) from erp.count_task t
            where t.tenant_id = r.tenant_id and t.item_id = i_w) = 'true,false,true'
      and (select sum(b.quantity) from erp.stock_balance b where b.tenant_id = r.tenant_id and b.item_id = i_w) = 94
      and v_books = 'passed',
      format('third round %s; posted by the system %s; books %s', v_status,
             (select string_agg(t.posted_by_system::text, ',' order by t.posted_at) from erp.count_task t
               where t.tenant_id = r.tenant_id and t.item_id = i_w), v_books);

    -- 18. A policy value outside its shape holds, fails closed: "POST" is
    --     not post, and "true" as a string is not true. Rolled back.
    v_fixture := 'recording under a policy value the door would have refused';
    v_err := null; v_status := null; v_status2 := null; v_log := null; v_hint := null;
    begin
      select t.id into j1 from erp.count_task t
       where t.tenant_id = r.tenant_id and t.item_id = i_a and t.status = 'open';
      select t.id into j2 from erp.count_task t
       where t.tenant_id = r.tenant_id and t.item_id = i_c and t.status = 'open';
      update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
      perform erp.set_config_value('inventory.count_posting',
        jsonb_build_object('within_tolerance', 'POST'), null, null, r.entity_id, s_main, 'the count autopost suite');
      update erp.environment set is_live = true where tenant_id = r.tenant_id and is_self;
      perform set_config('request.jwt.claims', json_build_object('sub', a3)::text, true);
      v_status := erp.record_count(j1, (select t.expected_quantity + t.movement_during - t.committed_quantity
                                          from erp.count_task t where t.id = j1) + 1)::text;
      perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
      update erp.environment set is_live = false where tenant_id = r.tenant_id and is_self;
      perform erp.set_config_value('inventory.count_posting',
        jsonb_build_object('within_tolerance', 'post', 'self_post_within_tolerance', 'true'),
        null, null, r.entity_id, s_main, 'the count autopost suite');
      update erp.environment set is_live = true where tenant_id = r.tenant_id and is_self;
      v_status2 := erp.record_count(j2, (select t.expected_quantity + t.movement_during - t.committed_quantity
                                           from erp.count_task t where t.id = j2) - 1)::text;
      v_log := (select t.post_held_reason from erp.count_task t where t.id = j1);
      v_hint := (select t.post_held_reason from erp.count_task t where t.id = j2);
      raise exception 'CLOVEERP_ROUTE_UNDO';
    exception when others then
      if sqlerrm <> 'CLOVEERP_ROUTE_UNDO' then v_err := left(sqlerrm, 200); end if;
    end;
    perform set_config('request.jwt.claims', json_build_object('sub', a1)::text, true);
    return query select 'a policy value outside its shape holds the count rather than posting it',
      v_err is null and v_status = 'approved' and v_status2 = 'approved'
      and v_log like 'held_by_policy:%' and v_hint like 'held_own_count:%'
      and erp.tenant_is_live(r.tenant_id),
      coalesce('stopped: ' || v_err, format('"POST": %s, %s; "true": %s, %s', v_status, v_log, v_status2, v_hint));

    -- 19. Every count posted as it was recorded is the system's post, and
    --     every other was somebody's.
    select count(*) filter (where l.guard_data #>> '{derived,fact}' = 'erp.count_is_within_tolerance'),
           count(*) filter (where l.guard_data -> 'derived' is null)
      into v_n, v_n2
      from erp.state_transition_log l
     where l.tenant_id = r.tenant_id and l.object_type = 'count_task' and l.transition_code = 'post';
    return query select 'each count posted as it was recorded was posted by the system, and each posted by hand by its poster',
      v_n = 10 and v_n2 = 5,
      format('%s derived post(s), %s by hand', v_n, v_n2);

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
  passed := not exists (select 1 from erp.tenant t where t.code = 'zz-cap-' || v_hex)
            and coalesce(current_setting('erp.deriving_move', true), '') = ''
            and pg_get_functiondef('erp.raise_count_adjustment(uuid)'::regprocedure) not like '%A stub for erp_test.count_autopost_suite%';
  detail := 'the organisation, its sites, policies, counts, adjustments and postings rolled back, no move named, and the post its own again';
  return next;
end;
$function$;

revoke all on function erp_test.count_autopost_suite() from public, anon;

create or replace function erp_test.assert_count_autopost_suite()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_failed integer;
  v_total  integer;
  v_detail text;
  v_ended  text;
begin
  select count(*) filter (where not coalesce(s.passed, false)),
         count(*),
         string_agg(s.case_name || ': ' || s.detail, E'\n  ') filter (where not coalesce(s.passed, false)),
         max(s.detail) filter (where s.case_name = 'the suite ran to its end')
    into v_failed, v_total, v_detail, v_ended
    from erp_test.count_autopost_suite() s;
  -- Failures first, so a suite that stopped part way says where.
  if v_failed > 0 then
    raise exception 'CLOVEERP_COUNT_AUTOPOST_SUITE_FAILED: %/% case(s) failed%', v_failed, v_total,
      E'\n  ' || v_detail
      using hint = 'A count inside tolerance posts as it is recorded unless the site''s count posting policy holds it, and outside tolerance nothing changed. Read the case that failed.';
  end if;
  if v_total <> 23 then
    raise exception 'CLOVEERP_COUNT_AUTOPOST_SUITE_SHRANK: % case(s), expected 23; the fixture stopped %', v_total,
      coalesce(v_ended, 'nowhere')
      using hint = 'A suite that loses a case reports success. Restore the case or re-pin the count.';
  end if;
end;
$$;

revoke all on function erp_test.assert_count_autopost_suite() from public, anon;

comment on function erp_test.assert_count_autopost_suite() is
  'A count inside tolerance posts as it is recorded, by the system''s move, the counter''s own included '
  'once live and though the counter may not adjust stock, consigned, batch and packed stock alike; a '
  'site whose inventory.count_posting holds leaves it for somebody to post, one that holds the '
  'counter''s own does so once live, and a value outside the policy''s shape holds; once live the '
  'variance posted unattended at a place is bounded across counts until a person posts there; outside '
  'tolerance nothing changes; a negative count is refused; a post refused for good keeps the count '
  'approved with the reason, and a transient conflict refuses the record; a task raised before '
  'the lifecycle and an organisation with no stock adjustment type post as recorded too; the policy is '
  'proposed per site; the books agree after each (20260927300000).';

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
