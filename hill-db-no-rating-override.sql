-- HiLL database: no rating or severity override under CERIC-T v0.3 (decided by Gene on 2026-11-10).
-- Applied on top of hill-db-rating-scale.sql. Run once as a database administrator who is a member of hill_owner.
--
--   * Under v0.3 a coder cannot set a rating or severity of their own on a coding. The coding carries the
--     rating and severity the rules give, written at submission by tracker.submit_coding().
--   * Element evaluations can still differ from the proposed ones, with an override note, as before.
--   * Codings made under v0.2 keep the v0.2 rules.
-- No question wording in this file.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE hill_owner;

CREATE FUNCTION tracker.no_rating_override() RETURNS trigger
LANGUAGE plpgsql SET search_path = pg_catalog, tracker AS $$
BEGIN
  IF NEW.protocol_version <> 'CERIC-T v0.2' AND NEW.status = 'draft'
     AND (NEW.final_rating IS NOT NULL OR NEW.final_severity IS NOT NULL) THEN
    RAISE EXCEPTION 'Under % the rating and severity cannot be overridden; they follow from the evaluations and the CER summary', NEW.protocol_version
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
COMMENT ON FUNCTION tracker.no_rating_override() IS
  'Refuses a coder-set rating or severity on a draft coding under v0.3 and later; submit_coding() writes the derived ones.';

CREATE TRIGGER no_rating_override BEFORE INSERT OR UPDATE ON tracker.codings
  FOR EACH ROW EXECUTE FUNCTION tracker.no_rating_override();

COMMIT;
