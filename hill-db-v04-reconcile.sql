-- CERIC-T v0.4, part 4 of the build: the result of a reconciled Claim.
-- A v0.4 Claim is finalized with a Claim rating and an Implications rating. Reconciling the elements,
-- the CER summary and the Evidence tier works as before. v0.2 and v0.3 Claims are untouched.
-- No question wording in this file.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE hill_owner;

ALTER TABLE tracker.reconciled_claims
  ALTER COLUMN rating DROP NOT NULL,
  ADD COLUMN claim_rating tracker.claim_rating,
  ADD COLUMN implications_rating tracker.implications_rating,
  ADD COLUMN supportable_claim_type tracker.claim_type,
  ADD COLUMN reporting_error_note text,
  ADD COLUMN reporting_error_open_data boolean,
  ADD CONSTRAINT reporting_error_complete CHECK ((reporting_error_note IS NULL) = (reporting_error_open_data IS NULL)),
  ADD CONSTRAINT ratings_by_version CHECK (
    CASE WHEN protocol_version = 'CERIC-T v0.4'
         THEN rating IS NULL AND severity IS NULL AND claim_rating IS NOT NULL AND implications_rating IS NOT NULL
         ELSE rating IS NOT NULL AND claim_rating IS NULL AND implications_rating IS NULL END),
  ADD CONSTRAINT v04_supportable_claim CHECK (
    protocol_version <> 'CERIC-T v0.4'
    OR ((claim_rating = 'Not supported') = (supportable_claim IS NOT NULL)
        AND (supportable_claim IS NULL) = (supportable_claim_type IS NULL))),
  ADD CONSTRAINT v04_not_rated CHECK (
    protocol_version <> 'CERIC-T v0.4'
    OR (claim_rating IN ('Not supported','Cannot be evaluated')) = (implications_rating = 'Not rated'));
COMMENT ON COLUMN tracker.reconciled_claims.claim_rating IS 'v0.4: derived from the agreed Claim, Evidence, Reasoning and Context evaluations and the CER summary. Never Overstated.';
COMMENT ON COLUMN tracker.reconciled_claims.implications_rating IS 'v0.4: the agreed Implications evaluation under its public names; Not rated when the Claim rating is Not supported or Cannot be evaluated.';

-- What the agreed evaluations produce under v0.4 (shown before finalizing; used by finalize_claim_v04).
CREATE FUNCTION tracker.claim_outcome_v04(p_claim text,
  OUT pending text, OUT claim_eval tracker.evaluation, OUT evidence_eval tracker.evaluation, OUT reasoning_eval tracker.evaluation,
  OUT implications_eval tracker.evaluation, OUT context_eval tracker.evaluation, OUT cer_summary tracker.answer_code,
  OUT evidence_tier tracker.evidence_tier, OUT claim_rating tracker.claim_rating, OUT implications_rating tracker.implications_rating,
  OUT falls_short text, OUT needs_supportable_claim boolean, OUT coders_supportable_claim text,
  OUT coders_supportable_claim_type tracker.claim_type, OUT reporting_error_flagged boolean, OUT protocol_version text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE o record; e_ni boolean; r_ni boolean;
BEGIN
  SELECT * INTO o FROM tracker.claim_outcome(p_claim);      -- checks who may ask and that all codings are submitted
  IF o.protocol_version <> 'CERIC-T v0.4' THEN
    RAISE EXCEPTION '% was coded under %, not CERIC-T v0.4', p_claim, o.protocol_version;
  END IF;
  IF (SELECT count(DISTINCT cd.protocol_version) FROM tracker.codings cd WHERE cd.claim_id = p_claim) > 1 THEN
    RAISE EXCEPTION 'The codings of % were recorded under different protocol versions', p_claim;
  END IF;
  pending := o.pending; protocol_version := o.protocol_version;
  claim_eval := o.claim_eval; evidence_eval := o.evidence_eval; reasoning_eval := o.reasoning_eval;
  implications_eval := o.implications_eval; context_eval := o.context_eval;
  cer_summary := o.cer_summary; evidence_tier := o.evidence_tier;
  IF pending IS NOT NULL THEN RETURN; END IF;
  e_ni := tracker._ni_only(p_claim, NULL, 'Evidence'); r_ni := tracker._ni_only(p_claim, NULL, 'Reasoning');
  claim_rating := tracker.derive_claim_rating(cer_summary, claim_eval, evidence_eval, reasoning_eval, context_eval, e_ni, r_ni);
  implications_rating := tracker.derive_implications_rating(claim_rating, implications_eval);
  falls_short := tracker.falls_short_v04(cer_summary, claim_eval, evidence_eval, reasoning_eval, context_eval, e_ni, r_ni);
  needs_supportable_claim := claim_rating = 'Not supported';
  -- If every coder who wrote a supportable claim wrote the same one, it is offered as the agreed one.
  SELECT CASE WHEN count(DISTINCT (cd.supportable_claim, cd.supportable_claim_type)) = 1 THEN min(cd.supportable_claim) END,
         CASE WHEN count(DISTINCT (cd.supportable_claim, cd.supportable_claim_type)) = 1 THEN min(cd.supportable_claim_type) END
    INTO coders_supportable_claim, coders_supportable_claim_type
    FROM tracker.codings cd WHERE cd.claim_id = p_claim AND cd.supportable_claim IS NOT NULL;
  reporting_error_flagged := EXISTS (SELECT 1 FROM tracker.codings cd WHERE cd.claim_id = p_claim AND cd.reporting_error_note IS NOT NULL);
END $$;

-- p_error_note: when a coder flagged a suspected reporting error, the agreed note is required; an empty string
-- records that the coders agreed there is no error to flag.
CREATE FUNCTION tracker.finalize_claim_v04(p_claim text, p_supportable text DEFAULT NULL,
                                           p_supportable_type tracker.claim_type DEFAULT NULL, p_note text DEFAULT NULL,
                                           p_error_note text DEFAULT NULL, p_error_open_data boolean DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE o record; sc text; st tracker.claim_type; en text; eo boolean;
BEGIN
  SELECT * INTO o FROM tracker.claim_outcome_v04(p_claim);
  IF o.pending IS NOT NULL THEN RAISE EXCEPTION '%', rtrim(o.pending, '; '); END IF;
  IF o.reporting_error_flagged AND p_error_note IS NULL THEN
    RAISE EXCEPTION 'A coder flagged a suspected reporting error: give the agreed note, or an empty note if you agree there is none'
      USING ERRCODE = 'check_violation';
  END IF;
  en := nullif(trim(p_error_note), '');
  IF en IS NOT NULL THEN
    IF p_error_open_data IS NULL THEN
      RAISE EXCEPTION 'Say whether the authors'' data are openly available' USING ERRCODE = 'check_violation';
    END IF;
    eo := p_error_open_data;
  END IF;
  IF o.needs_supportable_claim THEN
    sc := coalesce(nullif(trim(p_supportable), ''), o.coders_supportable_claim);
    st := CASE WHEN nullif(trim(p_supportable), '') IS NOT NULL THEN p_supportable_type ELSE o.coders_supportable_claim_type END;
    IF sc IS NULL OR st IS NULL THEN
      RAISE EXCEPTION 'The Claim rating is Not supported: give the agreed supportable claim and its type' USING ERRCODE = 'check_violation';
    END IF;
  ELSIF nullif(trim(p_supportable), '') IS NOT NULL THEN
    RAISE EXCEPTION 'A supportable claim is recorded only when the Claim rating is Not supported' USING ERRCODE = 'check_violation';
  END IF;
  INSERT INTO tracker.reconciled_claims (claim_id, claim_eval, evidence_eval, reasoning_eval, implications_eval, context_eval,
                                         rating, severity, context_flag, overstated_type, supportable_claim, supportable_claim_type, note,
                                         protocol_version, finalized_by, cer_summary, evidence_tier, falls_short,
                                         claim_rating, implications_rating, reporting_error_note, reporting_error_open_data)
  VALUES (p_claim, o.claim_eval, o.evidence_eval, o.reasoning_eval, o.implications_eval, o.context_eval,
          NULL, NULL, false, NULL, sc, st, p_note, o.protocol_version, admin.me(),
          o.cer_summary, o.evidence_tier, o.falls_short, o.claim_rating, o.implications_rating, en, eo);
  RETURN 'Claim: ' || o.claim_rating || '; Implications: ' || o.implications_rating;
END $$;

-- The earlier finalize function refuses a v0.4 Claim, so that it can never be given a single rating.
CREATE OR REPLACE FUNCTION tracker.finalize_claim(p_claim text, p_type tracker.overstated_type DEFAULT NULL,
                                                  p_supportable text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS tracker.rating
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE o record; t tracker.overstated_type; sc text;
BEGIN
  SELECT * INTO o FROM tracker.claim_outcome(p_claim);      -- checks who may finalize and that all codings are submitted
  IF o.protocol_version = 'CERIC-T v0.4' THEN
    RAISE EXCEPTION '% was coded under CERIC-T v0.4: finalize it with finalize_claim_v04', p_claim USING ERRCODE = 'check_violation';
  END IF;
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

-- Public view: the two v0.4 ratings are added at the end; earlier columns keep their meaning.
CREATE OR REPLACE VIEW tracker.public_ratings AS
SELECT rc.claim_id, cl.study_id, cl.main_claim, rc.rating, rc.severity, rc.context_flag, rc.overstated_type,
       rc.supportable_claim, rc.claim_eval, rc.evidence_eval, rc.reasoning_eval, rc.implications_eval, rc.context_eval,
       rc.protocol_version, rc.cer_summary, rc.evidence_tier, rc.falls_short,
       rc.claim_rating, rc.implications_rating, rc.supportable_claim_type, rc.reporting_error_note, rc.reporting_error_open_data
FROM tracker.reconciled_claims rc
JOIN tracker.claims cl USING (claim_id)
JOIN tracker.released_studies USING (study_id)
WHERE admin.setting('ratings_public') = 'on';

REVOKE ALL ON FUNCTION tracker.claim_outcome_v04(text), tracker.finalize_claim_v04(text, text, tracker.claim_type, text, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tracker.claim_outcome_v04(text), tracker.finalize_claim_v04(text, text, tracker.claim_type, text, text, boolean) TO hill_lead, hill_coder;
COMMIT;
