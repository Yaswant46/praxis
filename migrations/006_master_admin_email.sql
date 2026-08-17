-- =====================================================================
--  006 · Master-admin email
--  Point the master-admin helper at ross.harvey92@gmail.com. Logging in as
--  GM with this address unlocks the Master Admin view (all cohorts) and is
--  enforced at the RLS layer via praxis_is_master_admin(). Keep in sync with
--  SUPERUSER_EMAIL in app.html.
--  Idempotent — safe to re-run.
-- =====================================================================

CREATE OR REPLACE FUNCTION praxis_is_master_admin() RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
  SELECT praxis_caller_email() = 'ross.harvey92@gmail.com';
$$;
