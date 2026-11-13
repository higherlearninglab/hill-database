-- HiLL database: supplemental ratings (the records reported beside the two ratings).
-- Applied on top of hill-db-v04-rating-notes.sql. Run once as a database administrator who is a member of hill_owner.
-- No question wording in this file.
--
-- 1. Durability item: a new study-level record, built like the Dependence item. An agent pre-fills each field
--    with a quoted passage; a coder or the lead confirms. Never an input to an evaluation or a rating.
-- 2. The earlier, unused tracker.durability table (one row per time point) and its public view are removed.
--    The script stops if that table holds any row.
-- 3. Who-was-studied records get the same confirmation rules as the Dependence item: a coder or the lead
--    confirms through a function, an agent cannot change a record a person has verified, and a person's change
--    to a value clears the verification.
-- 4. All three records are open to every coder and the lead at any time, including while they are still coding
--    the study (Gene, 2026-11-13). Until now a Dependence record was withheld from a person who still had coding
--    to submit on the study; that rule is removed. Agents still cannot confirm, and the publisher still sees only
--    confirmed records of released studies.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL ROLE hill_owner;

-- ----------------------------------------------------------------------
-- 2. Remove the earlier durability table (never used)
-- ----------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM tracker.durability) THEN
    RAISE EXCEPTION 'tracker.durability holds rows; nothing was changed. Move them before running this script.';
  END IF;
END $$;
DROP VIEW tracker.public_durability;
DROP TABLE tracker.durability;

-- ----------------------------------------------------------------------
-- 1. Durability item
-- ----------------------------------------------------------------------
CREATE TABLE tracker.study_durability (
  study_id               text PRIMARY KEY REFERENCES tracker.studies,
  measured_after_removal text NOT NULL CHECK (measured_after_removal IN ('yes','measured, result not reported','no','not applicable')),
  measured_quote         text,
  measured_page          text,
  interval_after         text,
  effect_held            text NOT NULL CHECK (effect_held IN ('held','reduced','reversed','not measured')),
  effect_quote           text,
  effect_page            text,
  note                   text,
  prefilled_by           int REFERENCES admin.people DEFAULT admin.me(),
  prefilled_at           timestamptz NOT NULL DEFAULT now(),
  confirmed_by           int REFERENCES admin.people,
  confirmed_at           timestamptz,
  CHECK (measured_after_removal NOT IN ('yes','measured, result not reported') OR measured_quote IS NOT NULL),
  CHECK (measured_after_removal <> 'yes' OR interval_after IS NOT NULL),
  -- "Whether the effect held" compares the result after removal with the result while the tool was available,
  -- in the same study. Without a reported result after removal there is nothing to compare.
  CHECK (measured_after_removal = 'yes' OR effect_held = 'not measured'),
  CHECK (effect_held = 'not measured' OR effect_quote IS NOT NULL),
  CHECK ((confirmed_by IS NULL) = (confirmed_at IS NULL))
);
COMMENT ON TABLE tracker.study_durability IS 'Durability item: was the outcome measured after access to the AI tool was removed, and did the effect hold. Reported beside the ratings; never an input to them.';

CREATE TRIGGER zz_log_change AFTER INSERT OR UPDATE OR DELETE ON tracker.study_durability
  FOR EACH ROW EXECUTE FUNCTION admin.log_change();

-- Who may see a row: the same rule as the Dependence item (see part 4).
ALTER TABLE tracker.study_durability ENABLE ROW LEVEL SECURITY;
CREATE POLICY see  ON tracker.study_durability FOR SELECT USING (tracker.dependence_visible(study_id));
CREATE POLICY add  ON tracker.study_durability FOR INSERT WITH CHECK (admin.my_login_role() = 'agent');
CREATE POLICY edit ON tracker.study_durability FOR UPDATE
  USING (tracker.dependence_visible(study_id)) WITH CHECK (tracker.dependence_visible(study_id));

REVOKE ALL ON tracker.study_durability FROM PUBLIC, hill_lead, hill_coder, hill_tiebreak, hill_agent, hill_publisher;
GRANT SELECT ON tracker.study_durability TO hill_lead, hill_coder, hill_tiebreak, hill_agent;
GRANT INSERT (study_id, measured_after_removal, measured_quote, measured_page, interval_after, effect_held, effect_quote, effect_page, note)
  ON tracker.study_durability TO hill_agent;
GRANT UPDATE (measured_after_removal, measured_quote, measured_page, interval_after, effect_held, effect_quote, effect_page, note)
  ON tracker.study_durability TO hill_agent, hill_coder, hill_lead;

-- A change to any value clears the confirmation; an agent cannot change a confirmed row.
CREATE FUNCTION tracker.guard_durability() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.measured_after_removal, NEW.measured_quote, NEW.measured_page, NEW.interval_after, NEW.effect_held, NEW.effect_quote, NEW.effect_page)
     IS DISTINCT FROM
     (OLD.measured_after_removal, OLD.measured_quote, OLD.measured_page, OLD.interval_after, OLD.effect_held, OLD.effect_quote, OLD.effect_page) THEN
    IF OLD.confirmed_by IS NOT NULL AND admin.my_login_role() = 'agent' THEN
      RAISE EXCEPTION 'A person has confirmed this Durability record; an agent cannot change it.';
    END IF;
    IF NEW.confirmed_by IS NOT DISTINCT FROM OLD.confirmed_by THEN
      NEW.confirmed_by := NULL; NEW.confirmed_at := NULL;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER guard_durability BEFORE UPDATE ON tracker.study_durability
  FOR EACH ROW EXECUTE FUNCTION tracker.guard_durability();

-- Confirmation is by a person, never an agent. One person's confirmation completes the record.
CREATE FUNCTION tracker.confirm_durability(p_study text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
BEGIN
  IF admin.my_login_role() NOT IN ('coder','lead') THEN
    RAISE EXCEPTION 'Only a coder or the lead can confirm a Durability record.';
  END IF;
  UPDATE tracker.study_durability SET confirmed_by = admin.me(), confirmed_at = now() WHERE study_id = p_study;
  IF NOT FOUND THEN RAISE EXCEPTION 'No Durability record for study %.', p_study; END IF;
END $$;
REVOKE ALL ON FUNCTION tracker.confirm_durability(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tracker.confirm_durability(text) TO hill_coder, hill_lead;

-- Public: confirmed records of released studies only. The color is worked out here, not stored:
-- green, measured and reported; yellow, measured but the result is not reported; red, not measured; gray, not applicable.
CREATE VIEW tracker.public_durability AS
SELECT d.study_id, d.measured_after_removal, d.measured_quote, d.measured_page, d.interval_after,
       d.effect_held, d.effect_quote, d.effect_page,
       CASE d.measured_after_removal WHEN 'yes' THEN 'green' WHEN 'measured, result not reported' THEN 'yellow'
                                     WHEN 'no' THEN 'red' ELSE 'gray' END AS color
FROM tracker.study_durability d JOIN tracker.released_studies USING (study_id)
WHERE d.confirmed_by IS NOT NULL;
REVOKE ALL ON tracker.public_durability FROM PUBLIC;
GRANT SELECT ON tracker.public_durability TO hill_lead, hill_publisher;

-- ----------------------------------------------------------------------
-- 3. Who was studied: the same confirmation rules as the Dependence item
-- ----------------------------------------------------------------------
-- The lead may correct a value, as a coder may.
GRANT UPDATE (w1_stage, w2_described, w3_analyzed, w4_omission_acknowledged, quotes) ON tracker.who_was_studied TO hill_lead;

-- Runs before guard_prefill (triggers fire in name order).
CREATE FUNCTION tracker.guard_who_verified() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
BEGIN
  IF (NEW.w1_stage, NEW.w2_described, NEW.w3_analyzed, NEW.w4_omission_acknowledged, NEW.quotes)
     IS DISTINCT FROM (OLD.w1_stage, OLD.w2_described, OLD.w3_analyzed, OLD.w4_omission_acknowledged, OLD.quotes) THEN
    IF OLD.verified_by IS NOT NULL AND admin.my_login_role() = 'agent' THEN
      RAISE EXCEPTION 'A person has verified this who-was-studied record; an agent cannot change it.';
    END IF;
    IF NEW.verified_by IS NOT DISTINCT FROM OLD.verified_by THEN
      NEW.verified_by := NULL; NEW.verified_at := NULL;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER guard_a_who_verified BEFORE UPDATE ON tracker.who_was_studied
  FOR EACH ROW EXECUTE FUNCTION tracker.guard_who_verified();

CREATE FUNCTION tracker.confirm_who_was_studied(p_study text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
BEGIN
  IF admin.my_login_role() NOT IN ('coder','lead') THEN
    RAISE EXCEPTION 'Only a coder or the lead can confirm a who-was-studied record.';
  END IF;
  UPDATE tracker.who_was_studied SET verified_by = admin.me(), verified_at = now() WHERE study_id = p_study;
  IF NOT FOUND THEN RAISE EXCEPTION 'No who-was-studied record for study %.', p_study; END IF;
END $$;
REVOKE ALL ON FUNCTION tracker.confirm_who_was_studied(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION tracker.confirm_who_was_studied(text) TO hill_coder, hill_lead;

-- ----------------------------------------------------------------------
-- 4. Dependence and Durability are open to coders while they code
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tracker.dependence_visible(p_study text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
  SELECT admin.my_login_role() IN ('agent','lead','coder','tiebreak')
$$;

CREATE OR REPLACE FUNCTION tracker.confirm_dependence(p_study text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
BEGIN
  IF admin.my_login_role() NOT IN ('coder','lead') THEN
    RAISE EXCEPTION 'Only a coder or the lead can confirm a Dependence record.';
  END IF;
  UPDATE tracker.study_dependence SET confirmed_by = admin.me(), confirmed_at = now() WHERE study_id = p_study;
  IF NOT FOUND THEN RAISE EXCEPTION 'No Dependence record for study %.', p_study; END IF;
END $$;

COMMIT;
