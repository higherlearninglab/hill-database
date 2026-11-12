-- HiLL database: a tie-breaker cannot be someone assigned to code the Claim (found while building the lead view, 2026-11-10).
-- Applied on top of hill-db-no-rating-override.sql. Run once as a database administrator who is a member of hill_owner.
--
--   * Before this, naming a tie-breaker was refused only if that person had already started a coding of the Claim.
--     A person assigned to code it, but who had not started, could be named. Deciding was still refused later.
--   * Now naming is refused for anyone assigned to code the Claim, and a Claim's tie-breaker cannot be assigned to code it.
-- No question wording in this file.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE hill_owner;

CREATE OR REPLACE FUNCTION tracker.assign_tiebreak(p_claim text, p_person int) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
BEGIN
  IF admin.my_login_role() NOT IN ('lead','admin') THEN RAISE EXCEPTION 'Lead only' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF tracker.is_coder_of(p_claim, p_person)
     OR EXISTS (SELECT 1 FROM tracker.assignments WHERE claim_id = p_claim AND coder_id = p_person) THEN
    RAISE EXCEPTION 'A tie-breaker cannot be a coder of the claim';
  END IF;
  INSERT INTO tracker.tiebreak_assignments (claim_id, person_id, assigned_by) VALUES (p_claim, p_person, admin.me());
END $$;

CREATE FUNCTION tracker.guard_assignment_tiebreak() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM tracker.tiebreak_assignments WHERE claim_id = NEW.claim_id AND person_id = NEW.coder_id) THEN
    RAISE EXCEPTION 'The tie-breaker of claim % cannot be assigned to code it', NEW.claim_id USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER guard_assignment_tiebreak BEFORE INSERT ON tracker.assignments
  FOR EACH ROW EXECUTE FUNCTION tracker.guard_assignment_tiebreak();

COMMIT;
