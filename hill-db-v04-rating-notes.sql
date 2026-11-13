-- CERIC-T v0.4, step 17: a note appended to a finalized rating.
-- Decided by Gene on 2026-11-12:
--   * either coder of the Claim may add a note; the other coder's agreement is not needed;
--   * the rating itself stays locked: a note is added beside it, and never changes it;
--   * notes are added only, never edited or removed, by anyone;
--   * agents cannot write or read them; every note is in the change log.
-- Applies to Claims finalized under CERIC-T v0.4. Round-one (v0.3) records stay as they are.
-- No question wording in this file.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE hill_owner;

CREATE TABLE tracker.rating_notes (
  note_id   serial PRIMARY KEY,
  claim_id  text NOT NULL REFERENCES tracker.reconciled_claims,
  added_by  int NOT NULL REFERENCES admin.people,
  added_at  timestamptz NOT NULL DEFAULT now(),
  note      text NOT NULL CHECK (length(trim(note)) > 0)
);
COMMENT ON TABLE tracker.rating_notes IS 'Notes appended to a finalized v0.4 rating by a coder of the Claim. Added only; never edited or removed. No sign-in can write this table directly; use tracker.add_rating_note().';
ALTER TABLE tracker.rating_notes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON tracker.rating_notes FROM PUBLIC;

CREATE FUNCTION tracker.rating_notes_append_only() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'Notes on a rating are added only; they cannot be changed or removed' USING ERRCODE = 'insufficient_privilege';
END $$;
CREATE TRIGGER rating_notes_append_only BEFORE UPDATE OR DELETE ON tracker.rating_notes
  FOR EACH ROW EXECUTE FUNCTION tracker.rating_notes_append_only();
CREATE TRIGGER rating_notes_no_truncate BEFORE TRUNCATE ON tracker.rating_notes
  FOR EACH STATEMENT EXECUTE FUNCTION tracker.rating_notes_append_only();
CREATE TRIGGER zz_log_change AFTER INSERT ON tracker.rating_notes
  FOR EACH ROW EXECUTE FUNCTION admin.log_change();

CREATE FUNCTION tracker.add_rating_note(p_claim text, p_note text) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE me int := admin.me(); pv text; n int;
BEGIN
  IF admin.my_login_role() IS DISTINCT FROM 'coder' THEN
    RAISE EXCEPTION 'Only a coder of the Claim can add a note to its rating' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT protocol_version INTO pv FROM tracker.reconciled_claims WHERE claim_id = p_claim;
  IF NOT FOUND THEN RAISE EXCEPTION 'Claim % is not finalized; a note can be added only to a finalized rating', p_claim USING ERRCODE = 'check_violation'; END IF;
  IF pv <> 'CERIC-T v0.4' THEN
    RAISE EXCEPTION 'Notes can be added to CERIC-T v0.4 ratings only; % records stay as they are', pv USING ERRCODE = 'check_violation';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM tracker.codings WHERE claim_id = p_claim AND coder_id = me AND status = 'submitted') THEN
    RAISE EXCEPTION 'Only a coder of % can add a note to its rating', p_claim USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF coalesce(length(trim(p_note)), 0) = 0 THEN RAISE EXCEPTION 'The note is empty' USING ERRCODE = 'check_violation'; END IF;
  INSERT INTO tracker.rating_notes (claim_id, added_by, note) VALUES (p_claim, me, trim(p_note)) RETURNING note_id INTO n;
  RETURN n;
END $$;

-- Who may read: the lead, and anyone assigned to the Claim.
CREATE FUNCTION tracker.rating_notes_list(p_claim text)
RETURNS TABLE (note_id int, claim_id text, added_by int, added_by_name text, added_at timestamptz, note text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE rl text := admin.my_login_role(); me int := admin.me();
BEGIN
  IF rl IS NULL OR rl NOT IN ('lead','coder','tiebreak') THEN RAISE EXCEPTION 'Lead or coder only' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF rl <> 'lead' AND NOT EXISTS (SELECT 1 FROM tracker.assignments a WHERE a.claim_id = p_claim AND a.coder_id = me)
     AND NOT EXISTS (SELECT 1 FROM tracker.tiebreak_assignments t WHERE t.claim_id = p_claim AND t.person_id = me) THEN
    RAISE EXCEPTION 'You are not assigned to %', p_claim USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN QUERY SELECT n.note_id, n.claim_id, n.added_by, p.name, n.added_at, n.note
               FROM tracker.rating_notes n JOIN admin.people p ON p.person_id = n.added_by
               WHERE n.claim_id = p_claim ORDER BY n.note_id;
END $$;

-- Published with the rating, under the same conditions (study released; ratings switched on).
CREATE VIEW tracker.public_rating_notes AS
SELECT n.claim_id, n.added_at::date AS added_on, n.note
FROM tracker.rating_notes n JOIN tracker.public_ratings r USING (claim_id);

REVOKE ALL ON FUNCTION tracker.add_rating_note(text, text), tracker.rating_notes_list(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tracker.add_rating_note(text, text) TO hill_coder;
GRANT EXECUTE ON FUNCTION tracker.rating_notes_list(text) TO hill_lead, hill_coder, hill_tiebreak;
GRANT SELECT ON tracker.public_rating_notes TO hill_lead, hill_publisher;
COMMIT;
