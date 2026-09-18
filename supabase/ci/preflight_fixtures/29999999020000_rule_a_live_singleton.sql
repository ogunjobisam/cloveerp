-- Rule A. erp_test.commercial_renewal_suite() designates its own throwaway
-- tenant as the platform's organisation and does not say why, so on a database
-- that already has one it refuses. An empty build has none, so this is green on
-- every build and can never be green on a deploy.

select erp_test.assert_commercial_renewal_suite();
