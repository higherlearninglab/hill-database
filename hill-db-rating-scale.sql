-- HiLL database: rating scale revision for CERIC-T v0.3 (decided by Gene on 2026-11-10).
-- Applied on top of hill-db-v03.sql. Run once as a database administrator who is a member of hill_owner.
--
--   * The overall result of an appraisal is called a rating everywhere (types, columns, functions,
--     views, settings and messages are renamed).
--   * Five ratings: Supported / Supported with concerns / Overstated / Not supported / Cannot be evaluated.
--   * v0.3 derivation, in order:
--       1. Evidence or Reasoning Not supported, with a question in that element answered No or Probably no: Not supported
--       2. Evidence or Reasoning Not supported only through No information answers: Cannot be evaluated
--       3. CER summary answered Probably no or No, or Claim Not supported: Overstated
--       4. Implications or Context Not supported, or any element Some concerns: Supported with concerns
--       5. All five elements Supported: Supported
--   * Cannot be evaluated carries no severity.
--   * Overstated types are no longer used under v0.3. The database derives where the argument falls short.
--   * tracker.claim_outcome() gives the result the agreed evaluations produce, before a claim is finalized.
-- No question wording in this file.
\set ON_ERROR_STOP on
SET ROLE hill_owner;
-- A new enum value must be committed before it can be used, so this one statement runs on its own.
ALTER TYPE tracker.verdict ADD VALUE IF NOT EXISTS 'Cannot be evaluated';
RESET ROLE;

BEGIN;
SET LOCAL ROLE hill_owner;

-- ======================================================================
-- 1. Names: "rating" replaces the earlier word everywhere
-- ======================================================================
ALTER TYPE tracker.verdict RENAME VALUE 'Partially supported' TO 'Supported with concerns';
ALTER TYPE tracker.verdict RENAME TO rating;
ALTER TABLE tracker.codings RENAME COLUMN final_verdict TO final_rating;
ALTER TABLE tracker.reconciled_claims RENAME COLUMN verdict TO rating;
ALTER VIEW tracker.public_verdicts RENAME TO public_ratings;
UPDATE admin.settings SET key = 'ratings_public',
       note = 'Ratings and severity are hidden from the public views until v1.0. Only the lead can change this.'
 WHERE key = 'verdicts_public';

COMMENT ON COLUMN tracker.codings.cer_summary IS 'S1: given the Evidence and Reasoning evaluations, is the main Claim supported as stated? PN or N makes the rating Overstated when the Evidence and Reasoning hold.';
COMMENT ON COLUMN tracker.codings.evidence_tier IS 'E11: adapted from the ESSA tiers. Reported beside the rating; never an input to it.';
COMMENT ON COLUMN tracker.studies.publication_status IS 'Reported beside the rating. An agent may pre-fill; a coder or the lead confirms.';
COMMENT ON VIEW tracker.audit_flags_profile IS 'Flags profile by domain. No overall rating (checklist reporting rule).';

CREATE OR REPLACE FUNCTION admin.set_setting(p_key text, p_value text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, admin AS $$
BEGIN
  IF admin.my_login_role() NOT IN ('lead','admin') THEN
    RAISE EXCEPTION 'Only the lead can change settings' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_key = 'ratings_public' AND p_value NOT IN ('on','off') THEN RAISE EXCEPTION 'ratings_public must be on or off'; END IF;
  IF p_key = 'double_coding_rate' AND NOT (p_value::numeric > 0 AND p_value::numeric <= 1) THEN
    RAISE EXCEPTION 'double_coding_rate must be between 0 and 1';
  END IF;
  UPDATE admin.settings SET value = p_value, updated_by = admin.me(), updated_at = now() WHERE key = p_key;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown setting %', p_key; END IF;
END $$;

-- ======================================================================
-- 2. Rating rules
-- ======================================================================
DROP FUNCTION tracker.derive_verdict(tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation);
DROP FUNCTION tracker.derive_verdict(tracker.answer_code, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation);
DROP FUNCTION tracker.derive_context_flag(tracker.answer_code, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation);
DROP FUNCTION tracker.coding_result(int);

-- Decision rules v0.2 (kept for any coding recorded under v0.2)
CREATE FUNCTION tracker.derive_rating(c tracker.evaluation, e tracker.evaluation, r tracker.evaluation,
                                      i tracker.evaluation, x tracker.evaluation) RETURNS tracker.rating
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN c IS NULL OR e IS NULL OR r IS NULL OR i IS NULL OR x IS NULL THEN NULL
    WHEN e = 'Not supported' OR r = 'Not supported' THEN 'Not supported'
    WHEN c = 'Not supported' OR i = 'Not supported' THEN 'Overstated'
    WHEN x = 'Not supported' THEN 'Supported with concerns'
    WHEN 'Some concerns' IN (c, e, r, i, x) THEN 'Supported with concerns'
    ELSE 'Supported'
  END::tracker.rating
$$;

CREATE OR REPLACE FUNCTION tracker.derive_context_flag(c tracker.evaluation, e tracker.evaluation, r tracker.evaluation,
                                                       i tracker.evaluation, x tracker.evaluation) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT tracker.derive_rating(c, e, r, i, x) = 'Supported with concerns' AND x = 'Not supported'
$$;

-- Decision rules v0.3. e_ni and r_ni say that the element is Not supported only through
-- No information answers (no question in it was answered No or Probably no).
CREATE FUNCTION tracker.derive_rating(s1 tracker.answer_code, c tracker.evaluation, e tracker.evaluation, r tracker.evaluation,
                                      i tracker.evaluation, x tracker.evaluation, e_ni boolean, r_ni boolean) RETURNS tracker.rating
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN s1 IS NULL OR c IS NULL OR e IS NULL OR r IS NULL OR i IS NULL OR x IS NULL THEN NULL
    WHEN (e = 'Not supported' AND NOT coalesce(e_ni, false))
      OR (r = 'Not supported' AND NOT coalesce(r_ni, false)) THEN 'Not supported'        -- rule 1
    WHEN e = 'Not supported' OR r = 'Not supported' THEN 'Cannot be evaluated'           -- rule 2
    WHEN s1 IN ('PN','N') OR c = 'Not supported' THEN 'Overstated'                       -- rule 3
    WHEN i = 'Not supported' OR x = 'Not supported'
      OR 'Some concerns' IN (c, e, r, i, x) THEN 'Supported with concerns'               -- rule 4
    ELSE 'Supported'                                                                     -- rule 5
  END::tracker.rating
$$;

-- Where the argument falls short: elements that are not Supported, in CERIC order, each with its
-- evaluation; the CER summary is named after Reasoning when answered Probably no or No.
CREATE FUNCTION tracker.falls_short(s1 tracker.answer_code, c tracker.evaluation, e tracker.evaluation, r tracker.evaluation,
                                    i tracker.evaluation, x tracker.evaluation, e_ni boolean, r_ni boolean) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(concat_ws(', ',
    CASE WHEN c <> 'Supported' THEN 'Claim (' || c || ')' END,
    CASE WHEN e = 'Not supported' AND coalesce(e_ni, false) THEN 'Evidence (not enough reported)'
         WHEN e <> 'Supported' THEN 'Evidence (' || e || ')' END,
    CASE WHEN r = 'Not supported' AND coalesce(r_ni, false) THEN 'Reasoning (not enough reported)'
         WHEN r <> 'Supported' THEN 'Reasoning (' || r || ')' END,
    CASE s1 WHEN 'PN' THEN 'CER summary (Probably no)' WHEN 'N' THEN 'CER summary (No)' END,
    CASE WHEN i <> 'Supported' THEN 'Implications (' || i || ')' END,
    CASE WHEN x <> 'Supported' THEN 'Context (' || x || ')' END), '')
$$;

-- Is this element of a claim unfavorable only through No information answers?
-- p_coding NULL: across every coding of the claim. No answer of No or Probably no, and at least one unfavorable No information.
CREATE FUNCTION tracker._ni_only(p_claim text, p_coding int, p_element tracker.element) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
  SELECT coalesce(bool_and(a.answer NOT IN ('N','PN')), false)
     AND coalesce(bool_or(a.answer = 'NI' AND q.ni_reading = 'unfavorable'), false)
  FROM tracker.codings cd
  JOIN tracker.answers a ON a.coding_id = cd.coding_id
  JOIN tracker.questions q ON q.protocol_version = cd.protocol_version AND q.code = a.question_code
  WHERE cd.claim_id = p_claim AND (p_coding IS NULL OR cd.coding_id = p_coding) AND q.element = p_element
$$;

CREATE FUNCTION tracker.coding_falls_short(p_coding int) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
DECLARE c tracker.evaluation; e tracker.evaluation; r tracker.evaluation; i tracker.evaluation; x tracker.evaluation; cd record;
BEGIN
  PERFORM tracker.assert_visible(p_coding);
  SELECT effective INTO c FROM tracker.coding_summary(p_coding) WHERE element = 'Claim';
  SELECT effective INTO e FROM tracker.coding_summary(p_coding) WHERE element = 'Evidence';
  SELECT effective INTO r FROM tracker.coding_summary(p_coding) WHERE element = 'Reasoning';
  SELECT effective INTO i FROM tracker.coding_summary(p_coding) WHERE element = 'Implications';
  SELECT effective INTO x FROM tracker.coding_summary(p_coding) WHERE element = 'Context';
  SELECT * INTO cd FROM tracker.codings WHERE coding_id = p_coding;
  RETURN tracker.falls_short(cd.cer_summary, c, e, r, i, x,
                             tracker._ni_only(cd.claim_id, p_coding, 'Evidence'), tracker._ni_only(cd.claim_id, p_coding, 'Reasoning'));
END $$;

ALTER TABLE tracker.reconciled_claims ADD COLUMN falls_short text;
-- "Cannot be evaluated" carries no severity; every other rating has one.
ALTER TABLE tracker.reconciled_claims ALTER COLUMN severity DROP NOT NULL;
ALTER TABLE tracker.reconciled_claims ADD CONSTRAINT severity_by_rating CHECK ((rating = 'Cannot be evaluated') = (severity IS NULL));
COMMENT ON COLUMN tracker.reconciled_claims.falls_short IS 'Where the argument falls short, derived from the agreed evaluations and CER summary. NULL when every element is Supported.';

-- The Overstated type is required only for a claim recorded under v0.2; under v0.3 it is not used.
DO $$
DECLARE n text;
BEGIN
  SELECT conname INTO n FROM pg_constraint
   WHERE conrelid = 'tracker.reconciled_claims'::regclass AND contype = 'c' AND pg_get_constraintdef(oid) LIKE '%overstated_type%';
  IF n IS NULL THEN RAISE EXCEPTION 'Overstated-type check not found on tracker.reconciled_claims'; END IF;
  EXECUTE format('ALTER TABLE tracker.reconciled_claims DROP CONSTRAINT %I', n);
END $$;
ALTER TABLE tracker.reconciled_claims ADD CONSTRAINT overstated_type_by_version CHECK (
  CASE WHEN protocol_version = 'CERIC-T v0.2' THEN (rating = 'Overstated') = (overstated_type IS NOT NULL)
       ELSE overstated_type IS NULL END);

-- ======================================================================
-- 3. A coding's result
-- ======================================================================
CREATE FUNCTION tracker.coding_result(p_coding int,
  OUT proposed_rating tracker.rating, OUT proposed_severity tracker.severity,
  OUT context_flag boolean, OUT proposed_type tracker.overstated_type,
  OUT needs_supportable_claim boolean, OUT attention text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
DECLARE
  c tracker.evaluation; e tracker.evaluation; r tracker.evaluation; i tracker.evaluation; x tracker.evaluation;
  cd record; s record; uc text[]; n_ans int; n_q int; msg text := ''; v3 boolean; has_reason boolean;
BEGIN
  PERFORM tracker.assert_visible(p_coding);
  SELECT * INTO cd FROM tracker.codings WHERE coding_id = p_coding;
  v3 := cd.protocol_version <> 'CERIC-T v0.2';
  SELECT effective INTO c FROM tracker.coding_summary(p_coding) WHERE element = 'Claim';
  SELECT effective INTO e FROM tracker.coding_summary(p_coding) WHERE element = 'Evidence';
  SELECT effective INTO r FROM tracker.coding_summary(p_coding) WHERE element = 'Reasoning';
  SELECT effective INTO i FROM tracker.coding_summary(p_coding) WHERE element = 'Implications';
  SELECT effective INTO x FROM tracker.coding_summary(p_coding) WHERE element = 'Context';
  IF v3 THEN
    proposed_rating   := tracker.derive_rating(cd.cer_summary, c, e, r, i, x,
                           tracker._ni_only(cd.claim_id, p_coding, 'Evidence'), tracker._ni_only(cd.claim_id, p_coding, 'Reasoning'));
    proposed_severity := CASE WHEN proposed_rating = 'Cannot be evaluated' THEN NULL
                              ELSE tracker.derive_severity(cd.cer_summary, c, e, r, i, x) END;
    context_flag      := proposed_rating = 'Supported with concerns' AND x = 'Not supported';
    proposed_type     := NULL;
  ELSE
    proposed_rating   := tracker.derive_rating(c, e, r, i, x);
    proposed_severity := tracker.derive_severity(c, e, r, i, x);
    context_flag      := tracker.derive_context_flag(c, e, r, i, x);
    proposed_type     := tracker.derive_type(p_coding, coalesce(cd.final_rating, proposed_rating), c, i);
  END IF;
  SELECT unf INTO uc FROM tracker._unf_codes(p_coding, 'Claim');
  needs_supportable_claim := uc && ARRAY['C4','C5'];

  SELECT count(*) INTO n_ans FROM tracker.answers WHERE coding_id = p_coding;
  SELECT count(*) INTO n_q FROM tracker.questions WHERE protocol_version = cd.protocol_version;
  IF n_ans < n_q THEN msg := msg || format('%s of %s questions answered; ', n_ans, n_q); END IF;
  FOR s IN SELECT * FROM tracker.coding_summary(p_coding) LOOP
    IF s.final IS NULL THEN msg := msg || s.element || ' evaluation missing; '; END IF;
    IF NOT s.has_rationale THEN msg := msg || s.element || ' rationale missing; '; END IF;
    IF s.needs_override_note THEN msg := msg || s.element || ' differs from Proposed without a note; '; END IF;
  END LOOP;
  IF needs_supportable_claim AND cd.supportable_claim IS NULL THEN msg := msg || 'supportable claim missing; '; END IF;
  IF v3 THEN
    has_reason := coalesce(length(trim(cd.cer_summary_reason)), 0) > 0;
    IF cd.cer_summary IS NULL THEN
      msg := msg || 'CER summary not answered; ';
    ELSE
      IF cd.cer_summary IN ('PN','N') AND NOT has_reason THEN
        msg := msg || 'CER summary answered Probably no or No without a reason; ';
      END IF;
      IF cd.cer_summary IN ('Y','PY') AND 'Not supported' IN (e, r) THEN
        msg := msg || 'CER summary cannot be Yes or Probably yes when Evidence or Reasoning is Not supported; ';
      END IF;
      IF cd.cer_summary IN ('Y','PY') AND needs_supportable_claim AND NOT has_reason THEN
        msg := msg || 'CER summary is Yes or Probably yes although a supportable claim was written: add a note; ';
      END IF;
    END IF;
    IF cd.evidence_tier IS NULL THEN msg := msg || 'Evidence tier not chosen; '; END IF;
    IF cd.overstated_type IS NOT NULL THEN msg := msg || 'Overstated types are not used under this protocol version: clear the type; '; END IF;
  ELSE
    IF coalesce(cd.final_rating, proposed_rating) = 'Overstated' AND cd.overstated_type IS NULL THEN
      msg := msg || 'Overstated type missing; ';
    END IF;
    IF cd.overstated_type IS NOT NULL AND cd.overstated_type IS DISTINCT FROM proposed_type
       AND coalesce(length(trim(cd.type_reason)), 0) = 0 THEN
      msg := msg || 'Overstated type differs from Proposed (or none proposed) without a reason; ';
    END IF;
  END IF;
  IF (cd.final_rating IS NOT NULL AND cd.final_rating IS DISTINCT FROM proposed_rating
      OR cd.final_severity IS NOT NULL AND cd.final_severity IS DISTINCT FROM proposed_severity)
     AND coalesce(length(trim(cd.override_note)), 0) = 0 THEN
    msg := msg || 'rating or severity override without a note; ';
  END IF;
  attention := nullif(msg, '');
END $$;

CREATE OR REPLACE FUNCTION tracker.submit_coding(p_coding int) RETURNS tracker.rating
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE c record; r record;
BEGIN
  SELECT * INTO c FROM tracker.codings WHERE coding_id = p_coding;
  IF NOT FOUND OR c.coder_id IS DISTINCT FROM admin.me() OR admin.my_login_role() <> 'coder' THEN
    RAISE EXCEPTION 'Only the coder can submit their own coding' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF c.status <> 'draft' THEN RAISE EXCEPTION 'Coding % is already submitted', p_coding; END IF;
  SELECT * INTO r FROM tracker.coding_result(p_coding);
  IF r.attention IS NOT NULL THEN
    RAISE EXCEPTION 'Cannot submit coding %: %', p_coding, r.attention USING ERRCODE = 'check_violation';
  END IF;
  PERFORM set_config('hill.submitting', 'on', true);
  UPDATE tracker.codings
     SET final_rating   = coalesce(final_rating, r.proposed_rating),
         final_severity = coalesce(final_severity, r.proposed_severity),
         status = 'submitted', submitted_at = now()
   WHERE coding_id = p_coding;
  PERFORM set_config('hill.submitting', 'off', true);
  RETURN (SELECT final_rating FROM tracker.codings WHERE coding_id = p_coding);
END $$;

-- ======================================================================
-- 4. The result the agreed evaluations produce (shown before finalizing; used by finalize_claim)
-- ======================================================================
CREATE FUNCTION tracker.claim_outcome(p_claim text,
  OUT pending text, OUT claim_eval tracker.evaluation, OUT evidence_eval tracker.evaluation, OUT reasoning_eval tracker.evaluation,
  OUT implications_eval tracker.evaluation, OUT context_eval tracker.evaluation, OUT cer_summary tracker.answer_code,
  OUT evidence_tier tracker.evidence_tier, OUT rating tracker.rating, OUT severity tracker.severity,
  OUT context_flag boolean, OUT falls_short text, OUT protocol_version text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE
  rl text := admin.my_login_role(); n_sub int; n_all int; el tracker.element; ev tracker.evaluation;
  ev_all tracker.evaluation[] := '{}'; v3 boolean; txt text; msg text := ''; e_ni boolean; r_ni boolean;
BEGIN
  IF rl NOT IN ('lead','coder') THEN RAISE EXCEPTION 'Lead or coder only' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF rl = 'coder' AND NOT tracker.is_coder_of(p_claim, admin.me()) THEN RAISE EXCEPTION 'Not a coder of %', p_claim; END IF;
  SELECT count(*) FILTER (WHERE status = 'submitted'), count(*) INTO n_sub, n_all FROM tracker.codings WHERE claim_id = p_claim;
  IF n_sub = 0 OR n_sub <> n_all THEN RAISE EXCEPTION 'All codings of % must be submitted', p_claim; END IF;
  IF n_sub = 1 AND EXISTS (SELECT 1 FROM tracker.double_samples WHERE claim_id = p_claim AND selected) THEN
    RAISE EXCEPTION '% was drawn for double-coding; it needs a second coding', p_claim;
  END IF;
  protocol_version := (SELECT cd.protocol_version FROM tracker.codings cd WHERE cd.claim_id = p_claim LIMIT 1);
  v3 := protocol_version <> 'CERIC-T v0.2';
  FOREACH el IN ARRAY enum_range(NULL::tracker.element) LOOP
    SELECT CASE WHEN count(DISTINCT ee.final_evaluation) = 1 THEN min(ee.final_evaluation)
                ELSE (SELECT agreed_evaluation FROM tracker.reconciliations rr WHERE rr.claim_id = p_claim AND rr.element = el) END
      INTO ev
      FROM tracker.codings c JOIN tracker.element_evaluations ee ON ee.coding_id = c.coding_id AND ee.element = el
     WHERE c.claim_id = p_claim;
    IF ev IS NULL THEN msg := msg || el || ' on ' || p_claim || ' is not reconciled yet; '; END IF;
    ev_all := ev_all || ev;
  END LOOP;
  claim_eval := ev_all[1]; evidence_eval := ev_all[2]; reasoning_eval := ev_all[3]; implications_eval := ev_all[4]; context_eval := ev_all[5];
  IF v3 THEN
    -- CER summary: the coders' answers when both are favorable or both unfavorable (the less certain one is kept),
    -- otherwise the reconciled answer.
    IF (SELECT count(DISTINCT (cd.cer_summary IN ('Y','PY'))) FROM tracker.codings cd WHERE cd.claim_id = p_claim) = 1 THEN
      SELECT CASE WHEN bool_and(cd.cer_summary IN ('Y','PY'))
                  THEN CASE WHEN bool_or(cd.cer_summary = 'PY') THEN 'PY' ELSE 'Y' END
                  ELSE CASE WHEN bool_or(cd.cer_summary = 'PN') THEN 'PN' ELSE 'N' END END::tracker.answer_code
        INTO cer_summary FROM tracker.codings cd WHERE cd.claim_id = p_claim;
    ELSE
      SELECT agreed_value INTO txt FROM tracker.reconciliation_items WHERE claim_id = p_claim AND item = 'CER summary';
      cer_summary := txt::tracker.answer_code;
    END IF;
    IF cer_summary IS NULL THEN msg := msg || 'CER summary on ' || p_claim || ' is not reconciled yet; '; END IF;
    IF (SELECT count(DISTINCT cd.evidence_tier) FROM tracker.codings cd WHERE cd.claim_id = p_claim) = 1 THEN
      SELECT min(cd.evidence_tier) INTO evidence_tier FROM tracker.codings cd WHERE cd.claim_id = p_claim;
    ELSE
      txt := NULL;
      SELECT agreed_value INTO txt FROM tracker.reconciliation_items WHERE claim_id = p_claim AND item = 'Evidence tier';
      evidence_tier := txt::tracker.evidence_tier;
    END IF;
    IF evidence_tier IS NULL THEN msg := msg || 'Evidence tier on ' || p_claim || ' is not reconciled yet; '; END IF;
  END IF;
  pending := nullif(msg, '');
  IF pending IS NOT NULL THEN RETURN; END IF;
  IF v3 THEN
    e_ni := tracker._ni_only(p_claim, NULL, 'Evidence'); r_ni := tracker._ni_only(p_claim, NULL, 'Reasoning');
    rating       := tracker.derive_rating(cer_summary, ev_all[1], ev_all[2], ev_all[3], ev_all[4], ev_all[5], e_ni, r_ni);
    severity     := CASE WHEN rating = 'Cannot be evaluated' THEN NULL
                         ELSE tracker.derive_severity(cer_summary, ev_all[1], ev_all[2], ev_all[3], ev_all[4], ev_all[5]) END;
    context_flag := rating = 'Supported with concerns' AND ev_all[5] = 'Not supported';
    falls_short  := tracker.falls_short(cer_summary, ev_all[1], ev_all[2], ev_all[3], ev_all[4], ev_all[5], e_ni, r_ni);
  ELSE
    rating       := tracker.derive_rating(ev_all[1], ev_all[2], ev_all[3], ev_all[4], ev_all[5]);
    severity     := tracker.derive_severity(ev_all[1], ev_all[2], ev_all[3], ev_all[4], ev_all[5]);
    context_flag := tracker.derive_context_flag(ev_all[1], ev_all[2], ev_all[3], ev_all[4], ev_all[5]);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION tracker.finalize_claim(p_claim text, p_type tracker.overstated_type DEFAULT NULL,
                                                  p_supportable text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS tracker.rating
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE o record; t tracker.overstated_type; sc text;
BEGIN
  SELECT * INTO o FROM tracker.claim_outcome(p_claim);      -- checks who may finalize and that all codings are submitted
  IF o.pending IS NOT NULL THEN RAISE EXCEPTION '%', rtrim(o.pending, '; '); END IF;
  IF o.protocol_version = 'CERIC-T v0.2' THEN
    t := p_type;
    IF o.rating = 'Overstated' AND t IS NULL THEN
      SELECT CASE WHEN count(DISTINCT overstated_type) = 1 AND count(overstated_type) = count(*) THEN min(overstated_type) END
        INTO t FROM tracker.codings WHERE claim_id = p_claim;
      IF t IS NULL THEN RAISE EXCEPTION 'Overstated: the coders chose different types; give the agreed type'; END IF;
    END IF;
    IF o.rating <> 'Overstated' THEN t := NULL; END IF;
  END IF;
  sc := p_supportable;
  IF sc IS NULL THEN
    SELECT CASE WHEN count(DISTINCT supportable_claim) = 1 THEN min(supportable_claim) END INTO sc
      FROM tracker.codings WHERE claim_id = p_claim AND supportable_claim IS NOT NULL;
  END IF;
  INSERT INTO tracker.reconciled_claims (claim_id, claim_eval, evidence_eval, reasoning_eval, implications_eval, context_eval,
                                         rating, severity, context_flag, overstated_type, supportable_claim, note,
                                         protocol_version, finalized_by, cer_summary, evidence_tier, falls_short)
  VALUES (p_claim, o.claim_eval, o.evidence_eval, o.reasoning_eval, o.implications_eval, o.context_eval,
          o.rating, o.severity, o.context_flag, t, sc, p_note, o.protocol_version, admin.me(),
          o.cer_summary, o.evidence_tier, o.falls_short);
  RETURN o.rating;
END $$;

-- ======================================================================
-- 5. Public view and permissions
-- ======================================================================
DROP VIEW tracker.public_ratings;
CREATE VIEW tracker.public_ratings AS
SELECT rc.claim_id, cl.study_id, cl.main_claim, rc.rating, rc.severity, rc.context_flag, rc.overstated_type,
       rc.supportable_claim, rc.claim_eval, rc.evidence_eval, rc.reasoning_eval, rc.implications_eval, rc.context_eval,
       rc.protocol_version, rc.cer_summary, rc.evidence_tier, rc.falls_short
FROM tracker.reconciled_claims rc
JOIN tracker.claims cl USING (claim_id)
JOIN tracker.released_studies USING (study_id)
WHERE admin.setting('ratings_public') = 'on';
REVOKE ALL ON tracker.public_ratings FROM PUBLIC;
GRANT SELECT ON tracker.public_ratings TO hill_lead, hill_publisher;

REVOKE ALL ON FUNCTION
  tracker.derive_rating(tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation),
  tracker.derive_rating(tracker.answer_code, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, boolean, boolean),
  tracker.falls_short(tracker.answer_code, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, boolean, boolean),
  tracker._ni_only(text, int, tracker.element), tracker.coding_falls_short(int), tracker.coding_result(int), tracker.claim_outcome(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  tracker.derive_rating(tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation),
  tracker.derive_rating(tracker.answer_code, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, boolean, boolean),
  tracker.falls_short(tracker.answer_code, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, boolean, boolean),
  tracker.coding_falls_short(int), tracker.coding_result(int) TO hill_lead, hill_coder, hill_tiebreak, hill_agent;
GRANT EXECUTE ON FUNCTION tracker.claim_outcome(text) TO hill_lead, hill_coder;

COMMIT;

-- The description of the lead role names the setting; it can be changed only by a role administrator.
DO $$ BEGIN
  COMMENT ON ROLE hill_lead IS 'Lead (Gene): approves releases, decides reconciliations on claims she did not code, sets ratings_public.';
EXCEPTION WHEN insufficient_privilege THEN RAISE NOTICE 'Role comment left as it is (needs a role administrator).';
END $$;
