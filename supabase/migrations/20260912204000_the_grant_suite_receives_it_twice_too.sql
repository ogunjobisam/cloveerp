-- The second call site of the same mistake.
--
-- 20260912190000 took the hand-driven receive_all out of the demonstration
-- seeder, because posting a receipt now advances the order itself. The grant
-- suite drives the same spine, one line apart, and had the same line:
--
--   erp_test.assert_grant_suite — the spine runs through the invoker doors as
--   authenticated: CLOVEERP_TRANSITION_NOT_PERMITTED: receive_all is not a
--   declared transition out of received for document
--
-- The case exists to prove that a real caller, holding grants and nothing
-- else, can walk a purchase order from raised to received through the public
-- doors. It still does. What it no longer does is take a step the product has
-- already taken for it — which is a better proof, not a weaker one: the order
-- reaching Received without being pushed is the thing being claimed.
--
-- The journal and movement counts after it are untouched, so the case still
-- fails if the receipt posts nothing.

do $grant$
declare
  v_def text;
  v_new text;
begin
  v_def := pg_get_functiondef('erp_test.grant_suite()'::regprocedure);

  v_new := replace(v_def,
    E'      perform public.erp_transition_document(v_grn, ''post'', ''grant suite'');\n      perform public.erp_transition_document(v_po, ''receive_all'', ''grant suite'');\n',
    E'      perform public.erp_transition_document(v_grn, ''post'', ''grant suite'');\n');

  if v_new = v_def then
    raise exception 'CLOVEERP_GRANT_SUITE_UNRECOGNISED: erp_test.grant_suite() does not hold the hand-driven receive_all this migration removes';
  end if;

  execute v_new;
end
$grant$;
