-- CERIC-T v0.4, part 5 of the build: correcting an entry mistake in a submitted coding.
-- Decided by Gene on 2026-11-11:
--   * the coder asks, with a written reason;
--   * another person approves: the lead, or a coder assigned to the same Claim, never the coder who asked
--     (Adam approves Gene's, Gene approves Adam's). The approver sees the reason, not the answers;
--   * only before reconciliation has started on the Claim;
--   * the original answers are kept, and the request, the decision and the changes are all logged;
--   * agents cannot ask, approve or see.
-- Applies to v0.4 codings only. Round-one (v0.3) records stay locked.
-- No question wording in this file.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE hill_owner;

CREATE TABLE tracker.coding_corrections (
  correction_id serial PRIMARY KEY,
  coding_id    int NOT NULL REFERENCES tracker.codings,
  claim_id     text NOT NULL REFERENCES tracker.claims,
  requested_by int NOT NULL REFERENCES admin.people,
  requested_at timestamptz NOT NULL DEFAULT now(),
  reason       text NOT NULL CHECK (length(trim(reason)) > 0),
  other_coding_submitted boolean NOT NULL,
  status       text NOT NULL DEFAULT 'requested' CHECK (status IN ('requested','approved','refused','completed')),
  decided_by   int REFERENCES admin.people,
  decided_at   timestamptz,
  decision_reason text,
  original     jsonb,
  completed_at timestamptz,
  CHECK (decided_by IS NULL OR decided_by <> requested_by),
  CHECK ((status = 'requested') = (decided_by IS NULL)),
  CHECK (status NOT IN ('approved','completed') OR original IS NOT NULL)
);
COMMENT ON TABLE tracker.coding_corrections IS 'Requests to correct an entry mistake in a submitted v0.4 coding. No sign-in can read or write this table directly; use the functions.';
COMMENT ON COLUMN tracker.coding_corrections.other_coding_submitted IS 'Whether another coding of the Claim was already submitted, and so visible to the coder, when the correction was asked for.';
COMMENT ON COLUMN tracker.coding_corrections.original IS 'The coding, its answers and its element evaluations as they stood before the correction.';
CREATE UNIQUE INDEX one_open_correction ON tracker.coding_corrections (coding_id) WHERE status IN ('requested','approved');
ALTER TABLE tracker.coding_corrections ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON tracker.coding_corrections FROM PUBLIC;
CREATE TRIGGER zz_log_change AFTER INSERT OR UPDATE OR DELETE ON tracker.coding_corrections
  FOR EACH ROW EXECUTE FUNCTION admin.log_change();

CREATE FUNCTION tracker._reconciliation_started(p_claim text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
  SELECT EXISTS (SELECT 1 FROM tracker.reconciliations WHERE claim_id = p_claim)
      OR EXISTS (SELECT 1 FROM tracker.reconciliation_items WHERE claim_id = p_claim)
      OR EXISTS (SELECT 1 FROM tracker.reconciled_claims WHERE claim_id = p_claim)
$$;

CREATE FUNCTION tracker.request_correction(p_coding int, p_reason text) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE c record; n int;
BEGIN
  SELECT * INTO c FROM tracker.codings WHERE coding_id = p_coding;
  IF NOT FOUND OR c.coder_id IS DISTINCT FROM admin.me() OR admin.my_login_role() <> 'coder' THEN
    RAISE EXCEPTION 'Only the coder can ask for a correction to their own coding' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF c.protocol_version <> 'CERIC-T v0.4' THEN
    RAISE EXCEPTION 'Corrections are available for CERIC-T v0.4 codings only; % records stay locked', c.protocol_version USING ERRCODE = 'check_violation';
  END IF;
  IF c.status <> 'submitted' THEN RAISE EXCEPTION 'Coding % is still a draft; edit it directly', p_coding USING ERRCODE = 'check_violation'; END IF;
  IF tracker._reconciliation_started(c.claim_id) THEN
    RAISE EXCEPTION 'Reconciliation has started on %; a correction is no longer possible', c.claim_id USING ERRCODE = 'check_violation';
  END IF;
  IF coalesce(length(trim(p_reason)), 0) = 0 THEN RAISE EXCEPTION 'A reason is required' USING ERRCODE = 'check_violation'; END IF;
  INSERT INTO tracker.coding_corrections (coding_id, claim_id, requested_by, reason, other_coding_submitted)
  VALUES (p_coding, c.claim_id, admin.me(), trim(p_reason),
          EXISTS (SELECT 1 FROM tracker.codings o WHERE o.claim_id = c.claim_id AND o.coding_id <> p_coding AND o.status = 'submitted'))
  RETURNING correction_id INTO n;
  RETURN n;
END $$;

CREATE FUNCTION tracker.decide_correction(p_correction int, p_approve boolean, p_reason text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE k record; rl text := admin.my_login_role(); me int := admin.me(); snap jsonb;
BEGIN
  IF rl IS NULL OR rl NOT IN ('lead','coder') THEN RAISE EXCEPTION 'Lead or coder only' USING ERRCODE = 'insufficient_privilege'; END IF;
  SELECT * INTO k FROM tracker.coding_corrections WHERE correction_id = p_correction;
  IF NOT FOUND THEN RAISE EXCEPTION 'No such correction request'; END IF;
  IF k.requested_by = me THEN
    RAISE EXCEPTION 'You cannot decide a correction to your own coding' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF rl = 'coder' AND NOT EXISTS (SELECT 1 FROM tracker.assignments WHERE claim_id = k.claim_id AND coder_id = me) THEN
    RAISE EXCEPTION 'Only the lead or a coder assigned to % can decide this request', k.claim_id USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF k.status <> 'requested' THEN RAISE EXCEPTION 'This request is already %', k.status USING ERRCODE = 'check_violation'; END IF;
  IF coalesce(length(trim(p_reason)), 0) = 0 THEN RAISE EXCEPTION 'A reason is required' USING ERRCODE = 'check_violation'; END IF;
  IF NOT p_approve THEN
    UPDATE tracker.coding_corrections SET status = 'refused', decided_by = me, decided_at = now(), decision_reason = trim(p_reason)
     WHERE correction_id = p_correction;
    RETURN 'refused';
  END IF;
  IF tracker._reconciliation_started(k.claim_id) THEN
    RAISE EXCEPTION 'Reconciliation has started on %; a correction is no longer possible', k.claim_id USING ERRCODE = 'check_violation';
  END IF;
  SELECT jsonb_build_object(
           'coding', to_jsonb(c),
           'answers', (SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.question_code), '[]') FROM tracker.answers a WHERE a.coding_id = c.coding_id),
           'element_evaluations', (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.element), '[]') FROM tracker.element_evaluations e WHERE e.coding_id = c.coding_id))
    INTO snap FROM tracker.codings c WHERE c.coding_id = k.coding_id;
  UPDATE tracker.coding_corrections SET status = 'approved', decided_by = me, decided_at = now(), decision_reason = trim(p_reason), original = snap
   WHERE correction_id = p_correction;
  -- Reopen the coding. guard_coding() allows this one change because an approved request now exists.
  UPDATE tracker.codings SET status = 'draft', submitted_at = NULL, final_claim_rating = NULL, final_implications_rating = NULL
   WHERE coding_id = k.coding_id;
  UPDATE tracker.element_evaluations SET not_supported_route = NULL WHERE coding_id = k.coding_id;
  RETURN 'approved';
END $$;

-- What the people involved may see: the request and its decision, never the answers.
CREATE FUNCTION tracker.corrections_list(p_claim text DEFAULT NULL)
RETURNS TABLE (correction_id int, claim_id text, coding_id int, requested_by int, requested_at timestamptz, reason text,
               other_coding_submitted boolean, status text, decided_by int, decided_at timestamptz, decision_reason text, completed_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE rl text := admin.my_login_role(); me int := admin.me();
BEGIN
  IF rl IS NULL OR rl NOT IN ('lead','coder') THEN RAISE EXCEPTION 'Lead or coder only' USING ERRCODE = 'insufficient_privilege'; END IF;
  RETURN QUERY
    SELECT k.correction_id, k.claim_id, k.coding_id, k.requested_by, k.requested_at, k.reason, k.other_coding_submitted,
           k.status, k.decided_by, k.decided_at, k.decision_reason, k.completed_at
    FROM tracker.coding_corrections k
    WHERE (p_claim IS NULL OR k.claim_id = p_claim)
      AND (rl = 'lead' OR k.requested_by = me
           OR EXISTS (SELECT 1 FROM tracker.assignments a WHERE a.claim_id = k.claim_id AND a.coder_id = me))
    ORDER BY k.correction_id;
END $$;

-- A submitted coding stays locked, with one exception: reopening it as a draft when an approved correction exists.
CREATE OR REPLACE FUNCTION tracker.guard_coding() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NOT EXISTS (SELECT 1 FROM tracker.assignments WHERE claim_id = NEW.claim_id AND coder_id = NEW.coder_id) THEN
      RAISE EXCEPTION 'Coder % is not assigned to claim %', NEW.coder_id, NEW.claim_id;
    END IF;
    IF NEW.status <> 'draft' THEN RAISE EXCEPTION 'A new coding starts as a draft'; END IF;
    RETURN NEW;
  END IF;
  IF OLD.status = 'submitted' THEN
    IF TG_OP = 'UPDATE' AND NEW.status = 'draft'
       AND NEW.claim_id = OLD.claim_id AND NEW.coder_id = OLD.coder_id AND NEW.protocol_version = OLD.protocol_version
       AND OLD.protocol_version = 'CERIC-T v0.4'
       AND NOT tracker._reconciliation_started(OLD.claim_id)
       AND EXISTS (SELECT 1 FROM tracker.coding_corrections k
                   WHERE k.coding_id = OLD.coding_id AND k.status = 'approved' AND k.original IS NOT NULL) THEN
      RETURN NEW;
    END IF;
    RAISE EXCEPTION 'Coding % is submitted and locked; changes go through reconciliation', OLD.coding_id
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  IF NEW.claim_id <> OLD.claim_id OR NEW.coder_id <> OLD.coder_id OR NEW.protocol_version <> OLD.protocol_version THEN
    RAISE EXCEPTION 'Claim, coder and protocol version of a coding cannot be changed';
  END IF;
  IF NEW.status = 'submitted' AND current_setting('hill.submitting', true) IS DISTINCT FROM 'on' THEN
    RAISE EXCEPTION 'Use tracker.submit_coding() to submit';
  END IF;
  RETURN NEW;
END $$;

-- A corrected coding is closed again when it is resubmitted.
CREATE FUNCTION tracker.close_correction() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
BEGIN
  IF OLD.status = 'draft' AND NEW.status = 'submitted' THEN
    UPDATE tracker.coding_corrections SET status = 'completed', completed_at = now()
     WHERE coding_id = NEW.coding_id AND status = 'approved';
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER close_correction AFTER UPDATE ON tracker.codings
  FOR EACH ROW EXECUTE FUNCTION tracker.close_correction();

-- A draft reopened for correction cannot be deleted by its coder: the original must stay tied to a coding.
CREATE FUNCTION tracker.keep_corrected_coding() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM tracker.coding_corrections WHERE coding_id = OLD.coding_id) THEN
    RAISE EXCEPTION 'Coding % has a correction on record and cannot be deleted', OLD.coding_id USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN OLD;
END $$;
CREATE TRIGGER keep_corrected_coding BEFORE DELETE ON tracker.codings
  FOR EACH ROW EXECUTE FUNCTION tracker.keep_corrected_coding();

REVOKE ALL ON FUNCTION tracker._reconciliation_started(text), tracker.request_correction(int, text),
  tracker.decide_correction(int, boolean, text), tracker.corrections_list(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tracker.request_correction(int, text) TO hill_coder;
GRANT EXECUTE ON FUNCTION tracker.decide_correction(int, boolean, text), tracker.corrections_list(text) TO hill_lead, hill_coder;
-- Gene, 2026-11-12: an approved correction may also correct the coder's own evaluation of an element.
-- The value before the correction stays in coding_corrections.original. In every other case it stays locked.
CREATE OR REPLACE FUNCTION tracker.lock_own_evaluation() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
BEGIN
  IF OLD.own_evaluation IS NOT NULL AND NEW.own_evaluation IS DISTINCT FROM OLD.own_evaluation THEN
    IF NEW.own_evaluation IS NULL OR NOT EXISTS (SELECT 1 FROM tracker.coding_corrections k
                    WHERE k.coding_id = OLD.coding_id AND k.status = 'approved' AND k.original IS NOT NULL) THEN
      RAISE EXCEPTION 'Your own evaluation of % is already recorded and cannot be changed', OLD.element USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END $$;

COMMIT;
