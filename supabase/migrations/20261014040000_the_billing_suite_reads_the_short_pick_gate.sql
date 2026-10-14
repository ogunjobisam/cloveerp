-- The billing suite reads the short pick's gate.
--
-- 20261014020000 let a scanner confirm a short pick as it confirms a pick:
-- erp.commit_allocation now asks erp.scan_confirms('sales.despatch',
-- array['pick', 'short_pick'], ...). erp_test.billing_matches_the_list_suite
-- proves the confirmation is asked by reading that call's text, and looked
-- for array['pick'] closed after one element, so it failed although the gate
-- is the same gate with one more task it confirms. It now reads the call as
-- written; the behaviour it then proves (false outside the drain) is
-- unchanged.

do $billing$
declare
  v_sig  constant text := 'erp_test.billing_matches_the_list_suite()';
  v_def  text := pg_get_functiondef(v_sig::regprocedure);
  v_old  constant text := $o$ok_gates := position('erp.scan_confirms(''sales.despatch'', array[''pick'']' in$o$;
  v_new  constant text := $n$ok_gates := position('erp.scan_confirms(''sales.despatch'', array[''pick'', ''short_pick'']' in$n$;
  v_hits integer := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
begin
  if position($n$array[''pick'', ''short_pick'']$n$ in v_def) > 0 then
    return;
  end if;
  if v_hits <> 1 then
    raise exception 'CLOVEERP_ANCHOR_MOVED: % gate anchor found % time(s)', v_sig, v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$billing$;

-- The generators, which are idempotent and run at the end of every migration.
select erp.apply_row_security();
select erp.apply_execute_grants();
select erp.assert_no_public_execute();
