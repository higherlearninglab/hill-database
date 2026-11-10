-- HiLL database, Phase 2 build. Part 0: group roles.
-- Run once as the database administrator (doadmin on hill-db).
-- Group roles cannot sign in. Sign-in logins are created separately, one per
-- person or agent, with passwords entered by Gene directly (never in a chat).

DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['hill_owner','hill_lead','hill_coder','hill_tiebreak','hill_agent','hill_publisher'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN', r);
    END IF;
  END LOOP;
END $$;

COMMENT ON ROLE hill_owner     IS 'Owns all HiLL objects. Administrator logins are members; every administrator session is logged.';
COMMENT ON ROLE hill_lead      IS 'Lead (Gene): approves releases, decides reconciliations on claims she did not code, sets verdicts_public.';
COMMENT ON ROLE hill_coder     IS 'Human coders: write their own CERIC-T codings and synthesis audits.';
COMMENT ON ROLE hill_tiebreak  IS 'Third coder or advisory-board member deciding a reconciliation on a claim Gene coded.';
COMMENT ON ROLE hill_agent     IS 'Agents: packets, pre-fills, flags, draft studies and releases, funding, draft decisions. Never appraisal fields.';
COMMENT ON ROLE hill_publisher IS 'WordPress publishing job: reads public views of approved releases only.';

-- Let the administrator running this script act as hill_owner, and let hill_owner create schemas.
DO $$
BEGIN
  IF NOT pg_has_role(current_user, 'hill_owner', 'MEMBER') THEN
    EXECUTE format('GRANT hill_owner TO %I', current_user);
  END IF;
  EXECUTE format('GRANT CREATE ON DATABASE %I TO hill_owner', current_database());
END $$;
-- HiLL database, Phase 2 build. Part 1: schemas, types and tables.
-- Run as hill_owner (SET ROLE hill_owner). Follows infrastructure/database-design-v0.1.md.

SET ROLE hill_owner;

CREATE SCHEMA admin;
CREATE SCHEMA tracker;
CREATE SCHEMA funding;

-- ======================================================================
-- ADMIN
-- ======================================================================

CREATE TABLE admin.people (
  person_id   serial PRIMARY KEY,
  name        text NOT NULL,
  kind        text NOT NULL CHECK (kind IN ('human','agent','service')),
  role_note   text,
  started_on  date NOT NULL DEFAULT current_date,
  ended_on    date,
  active      boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE admin.people IS 'Coders, tie-breakers, agents and services. No passwords are stored here.';

-- One person can have several sign-ins (Gene: admin, lead, coder). Blinding is
-- applied per person, so all of a person''s sign-ins are blinded together.
CREATE TABLE admin.logins (
  db_login    text PRIMARY KEY,
  person_id   int NOT NULL REFERENCES admin.people,
  login_role  text NOT NULL CHECK (login_role IN ('admin','lead','coder','tiebreak','agent','publisher')),
  active      boolean NOT NULL DEFAULT true
);

CREATE TABLE admin.settings (
  key         text PRIMARY KEY,
  value       text NOT NULL,
  note        text,
  updated_by  int REFERENCES admin.people,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE admin.decisions (
  decision_id serial PRIMARY KEY,
  decided_on  date NOT NULL,
  area        text NOT NULL,
  decision    text NOT NULL,
  decided_by  text NOT NULL,
  source      text,
  status      text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','confirmed')),
  created_by  int REFERENCES admin.people,
  confirmed_by int REFERENCES admin.people,
  confirmed_at timestamptz
);

CREATE TABLE admin.admin_sessions (
  session_id  bigserial PRIMARY KEY,
  db_login    text NOT NULL,
  started_at  timestamptz NOT NULL DEFAULT now(),
  purpose     text,
  recorded_by text NOT NULL DEFAULT session_user
);
COMMENT ON TABLE admin.admin_sessions IS 'Every administrator session. Written by the connector when an admin login connects, and by admin.begin_admin_session().';

CREATE TABLE admin.change_log (
  change_id   bigserial PRIMARY KEY,
  at          timestamptz NOT NULL DEFAULT clock_timestamp(),
  db_login    text NOT NULL,
  person_id   int,
  schema_name text NOT NULL,
  table_name  text NOT NULL,
  operation   text NOT NULL,
  old_row     jsonb,
  new_row     jsonb
);
COMMENT ON TABLE admin.change_log IS 'Append-only record of every insert, update and delete in admin, tracker and funding.';

-- ======================================================================
-- TRACKER: types
-- ======================================================================

CREATE TYPE tracker.answer_code     AS ENUM ('Y','PY','PN','N','NI','NA');
CREATE TYPE tracker.ni_reading      AS ENUM ('unfavorable','neutral');
CREATE TYPE tracker.element         AS ENUM ('Claim','Evidence','Reasoning','Implications','Context');
CREATE TYPE tracker.evaluation      AS ENUM ('Supported','Some concerns','Not supported');
CREATE TYPE tracker.verdict         AS ENUM ('Supported','Partially supported','Overstated','Not supported');
CREATE TYPE tracker.severity        AS ENUM ('No concerns','Minor concerns','Major concerns');
CREATE TYPE tracker.overstated_type AS ENUM ('Misleading interpretation','Misleading reporting','Inappropriate extrapolation');
CREATE TYPE tracker.claim_type      AS ENUM ('Correlation','Cause-effect','Confirmation or refutation','Description of a phenomenon',
                                             'New resource, tool or instrument','Discovery','Methodological','New theory or update to theory');
CREATE TYPE tracker.dev_stage       AS ENUM ('Pre-K to grade 3','Grades 4-5','Grades 6-8','Grades 9-12','Undergraduate','Graduate',
                                             'Adult learners','Mixed','Not reported');

-- ======================================================================
-- TRACKER: reference tables
-- ======================================================================

CREATE TABLE tracker.protocol_versions (
  version     text PRIMARY KEY,
  instrument  text NOT NULL CHECK (instrument IN ('CERIC-T','Synthesis Audit Checklist')),
  released_on date,
  notes       text
);

CREATE TABLE tracker.questions (
  code        text PRIMARY KEY,
  element     tracker.element NOT NULL,
  position    int NOT NULL,
  wording     text NOT NULL,
  ni_reading  tracker.ni_reading NOT NULL,
  na_allowed  boolean NOT NULL DEFAULT false,
  book_section text,
  protocol_version text NOT NULL REFERENCES tracker.protocol_versions
);

CREATE TABLE tracker.audit_items (
  code        text PRIMARY KEY,
  part        char(1) NOT NULL CHECK (part BETWEEN 'A' AND 'G'),
  domain      text NOT NULL,
  wording     text NOT NULL,
  flag_when   text,
  who         text,
  agent_prefill_allowed boolean NOT NULL DEFAULT false,
  checklist_version text NOT NULL REFERENCES tracker.protocol_versions
);

CREATE TABLE tracker.vulnerable_categories (
  code        text PRIMARY KEY,
  label       text NOT NULL,
  grouping    text NOT NULL
);

-- ======================================================================
-- TRACKER: studies and claims
-- ======================================================================

CREATE TABLE tracker.studies (
  study_id    text PRIMARY KEY CHECK (study_id ~ '^[SM][0-9]{4}$'),
  citation    text NOT NULL,
  doi         text,
  year        int,
  strand      text NOT NULL CHECK (strand IN ('census','synthesis audit','attachment gap')),
  status      text NOT NULL DEFAULT 'queued'
              CHECK (status IN ('queued','holding','in coding','reconciled','released','excluded')),
  status_reason text,
  inclusion_confirmed_by int REFERENCES admin.people,
  wwc_rating  text,
  wwc_source  text,
  full_text   text NOT NULL DEFAULT 'needs PDF' CHECK (full_text IN ('have','needs PDF')),
  notes       text,
  created_by  int REFERENCES admin.people,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK (status <> 'excluded' OR status_reason IS NOT NULL)
);
COMMENT ON COLUMN tracker.studies.full_text IS 'Whether HiLL holds the PDF. Full texts are never stored in the database.';

CREATE TABLE tracker.claims (
  claim_id    text PRIMARY KEY CHECK (claim_id ~ '^[SM][0-9]{4}-C[0-9]{2}$'),
  study_id    text NOT NULL REFERENCES tracker.studies,
  main_claim  text NOT NULL,
  claim_type  tracker.claim_type NOT NULL,
  sub_claims  text[] NOT NULL DEFAULT '{}',
  secondary_claims text[] NOT NULL DEFAULT '{}',
  created_by  int REFERENCES admin.people,
  CHECK (left(claim_id, 5) = study_id)
);

CREATE TABLE tracker.assignments (
  claim_id    text NOT NULL REFERENCES tracker.claims,
  coder_id    int NOT NULL REFERENCES admin.people,
  assigned_by int REFERENCES admin.people,
  assigned_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (claim_id, coder_id)
);

-- Random draw of claims for double-coding (100% during validation, then 20%).
CREATE TABLE tracker.double_samples (
  claim_id    text PRIMARY KEY REFERENCES tracker.claims,
  rate        numeric NOT NULL CHECK (rate > 0 AND rate <= 1),
  seed        double precision NOT NULL CHECK (seed BETWEEN -1 AND 1),
  draw        double precision NOT NULL,
  selected    boolean NOT NULL,
  drawn_by    int REFERENCES admin.people,
  drawn_at    timestamptz NOT NULL DEFAULT now()
);

-- ======================================================================
-- TRACKER: coding (human only)
-- ======================================================================

CREATE TABLE tracker.codings (
  coding_id   serial PRIMARY KEY,
  claim_id    text NOT NULL REFERENCES tracker.claims,
  coder_id    int NOT NULL REFERENCES admin.people,
  protocol_version text NOT NULL REFERENCES tracker.protocol_versions,
  supportable_claim text,
  supportable_claim_type tracker.claim_type,
  -- The three conditions a coder marks by hand (protocol: C3, R7, I7)
  mark_c3_opposite_direction boolean NOT NULL DEFAULT false,
  mark_r7_fallacy_carries_claim boolean NOT NULL DEFAULT false,
  mark_i7_no_limitations boolean NOT NULL DEFAULT false,
  final_verdict  tracker.verdict,
  final_severity tracker.severity,
  overstated_type tracker.overstated_type,
  type_reason   text,
  override_note text,
  status      text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','submitted')),
  started_at  timestamptz NOT NULL DEFAULT now(),
  submitted_at timestamptz,
  UNIQUE (claim_id, coder_id),
  CHECK ((supportable_claim IS NULL) = (supportable_claim_type IS NULL))
);

CREATE TABLE tracker.answers (
  coding_id   int NOT NULL REFERENCES tracker.codings ON DELETE CASCADE,
  question_code text NOT NULL REFERENCES tracker.questions,
  answer      tracker.answer_code NOT NULL,
  note        text,
  PRIMARY KEY (coding_id, question_code)
);

CREATE TABLE tracker.element_evaluations (
  coding_id   int NOT NULL REFERENCES tracker.codings ON DELETE CASCADE,
  element     tracker.element NOT NULL,
  final_evaluation tracker.evaluation,
  rationale   text,
  override_note text,
  PRIMARY KEY (coding_id, element)
);

-- ======================================================================
-- TRACKER: reported beside the verdict (agent pre-fill, human confirms)
-- ======================================================================

CREATE TABLE tracker.who_was_studied (
  study_id    text PRIMARY KEY REFERENCES tracker.studies,
  w1_stage    tracker.dev_stage,
  w2_described text[] NOT NULL DEFAULT '{}',
  w3_analyzed  text[] NOT NULL DEFAULT '{}',
  w4_omission_acknowledged boolean,
  rating      text GENERATED ALWAYS AS (
                CASE WHEN cardinality(w3_analyzed) > 0 THEN 'Analyzed'
                     WHEN cardinality(w2_described) > 0 THEN 'Described'
                     ELSE 'Not described' END) STORED,
  quotes      jsonb NOT NULL DEFAULT '{}',
  prefilled_by int REFERENCES admin.people,
  verified_by int REFERENCES admin.people,
  verified_at timestamptz
);

CREATE TABLE tracker.durability (
  durability_id serial PRIMARY KEY,
  study_id    text NOT NULL REFERENCES tracker.studies,
  timepoint   text NOT NULL CHECK (timepoint IN ('during use','after removal','follow-up')),
  direction   text NOT NULL,
  quote       text,
  page        text,
  prefilled_by int REFERENCES admin.people,
  confirmed_by int REFERENCES admin.people,
  confirmed_at timestamptz,
  UNIQUE (study_id, timepoint)
);

-- ======================================================================
-- TRACKER: agent work
-- ======================================================================

CREATE TABLE tracker.packets (
  passage_id  serial PRIMARY KEY,
  study_id    text NOT NULL REFERENCES tracker.studies,
  topic       text NOT NULL CHECK (topic IN ('sample','instruments','AI tool','limitations','references','journal format omits Context')),
  quote       text NOT NULL,
  page        text NOT NULL,
  created_by  int REFERENCES admin.people,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE tracker.flags (
  flag_id     serial PRIMARY KEY,
  study_id    text REFERENCES tracker.studies,
  claim_id    text REFERENCES tracker.claims,
  coding_id   int REFERENCES tracker.codings,
  audit_id    int,
  check_type  text NOT NULL CHECK (check_type IN ('completeness','rule consistency','references','statistics','other')),
  message     text NOT NULL,
  evidence    text,
  raised_by   int REFERENCES admin.people,
  raised_at   timestamptz NOT NULL DEFAULT now(),
  status      text NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved','dismissed')),
  close_note  text,
  closed_by   int REFERENCES admin.people,
  closed_at   timestamptz,
  CHECK (status = 'open' OR (close_note IS NOT NULL AND closed_by IS NOT NULL))
);

CREATE TABLE tracker.reference_checks (
  check_id    serial PRIMARY KEY,
  study_id    text NOT NULL REFERENCES tracker.studies,
  reference_text text NOT NULL,
  resolved    boolean NOT NULL,
  doi         text,
  openalex_id text,
  retracted   boolean,
  checked_by  int REFERENCES admin.people,
  checked_at  timestamptz NOT NULL DEFAULT now()
);

-- ======================================================================
-- TRACKER: reconciliation and reliability
-- ======================================================================

CREATE TABLE tracker.tiebreak_assignments (
  claim_id    text NOT NULL REFERENCES tracker.claims,
  person_id   int NOT NULL REFERENCES admin.people,
  assigned_by int REFERENCES admin.people,
  PRIMARY KEY (claim_id, person_id)
);

CREATE TABLE tracker.reconciliations (
  claim_id    text NOT NULL REFERENCES tracker.claims,
  element     tracker.element NOT NULL,
  coding_a    int NOT NULL REFERENCES tracker.codings,
  coding_b    int NOT NULL REFERENCES tracker.codings,
  evaluation_a tracker.evaluation NOT NULL,
  evaluation_b tracker.evaluation NOT NULL,
  proposed_evaluation tracker.evaluation,
  proposed_by int REFERENCES admin.people,
  signoff_a   boolean NOT NULL DEFAULT false,
  signoff_b   boolean NOT NULL DEFAULT false,
  agreed_evaluation tracker.evaluation,
  reason      text,
  resolution  text CHECK (resolution IN ('agreed','decided')),
  decided_by  int REFERENCES admin.people,
  resolved_at timestamptz,
  PRIMARY KEY (claim_id, element),
  CHECK (resolution IS NULL OR (agreed_evaluation IS NOT NULL AND reason IS NOT NULL))
);

CREATE TABLE tracker.reconciled_claims (
  claim_id    text PRIMARY KEY REFERENCES tracker.claims,
  claim_eval  tracker.evaluation NOT NULL,
  evidence_eval tracker.evaluation NOT NULL,
  reasoning_eval tracker.evaluation NOT NULL,
  implications_eval tracker.evaluation NOT NULL,
  context_eval tracker.evaluation NOT NULL,
  verdict     tracker.verdict NOT NULL,
  severity    tracker.severity NOT NULL,
  context_flag boolean NOT NULL DEFAULT false,
  overstated_type tracker.overstated_type,
  supportable_claim text,
  note        text,
  protocol_version text NOT NULL REFERENCES tracker.protocol_versions,
  finalized_by int REFERENCES admin.people,
  finalized_at timestamptz NOT NULL DEFAULT now(),
  CHECK ((verdict = 'Overstated') = (overstated_type IS NOT NULL))
);

CREATE TABLE tracker.reliability_runs (
  run_id      serial PRIMARY KEY,
  run_at      timestamptz NOT NULL DEFAULT now(),
  protocol_version text NOT NULL,
  element     tracker.element NOT NULL,
  n_claims    int NOT NULL,
  percent_agreement numeric,
  kappa       numeric,
  kappa_ci_low numeric,
  kappa_ci_high numeric,
  gwet_ac2    numeric,
  override_rate numeric,
  run_by      int REFERENCES admin.people
);
COMMENT ON TABLE tracker.reliability_runs IS 'Agreement on the coders'' independent submissions, before reconciliation. Kappa CI is the large-sample approximation; AC2 uses quadratic weights.';

-- ======================================================================
-- TRACKER: synthesis audits
-- ======================================================================

CREATE TABLE tracker.audits (
  audit_id    serial PRIMARY KEY,
  study_id    text NOT NULL REFERENCES tracker.studies CHECK (study_id LIKE 'M%'),
  coder_id    int NOT NULL REFERENCES admin.people,
  checklist_version text NOT NULL REFERENCES tracker.protocol_versions,
  status      text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','submitted')),
  started_at  timestamptz NOT NULL DEFAULT now(),
  submitted_at timestamptz,
  UNIQUE (study_id, coder_id)
);

ALTER TABLE tracker.flags ADD FOREIGN KEY (audit_id) REFERENCES tracker.audits;

-- Part F is answered for five primary studies drawn at random from the synthesis.
-- The agent logs the seed and the full list drawn from (checklist, Part F).
CREATE TABLE tracker.audit_samples (
  audit_id    int NOT NULL REFERENCES tracker.audits ON DELETE CASCADE,
  slot        int NOT NULL CHECK (slot BETWEEN 1 AND 5),
  primary_citation text NOT NULL,
  seed        text NOT NULL,
  drawn_from  text NOT NULL,
  drawn_by    int REFERENCES admin.people,
  PRIMARY KEY (audit_id, slot)
);

CREATE TABLE tracker.audit_answers (
  audit_id    int NOT NULL REFERENCES tracker.audits ON DELETE CASCADE,
  item_code   text NOT NULL REFERENCES tracker.audit_items,
  sample_slot int NOT NULL DEFAULT 0 CHECK (sample_slot BETWEEN 0 AND 5),
  answer      text NOT NULL CHECK (answer IN ('Flag','No flag','Recorded','NI','NA')),
  value       text,
  note        text,
  quote       text,
  page        text,
  entered_by  int REFERENCES admin.people,
  is_prefill  boolean NOT NULL DEFAULT false,
  calculation text,
  confirmed_by int REFERENCES admin.people,
  confirmed_at timestamptz,
  PRIMARY KEY (audit_id, item_code, sample_slot),
  CHECK ((left(item_code, 1) = 'F') = (sample_slot > 0))
);

-- ======================================================================
-- TRACKER: public record
-- ======================================================================

CREATE TABLE tracker.releases (
  release_id  serial PRIMARY KEY,
  created_at  timestamptz NOT NULL DEFAULT now(),
  summary_draft text,
  prepared_by int REFERENCES admin.people,
  status      text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','approved','published')),
  approved_by int REFERENCES admin.people,
  approved_at timestamptz,
  wp_revision_id text,
  published_at timestamptz
);

CREATE TABLE tracker.release_items (
  release_id  int NOT NULL REFERENCES tracker.releases,
  study_id    text NOT NULL REFERENCES tracker.studies,
  PRIMARY KEY (release_id, study_id)
);

CREATE TABLE tracker.gap_register (
  gap_id      serial PRIMARY KEY,
  topic       text NOT NULL,
  description text NOT NULL,
  related_studies text[] NOT NULL DEFAULT '{}',
  added_on    date NOT NULL DEFAULT current_date,
  release_id  int REFERENCES tracker.releases,
  created_by  int REFERENCES admin.people
);

-- ======================================================================
-- FUNDING (agents may edit everything)
-- ======================================================================

CREATE TABLE funding.funders (
  funder_id   serial PRIMARY KEY,
  name        text NOT NULL UNIQUE,
  funder_type text,
  url         text,
  independence_ok boolean,
  independence_source text,
  notes       text
);
COMMENT ON COLUMN funding.funders.independence_ok IS 'False if the funder takes money from AI developers or edtech vendors (HiLL independence policy).';

CREATE TABLE funding.opportunities (
  opportunity_id serial PRIMARY KEY,
  funder_id   int REFERENCES funding.funders,
  program     text NOT NULL,
  amount      text,
  deadline    date,
  eligibility text,
  fit_notes   text,
  status      text NOT NULL DEFAULT 'watching'
              CHECK (status IN ('watching','preparing','submitted','awarded','declined','not pursuing')),
  next_action text,
  owner       text,
  url         text,
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE funding.contacts_log (
  entry_id    serial PRIMARY KEY,
  funder_id   int REFERENCES funding.funders,
  on_date     date NOT NULL DEFAULT current_date,
  contact     text,
  note        text NOT NULL
);
COMMENT ON TABLE funding.contacts_log IS 'Name and role only; no personal contact details.';

RESET ROLE;
-- HiLL database, Phase 2 build. Part 2: identity helpers and CERIC-T rule functions.
-- Rules follow CERIC-T protocol v0.2 and decision rules v0.2, and must reproduce
-- the calibration workbook's 13 test scenarios.

SET ROLE hill_owner;

-- ----------------------------------------------------------------------
-- Identity
-- ----------------------------------------------------------------------

CREATE FUNCTION admin.me() RETURNS int
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, admin AS $$
  SELECT person_id FROM admin.logins WHERE db_login = session_user AND active
$$;

CREATE FUNCTION admin.my_login_role() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, admin AS $$
  SELECT login_role FROM admin.logins WHERE db_login = session_user AND active
$$;

CREATE FUNCTION admin.setting(p_key text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, admin AS $$
  SELECT value FROM admin.settings WHERE key = p_key
$$;


-- ----------------------------------------------------------------------
-- Blind coding: who may see a coding
-- A person sees their own coding. A coder on a claim sees the other coder's
-- coding only after both have submitted. Leads, tie-breakers and agents who did
-- not code the claim see submitted codings only. The rule is applied per person,
-- so Gene's lead sign-in is blinded whenever Gene is coding the same claim.
-- ----------------------------------------------------------------------

CREATE FUNCTION tracker.coding_visible(p_claim text, p_coder int, p_status text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE m int := admin.me(); rl text := admin.my_login_role();
BEGIN
  IF rl IS NULL OR rl = 'publisher' THEN RETURN false; END IF;
  IF rl = 'admin' THEN RETURN true; END IF;
  IF p_coder = m THEN RETURN true; END IF;
  IF p_status <> 'submitted' THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM tracker.assignments WHERE claim_id = p_claim AND coder_id = m)
     OR EXISTS (SELECT 1 FROM tracker.codings WHERE claim_id = p_claim AND coder_id = m) THEN
    RETURN EXISTS (SELECT 1 FROM tracker.codings WHERE claim_id = p_claim AND coder_id = m AND status = 'submitted');
  END IF;
  RETURN true;
END $$;

CREATE FUNCTION tracker.coding_visible_id(p_coding int) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
  SELECT coalesce((SELECT tracker.coding_visible(claim_id, coder_id, status) FROM tracker.codings WHERE coding_id = p_coding), false)
$$;

CREATE FUNCTION tracker.assert_visible(p_coding int) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
BEGIN
  IF NOT tracker.coding_visible_id(p_coding) THEN
    RAISE EXCEPTION 'Coding % is not visible to you (blind coding)', p_coding USING ERRCODE = 'insufficient_privilege';
  END IF;
  RETURN true;
END $$;

-- ----------------------------------------------------------------------
-- Answer readings
-- ----------------------------------------------------------------------

-- Unfavorable: PN or N; NI also, where the question reads NI as unfavorable.
CREATE FUNCTION tracker.is_unf(a tracker.answer_code, r tracker.ni_reading) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT a IN ('PN','N') OR (a = 'NI' AND r = 'unfavorable')
$$;

-- The Claim type the Reasoning rule is applied to: the supportable claim's type
-- when one was written, otherwise the authors' Claim type.
CREATE FUNCTION tracker.evaluated_claim_type(p_coding int) RETURNS tracker.claim_type
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
  SELECT CASE WHEN c.supportable_claim IS NOT NULL THEN c.supportable_claim_type ELSE cl.claim_type END
  FROM tracker.codings c JOIN tracker.claims cl USING (claim_id)
  WHERE c.coding_id = p_coding
$$;

-- Unfavorable question codes for one element of one coding, and how many answered.
CREATE FUNCTION tracker._unf_codes(p_coding int, p_element tracker.element,
                                   OUT unf text[], OUT answered int, OUT total int)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
  SELECT coalesce(array_agg(q.code) FILTER (WHERE a.answer IS NOT NULL AND tracker.is_unf(a.answer, q.ni_reading)), '{}'),
         count(a.answer)::int,
         count(*)::int
  FROM tracker.questions q
  LEFT JOIN tracker.answers a ON a.question_code = q.code AND a.coding_id = p_coding
  WHERE q.element = p_element AND tracker.assert_visible(p_coding)
$$;

-- ----------------------------------------------------------------------
-- Proposed element evaluations (protocol v0.2 algorithms)
-- Return NULL until every question of the element is answered.
-- ----------------------------------------------------------------------

CREATE FUNCTION tracker.proposed_evaluation(p_coding int, p_element tracker.element) RETURNS tracker.evaluation
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
DECLARE
  u text[]; n_ans int; n_tot int; k int; c record; u2 text[];
BEGIN
  PERFORM tracker.assert_visible(p_coding);
  SELECT * INTO u, n_ans, n_tot FROM tracker._unf_codes(p_coding, p_element);
  IF n_ans < n_tot THEN RETURN NULL; END IF;
  SELECT * INTO c FROM tracker.codings WHERE coding_id = p_coding;
  k := cardinality(u);

  IF p_element = 'Claim' THEN
    IF 'C4' = ANY(u) OR k >= 3 OR ('C3' = ANY(u) AND c.mark_c3_opposite_direction) THEN RETURN 'Not supported'; END IF;
  ELSIF p_element = 'Evidence' THEN
    -- E6 reads NI as neutral, so E6 is unfavorable only when answered N or PN.
    IF 'E1' = ANY(u) OR 'E6' = ANY(u) OR 'E8' = ANY(u) OR k >= 3 THEN RETURN 'Not supported'; END IF;
  ELSIF p_element = 'Reasoning' THEN
    IF ('R3' = ANY(u) AND tracker.evaluated_claim_type(p_coding) = 'Cause-effect')
       OR 'R6' = ANY(u)
       OR ('R7' = ANY(u) AND c.mark_r7_fallacy_carries_claim)
       OR k >= 3 THEN RETURN 'Not supported'; END IF;
  ELSIF p_element = 'Implications' THEN
    u2 := array_remove(u, 'I1');           -- counts run over I2-I8
    IF ('I6' = ANY(u) AND (u && ARRAY['I3','I4','I5']))
       OR ('I7' = ANY(u) AND c.mark_i7_no_limitations)
       OR cardinality(u2) >= 3 THEN RETURN 'Not supported'; END IF;
    IF cardinality(u2) >= 1 OR 'I1' = ANY(u) THEN RETURN 'Some concerns'; END IF;
    RETURN 'Supported';
  ELSIF p_element = 'Context' THEN
    IF 'X1' = ANY(u) OR 'X3' = ANY(u) OR k >= 3 THEN RETURN 'Not supported'; END IF;
  END IF;

  IF k >= 1 THEN RETURN 'Some concerns'; END IF;
  RETURN 'Supported';
END $$;

-- ----------------------------------------------------------------------
-- Verdict, severity and Overstated type (decision rules v0.2)
-- Applied to the coder's final element evaluations.
-- ----------------------------------------------------------------------

CREATE FUNCTION tracker.derive_verdict(c tracker.evaluation, e tracker.evaluation, r tracker.evaluation,
                                       i tracker.evaluation, x tracker.evaluation) RETURNS tracker.verdict
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN c IS NULL OR e IS NULL OR r IS NULL OR i IS NULL OR x IS NULL THEN NULL
    WHEN e = 'Not supported' OR r = 'Not supported' THEN 'Not supported'         -- rule 1
    WHEN c = 'Not supported' OR i = 'Not supported' THEN 'Overstated'            -- rule 2
    WHEN x = 'Not supported' THEN 'Partially supported'                          -- rule 3 (flag context)
    WHEN 'Some concerns' IN (c, e, r, i, x) THEN 'Partially supported'           -- rule 4
    ELSE 'Supported'                                                             -- rule 5
  END::tracker.verdict
$$;

CREATE FUNCTION tracker.derive_context_flag(c tracker.evaluation, e tracker.evaluation, r tracker.evaluation,
                                            i tracker.evaluation, x tracker.evaluation) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT tracker.derive_verdict(c, e, r, i, x) = 'Partially supported' AND x = 'Not supported'
$$;

CREATE FUNCTION tracker.derive_severity(c tracker.evaluation, e tracker.evaluation, r tracker.evaluation,
                                        i tracker.evaluation, x tracker.evaluation) RETURNS tracker.severity
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN c IS NULL OR e IS NULL OR r IS NULL OR i IS NULL OR x IS NULL THEN NULL
    WHEN 'Not supported' IN (c, e, r) THEN 'Major concerns'
    WHEN c = 'Supported' AND e = 'Supported' AND r = 'Supported' AND i = 'Supported' AND x = 'Supported' THEN 'No concerns'
    ELSE 'Minor concerns'
  END::tracker.severity
$$;

-- Proposed type: from the Claim first (C4/C5, then C3/C6), otherwise from the
-- Implications (I3-I6). NULL for an Overstated verdict means the coder chooses.
CREATE FUNCTION tracker.derive_type(p_coding int, v tracker.verdict, c tracker.evaluation, i tracker.evaluation)
RETURNS tracker.overstated_type
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
DECLARE uc text[]; ui text[];
BEGIN
  IF v IS DISTINCT FROM 'Overstated' THEN RETURN NULL; END IF;
  SELECT unf INTO uc FROM tracker._unf_codes(p_coding, 'Claim');
  SELECT unf INTO ui FROM tracker._unf_codes(p_coding, 'Implications');
  IF c = 'Not supported' THEN
    IF uc && ARRAY['C4','C5'] THEN RETURN 'Misleading interpretation'; END IF;
    IF uc && ARRAY['C3','C6'] THEN RETURN 'Misleading reporting'; END IF;
    RETURN NULL;
  END IF;
  IF i = 'Not supported' AND ui && ARRAY['I3','I4','I5','I6'] THEN RETURN 'Inappropriate extrapolation'; END IF;
  RETURN NULL;
END $$;

-- ----------------------------------------------------------------------
-- Everything the coding app shows live for one coding
-- ----------------------------------------------------------------------

CREATE FUNCTION tracker.coding_summary(p_coding int)
RETURNS TABLE (
  element tracker.element, proposed tracker.evaluation, final tracker.evaluation, effective tracker.evaluation,
  has_rationale boolean, needs_override_note boolean
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
  SELECT e.el,
         tracker.proposed_evaluation(p_coding, e.el),
         ee.final_evaluation,
         coalesce(ee.final_evaluation, tracker.proposed_evaluation(p_coding, e.el)),
         coalesce(length(trim(ee.rationale)) > 0, false),
         ee.final_evaluation IS NOT NULL
           AND ee.final_evaluation IS DISTINCT FROM tracker.proposed_evaluation(p_coding, e.el)
           AND coalesce(length(trim(ee.override_note)), 0) = 0
  FROM unnest(enum_range(NULL::tracker.element)) AS e(el)
  LEFT JOIN tracker.element_evaluations ee ON ee.coding_id = p_coding AND ee.element = e.el
  WHERE tracker.assert_visible(p_coding)
  ORDER BY e.el
$$;

CREATE FUNCTION tracker.coding_result(p_coding int,
  OUT proposed_verdict tracker.verdict, OUT proposed_severity tracker.severity,
  OUT context_flag boolean, OUT proposed_type tracker.overstated_type,
  OUT needs_supportable_claim boolean, OUT attention text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
DECLARE
  c tracker.evaluation; e tracker.evaluation; r tracker.evaluation; i tracker.evaluation; x tracker.evaluation;
  cd record; s record; uc text[]; n_ans int; msg text := '';
BEGIN
  PERFORM tracker.assert_visible(p_coding);
  SELECT * INTO cd FROM tracker.codings WHERE coding_id = p_coding;
  SELECT effective INTO c FROM tracker.coding_summary(p_coding) WHERE element = 'Claim';
  SELECT effective INTO e FROM tracker.coding_summary(p_coding) WHERE element = 'Evidence';
  SELECT effective INTO r FROM tracker.coding_summary(p_coding) WHERE element = 'Reasoning';
  SELECT effective INTO i FROM tracker.coding_summary(p_coding) WHERE element = 'Implications';
  SELECT effective INTO x FROM tracker.coding_summary(p_coding) WHERE element = 'Context';
  proposed_verdict  := tracker.derive_verdict(c, e, r, i, x);
  proposed_severity := tracker.derive_severity(c, e, r, i, x);
  context_flag      := tracker.derive_context_flag(c, e, r, i, x);
  proposed_type     := tracker.derive_type(p_coding, coalesce(cd.final_verdict, proposed_verdict), c, i);
  SELECT unf INTO uc FROM tracker._unf_codes(p_coding, 'Claim');
  needs_supportable_claim := uc && ARRAY['C4','C5'];

  SELECT count(*) INTO n_ans FROM tracker.answers WHERE coding_id = p_coding;
  IF n_ans < (SELECT count(*) FROM tracker.questions) THEN
    msg := msg || format('%s of %s questions answered; ', n_ans, (SELECT count(*) FROM tracker.questions));
  END IF;
  FOR s IN SELECT * FROM tracker.coding_summary(p_coding) LOOP
    IF s.final IS NULL THEN msg := msg || s.element || ' evaluation missing; '; END IF;
    IF NOT s.has_rationale THEN msg := msg || s.element || ' rationale missing; '; END IF;
    IF s.needs_override_note THEN msg := msg || s.element || ' differs from Proposed without a note; '; END IF;
  END LOOP;
  IF needs_supportable_claim AND cd.supportable_claim IS NULL THEN msg := msg || 'supportable claim missing; '; END IF;
  IF coalesce(cd.final_verdict, proposed_verdict) = 'Overstated' AND cd.overstated_type IS NULL THEN
    msg := msg || 'Overstated type missing; ';
  END IF;
  IF cd.overstated_type IS NOT NULL AND cd.overstated_type IS DISTINCT FROM proposed_type
     AND coalesce(length(trim(cd.type_reason)), 0) = 0 THEN
    msg := msg || 'Overstated type differs from Proposed (or none proposed) without a reason; ';
  END IF;
  IF (cd.final_verdict IS NOT NULL AND cd.final_verdict IS DISTINCT FROM proposed_verdict
      OR cd.final_severity IS NOT NULL AND cd.final_severity IS DISTINCT FROM proposed_severity)
     AND coalesce(length(trim(cd.override_note)), 0) = 0 THEN
    msg := msg || 'verdict or severity override without a note; ';
  END IF;
  attention := nullif(msg, '');
END $$;

-- ----------------------------------------------------------------------
-- Reliability (validation plan): Cohen's kappa with approximate 95% CI,
-- percent agreement, Gwet's AC2 (quadratic weights), override rate.
-- Uses the coders' independent submissions, before reconciliation.
-- ----------------------------------------------------------------------

CREATE FUNCTION tracker.reliability(p_protocol text)
RETURNS TABLE (element tracker.element, n_claims int, percent_agreement numeric, kappa numeric,
               kappa_ci_low numeric, kappa_ci_high numeric, gwet_ac2 numeric, override_rate numeric)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
DECLARE
  el tracker.element; n int; po numeric; pe numeric; k numeric; se numeric;
  pa_w numeric; pe_w numeric; tw numeric; q int := 3; ov numeric;
BEGIN
  FOREACH el IN ARRAY enum_range(NULL::tracker.element) LOOP
    CREATE TEMP TABLE IF NOT EXISTS _pairs (a int, b int) ON COMMIT DROP;
    TRUNCATE _pairs;
    INSERT INTO _pairs
    SELECT array_position(enum_range(NULL::tracker.evaluation), (array_agg(ee.final_evaluation ORDER BY c.coder_id))[1]),
           array_position(enum_range(NULL::tracker.evaluation), (array_agg(ee.final_evaluation ORDER BY c.coder_id))[2])
    FROM tracker.codings c JOIN tracker.element_evaluations ee ON ee.coding_id = c.coding_id AND ee.element = el
    WHERE c.status = 'submitted' AND c.protocol_version = p_protocol
    GROUP BY c.claim_id HAVING count(*) = 2;
    -- Rater A is the coder with the lower person ID on each claim.

    SELECT count(*) INTO n FROM _pairs;
    IF n = 0 THEN CONTINUE; END IF;

    SELECT avg((a = b)::int) INTO po FROM _pairs;
    SELECT sum(pa * pb) INTO pe FROM (
      SELECT g, (SELECT count(*) FROM _pairs WHERE a = g)::numeric / n AS pa,
                (SELECT count(*) FROM _pairs WHERE b = g)::numeric / n AS pb
      FROM generate_series(1, q) g) t;
    k  := CASE WHEN pe = 1 THEN 1 ELSE (po - pe) / (1 - pe) END;
    se := CASE WHEN pe = 1 THEN 0 ELSE sqrt(po * (1 - po) / (n * (1 - pe) ^ 2)) END;

    -- Gwet AC2, quadratic weights w(k,l) = 1 - ((k-l)/(q-1))^2
    SELECT avg(1 - ((a - b)::numeric / (q - 1)) ^ 2) INTO pa_w FROM _pairs;
    SELECT sum(1 - ((g1 - g2)::numeric / (q - 1)) ^ 2) INTO tw FROM generate_series(1, q) g1, generate_series(1, q) g2;
    SELECT tw / (q * (q - 1)) * sum(pi * (1 - pi)) INTO pe_w FROM (
      SELECT ((SELECT count(*) FROM _pairs WHERE a = g) + (SELECT count(*) FROM _pairs WHERE b = g))::numeric / (2 * n) AS pi
      FROM generate_series(1, q) g) t;

    SELECT avg((ee.final_evaluation IS DISTINCT FROM tracker.proposed_evaluation(c.coding_id, el))::int) INTO ov
    FROM tracker.codings c JOIN tracker.element_evaluations ee ON ee.coding_id = c.coding_id AND ee.element = el
    WHERE c.status = 'submitted' AND c.protocol_version = p_protocol
      AND c.claim_id IN (SELECT claim_id FROM tracker.codings WHERE status = 'submitted' AND protocol_version = p_protocol
                         GROUP BY claim_id HAVING count(*) = 2);

    element := el; n_claims := n; percent_agreement := round(po, 3); kappa := round(k, 3);
    kappa_ci_low := round(k - 1.96 * se, 3); kappa_ci_high := round(k + 1.96 * se, 3);
    gwet_ac2 := round(CASE WHEN pe_w = 1 THEN 1 ELSE (pa_w - pe_w) / (1 - pe_w) END, 3);
    override_rate := round(ov, 3);
    RETURN NEXT;
  END LOOP;
END $$;

RESET ROLE;
-- HiLL database, Phase 2 build. Part 3: workflow functions, guards, change log,
-- row-level security, permissions and public views.

SET ROLE hill_owner;

-- ======================================================================
-- Defaults: record who created a row
-- ======================================================================

ALTER TABLE tracker.studies      ALTER COLUMN created_by SET DEFAULT admin.me();
ALTER TABLE tracker.claims       ALTER COLUMN created_by SET DEFAULT admin.me();
ALTER TABLE tracker.assignments  ALTER COLUMN assigned_by SET DEFAULT admin.me();
ALTER TABLE tracker.codings      ALTER COLUMN coder_id SET DEFAULT admin.me();
ALTER TABLE tracker.codings      ALTER COLUMN protocol_version SET DEFAULT admin.setting('protocol_version');
ALTER TABLE tracker.packets      ALTER COLUMN created_by SET DEFAULT admin.me();
ALTER TABLE tracker.flags        ALTER COLUMN raised_by SET DEFAULT admin.me();
ALTER TABLE tracker.reference_checks ALTER COLUMN checked_by SET DEFAULT admin.me();
ALTER TABLE tracker.audits       ALTER COLUMN coder_id SET DEFAULT admin.me();
ALTER TABLE tracker.audits       ALTER COLUMN checklist_version SET DEFAULT admin.setting('checklist_version');
ALTER TABLE tracker.releases     ALTER COLUMN prepared_by SET DEFAULT admin.me();
ALTER TABLE tracker.gap_register ALTER COLUMN created_by SET DEFAULT admin.me();
ALTER TABLE admin.decisions      ALTER COLUMN created_by SET DEFAULT admin.me();

-- ======================================================================
-- Change log (append-only)
-- ======================================================================

CREATE FUNCTION admin.log_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, admin AS $$
BEGIN
  INSERT INTO admin.change_log (db_login, person_id, schema_name, table_name, operation, old_row, new_row)
  VALUES (session_user, admin.me(), TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP,
          CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
          CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END);
  RETURN NULL;
END $$;

CREATE FUNCTION admin.block_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'The change log is append-only' USING ERRCODE = 'insufficient_privilege';
END $$;

CREATE TRIGGER change_log_append_only BEFORE UPDATE OR DELETE ON admin.change_log
  FOR EACH ROW EXECUTE FUNCTION admin.block_change();
CREATE TRIGGER change_log_no_truncate BEFORE TRUNCATE ON admin.change_log
  FOR EACH STATEMENT EXECUTE FUNCTION admin.block_change();

DO $$
DECLARE t record;
BEGIN
  FOR t IN SELECT schemaname, tablename FROM pg_tables
           WHERE schemaname IN ('admin','tracker','funding') AND tablename <> 'change_log' LOOP
    EXECUTE format('CREATE TRIGGER zz_log_change AFTER INSERT OR UPDATE OR DELETE ON %I.%I
                    FOR EACH ROW EXECUTE FUNCTION admin.log_change()', t.schemaname, t.tablename);
  END LOOP;
END $$;

CREATE FUNCTION admin.begin_admin_session(p_purpose text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, admin AS $$
BEGIN
  IF admin.my_login_role() <> 'admin' THEN RAISE EXCEPTION 'Administrator sign-ins only'; END IF;
  INSERT INTO admin.admin_sessions (db_login, purpose) VALUES (session_user, p_purpose);
END $$;

-- ======================================================================
-- Settings (lead only)
-- ======================================================================

CREATE FUNCTION admin.set_setting(p_key text, p_value text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, admin AS $$
BEGIN
  IF admin.my_login_role() NOT IN ('lead','admin') THEN
    RAISE EXCEPTION 'Only the lead can change settings' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_key = 'verdicts_public' AND p_value NOT IN ('on','off') THEN RAISE EXCEPTION 'verdicts_public must be on or off'; END IF;
  IF p_key = 'double_coding_rate' AND NOT (p_value::numeric > 0 AND p_value::numeric <= 1) THEN
    RAISE EXCEPTION 'double_coding_rate must be between 0 and 1';
  END IF;
  UPDATE admin.settings SET value = p_value, updated_by = admin.me(), updated_at = now() WHERE key = p_key;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown setting %', p_key; END IF;
END $$;

-- ======================================================================
-- Coding guards
-- ======================================================================

CREATE FUNCTION tracker.guard_coding() RETURNS trigger
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

CREATE TRIGGER guard_coding BEFORE INSERT OR UPDATE OR DELETE ON tracker.codings
  FOR EACH ROW EXECUTE FUNCTION tracker.guard_coding();

-- Answers and evaluations can change only while their coding is a draft.
CREATE FUNCTION tracker.guard_coding_child() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
DECLARE cid int := CASE WHEN TG_OP = 'DELETE' THEN OLD.coding_id ELSE NEW.coding_id END;
        st text;
BEGIN
  SELECT status INTO st FROM tracker.codings WHERE coding_id = cid;
  IF st = 'submitted' THEN
    RAISE EXCEPTION 'Coding % is submitted and locked; changes go through reconciliation', cid
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF TG_OP <> 'DELETE' AND TG_OP = 'UPDATE' AND NEW.coding_id <> OLD.coding_id THEN
    RAISE EXCEPTION 'An answer cannot be moved to another coding';
  END IF;
  -- "Not applicable" only where the protocol allows it
  IF TG_TABLE_NAME = 'answers' AND TG_OP <> 'DELETE' THEN
    IF to_jsonb(NEW) ->> 'answer' = 'NA'
       AND NOT (SELECT na_allowed FROM tracker.questions WHERE code = to_jsonb(NEW) ->> 'question_code') THEN
      RAISE EXCEPTION 'NA is not allowed on %', to_jsonb(NEW) ->> 'question_code' USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

CREATE TRIGGER guard_answers BEFORE INSERT OR UPDATE OR DELETE ON tracker.answers
  FOR EACH ROW EXECUTE FUNCTION tracker.guard_coding_child();
CREATE TRIGGER guard_evaluations BEFORE INSERT OR UPDATE OR DELETE ON tracker.element_evaluations
  FOR EACH ROW EXECUTE FUNCTION tracker.guard_coding_child();

-- A Claim's wording and type are fixed once anyone has submitted a coding of it.
CREATE FUNCTION tracker.guard_claim() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM tracker.codings WHERE claim_id = OLD.claim_id AND status = 'submitted')
     AND (NEW.main_claim IS DISTINCT FROM OLD.main_claim OR NEW.claim_type IS DISTINCT FROM OLD.claim_type) THEN
    RAISE EXCEPTION 'Claim % has a submitted coding; its wording and type are fixed', OLD.claim_id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER guard_claim BEFORE UPDATE ON tracker.claims FOR EACH ROW EXECUTE FUNCTION tracker.guard_claim();

CREATE FUNCTION tracker.owns_draft_coding(p_coding int) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
  SELECT EXISTS (SELECT 1 FROM tracker.codings
                 WHERE coding_id = p_coding AND coder_id = admin.me() AND status = 'draft')
         AND admin.my_login_role() = 'coder'
$$;

-- ======================================================================
-- Submitting a coding
-- ======================================================================

CREATE FUNCTION tracker.submit_coding(p_coding int) RETURNS tracker.verdict
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
     SET final_verdict  = coalesce(final_verdict, r.proposed_verdict),
         final_severity = coalesce(final_severity, r.proposed_severity),
         status = 'submitted', submitted_at = now()
   WHERE coding_id = p_coding;
  PERFORM set_config('hill.submitting', 'off', true);
  RETURN (SELECT final_verdict FROM tracker.codings WHERE coding_id = p_coding);
END $$;

-- ======================================================================
-- Double-coding sample (lead)
-- ======================================================================

CREATE FUNCTION tracker.draw_double_sample(p_claims text[], p_rate numeric, p_seed double precision)
RETURNS TABLE (claim_id text, selected boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE cl text; d double precision;
BEGIN
  IF admin.my_login_role() NOT IN ('lead','admin') THEN RAISE EXCEPTION 'Lead only' USING ERRCODE = 'insufficient_privilege'; END IF;
  PERFORM setseed(p_seed);
  FOREACH cl IN ARRAY (SELECT array_agg(x ORDER BY x) FROM unnest(p_claims) x) LOOP
    d := random();
    INSERT INTO tracker.double_samples (claim_id, rate, seed, draw, selected, drawn_by)
    VALUES (cl, p_rate, p_seed, d, d < p_rate, admin.me());
    claim_id := cl; selected := d < p_rate; RETURN NEXT;
  END LOOP;
END $$;

-- ======================================================================
-- Reconciliation (D2: Gene does not decide claims she coded)
-- ======================================================================

CREATE FUNCTION tracker.is_coder_of(p_claim text, p_person int) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
  SELECT EXISTS (SELECT 1 FROM tracker.codings WHERE claim_id = p_claim AND coder_id = p_person)
$$;

CREATE FUNCTION tracker.open_reconciliation(p_claim text) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE a record; b record; n int := 0; el tracker.element; ea tracker.evaluation; eb tracker.evaluation;
BEGIN
  IF admin.my_login_role() NOT IN ('lead','coder','agent','admin') THEN RAISE EXCEPTION 'Not permitted'; END IF;
  IF admin.my_login_role() = 'coder' AND NOT tracker.is_coder_of(p_claim, admin.me()) THEN
    RAISE EXCEPTION 'Only coders of this claim can open its reconciliation';
  END IF;
  SELECT * INTO a FROM tracker.codings WHERE claim_id = p_claim AND status = 'submitted' ORDER BY coder_id LIMIT 1;
  SELECT * INTO b FROM tracker.codings WHERE claim_id = p_claim AND status = 'submitted' ORDER BY coder_id OFFSET 1 LIMIT 1;
  IF b.coding_id IS NULL OR (SELECT count(*) FROM tracker.codings WHERE claim_id = p_claim) <> 2 THEN
    RAISE EXCEPTION 'Both codings of % must be submitted first', p_claim;
  END IF;
  FOREACH el IN ARRAY enum_range(NULL::tracker.element) LOOP
    SELECT final_evaluation INTO ea FROM tracker.element_evaluations WHERE coding_id = a.coding_id AND element = el;
    SELECT final_evaluation INTO eb FROM tracker.element_evaluations WHERE coding_id = b.coding_id AND element = el;
    IF ea IS DISTINCT FROM eb THEN
      INSERT INTO tracker.reconciliations (claim_id, element, coding_a, coding_b, evaluation_a, evaluation_b)
      VALUES (p_claim, el, a.coding_id, b.coding_id, ea, eb) ON CONFLICT DO NOTHING;
      n := n + 1;
    END IF;
  END LOOP;
  RETURN n;
END $$;

-- A coder of the claim proposes or accepts an evaluation; when both coders
-- have signed off on the same evaluation it is agreed.
CREATE FUNCTION tracker.agree_reconciliation(p_claim text, p_element tracker.element,
                                             p_evaluation tracker.evaluation, p_reason text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE rc record; side text; m int := admin.me();
BEGIN
  IF admin.my_login_role() <> 'coder' THEN RAISE EXCEPTION 'Coder sign-ins only' USING ERRCODE = 'insufficient_privilege'; END IF;
  SELECT * INTO rc FROM tracker.reconciliations WHERE claim_id = p_claim AND element = p_element FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'No open reconciliation for % %', p_claim, p_element; END IF;
  IF rc.resolution IS NOT NULL THEN RAISE EXCEPTION 'Already resolved'; END IF;
  IF m = (SELECT coder_id FROM tracker.codings WHERE coding_id = rc.coding_a) THEN side := 'a';
  ELSIF m = (SELECT coder_id FROM tracker.codings WHERE coding_id = rc.coding_b) THEN side := 'b';
  ELSE RAISE EXCEPTION 'Only the two coders of % can agree a reconciliation', p_claim USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF coalesce(length(trim(p_reason)), 0) = 0 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  IF rc.proposed_evaluation IS DISTINCT FROM p_evaluation THEN
    UPDATE tracker.reconciliations
       SET proposed_evaluation = p_evaluation, reason = p_reason, proposed_by = m,
           signoff_a = (side = 'a'), signoff_b = (side = 'b')
     WHERE claim_id = p_claim AND element = p_element;
    RETURN 'proposed; waiting for the other coder';
  END IF;
  UPDATE tracker.reconciliations
     SET signoff_a = signoff_a OR side = 'a', signoff_b = signoff_b OR side = 'b'
   WHERE claim_id = p_claim AND element = p_element;
  UPDATE tracker.reconciliations
     SET agreed_evaluation = proposed_evaluation, resolution = 'agreed', resolved_at = now()
   WHERE claim_id = p_claim AND element = p_element AND signoff_a AND signoff_b;
  RETURN CASE WHEN FOUND THEN 'agreed' ELSE 'signed off; waiting for the other coder' END;
END $$;

CREATE FUNCTION tracker.assign_tiebreak(p_claim text, p_person int) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
BEGIN
  IF admin.my_login_role() NOT IN ('lead','admin') THEN RAISE EXCEPTION 'Lead only' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF tracker.is_coder_of(p_claim, p_person) THEN RAISE EXCEPTION 'A tie-breaker cannot be a coder of the claim'; END IF;
  INSERT INTO tracker.tiebreak_assignments (claim_id, person_id, assigned_by) VALUES (p_claim, p_person, admin.me());
END $$;

CREATE FUNCTION tracker.decide_reconciliation(p_claim text, p_element tracker.element,
                                              p_evaluation tracker.evaluation, p_reason text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE m int := admin.me(); rl text := admin.my_login_role();
BEGIN
  IF rl NOT IN ('lead','tiebreak') THEN RAISE EXCEPTION 'Only the lead or an assigned tie-breaker decides' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF tracker.is_coder_of(p_claim, m) THEN
    RAISE EXCEPTION 'You coded % and cannot decide its reconciliation; assign a tie-breaker', p_claim
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF rl = 'tiebreak' AND NOT EXISTS (SELECT 1 FROM tracker.tiebreak_assignments WHERE claim_id = p_claim AND person_id = m) THEN
    RAISE EXCEPTION 'You are not assigned as tie-breaker for %', p_claim USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF coalesce(length(trim(p_reason)), 0) = 0 THEN RAISE EXCEPTION 'A reason is required'; END IF;
  UPDATE tracker.reconciliations
     SET agreed_evaluation = p_evaluation, reason = p_reason, resolution = 'decided', decided_by = m, resolved_at = now()
   WHERE claim_id = p_claim AND element = p_element AND resolution IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'No open reconciliation for % %', p_claim, p_element; END IF;
END $$;

-- Records the claim's final result once every disagreement is resolved.
-- A single-coded claim (not drawn for double-coding) is finalized from its one coding.
CREATE FUNCTION tracker.finalize_claim(p_claim text, p_type tracker.overstated_type DEFAULT NULL,
                                       p_supportable text DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS tracker.verdict
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE
  rl text := admin.my_login_role(); n_sub int; n_all int; el tracker.element; ev tracker.evaluation;
  ev_all tracker.evaluation[] := '{}'; v tracker.verdict; sv tracker.severity; t tracker.overstated_type; sc text;
  pv text;
BEGIN
  IF rl NOT IN ('lead','coder') THEN RAISE EXCEPTION 'Lead or coder only' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF rl = 'coder' AND NOT tracker.is_coder_of(p_claim, admin.me()) THEN RAISE EXCEPTION 'Not a coder of %', p_claim; END IF;
  SELECT count(*) FILTER (WHERE status = 'submitted'), count(*) INTO n_sub, n_all FROM tracker.codings WHERE claim_id = p_claim;
  IF n_sub = 0 OR n_sub <> n_all THEN RAISE EXCEPTION 'All codings of % must be submitted', p_claim; END IF;
  IF n_sub = 1 AND EXISTS (SELECT 1 FROM tracker.double_samples WHERE claim_id = p_claim AND selected) THEN
    RAISE EXCEPTION '% was drawn for double-coding; it needs a second coding', p_claim;
  END IF;
  FOREACH el IN ARRAY enum_range(NULL::tracker.element) LOOP
    SELECT CASE WHEN count(DISTINCT ee.final_evaluation) = 1 THEN min(ee.final_evaluation)
                ELSE (SELECT agreed_evaluation FROM tracker.reconciliations r WHERE r.claim_id = p_claim AND r.element = el) END
      INTO ev
      FROM tracker.codings c JOIN tracker.element_evaluations ee ON ee.coding_id = c.coding_id AND ee.element = el
     WHERE c.claim_id = p_claim;
    IF ev IS NULL THEN RAISE EXCEPTION '% on % is not reconciled yet', el, p_claim; END IF;
    ev_all := ev_all || ev;
  END LOOP;
  v  := tracker.derive_verdict(ev_all[1], ev_all[2], ev_all[3], ev_all[4], ev_all[5]);
  sv := tracker.derive_severity(ev_all[1], ev_all[2], ev_all[3], ev_all[4], ev_all[5]);
  t := p_type;
  IF v = 'Overstated' AND t IS NULL THEN
    SELECT CASE WHEN count(DISTINCT overstated_type) = 1 AND count(overstated_type) = count(*) THEN min(overstated_type) END
      INTO t FROM tracker.codings WHERE claim_id = p_claim;
    IF t IS NULL THEN RAISE EXCEPTION 'Overstated: the coders chose different types; give the agreed type'; END IF;
  END IF;
  IF v <> 'Overstated' THEN t := NULL; END IF;
  sc := p_supportable;
  IF sc IS NULL THEN
    SELECT CASE WHEN count(DISTINCT supportable_claim) = 1 THEN min(supportable_claim) END INTO sc
      FROM tracker.codings WHERE claim_id = p_claim AND supportable_claim IS NOT NULL;
  END IF;
  pv := (SELECT protocol_version FROM tracker.codings WHERE claim_id = p_claim LIMIT 1);
  INSERT INTO tracker.reconciled_claims (claim_id, claim_eval, evidence_eval, reasoning_eval, implications_eval, context_eval,
                                         verdict, severity, context_flag, overstated_type, supportable_claim, note,
                                         protocol_version, finalized_by)
  VALUES (p_claim, ev_all[1], ev_all[2], ev_all[3], ev_all[4], ev_all[5], v, sv,
          tracker.derive_context_flag(ev_all[1], ev_all[2], ev_all[3], ev_all[4], ev_all[5]),
          t, sc, p_note, pv, admin.me());
  RETURN v;
END $$;

CREATE FUNCTION tracker.run_reliability(p_protocol text) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE n int;
BEGIN
  IF admin.my_login_role() NOT IN ('lead','agent','admin') THEN RAISE EXCEPTION 'Lead or agent only'; END IF;
  INSERT INTO tracker.reliability_runs (protocol_version, element, n_claims, percent_agreement, kappa,
                                        kappa_ci_low, kappa_ci_high, gwet_ac2, override_rate, run_by)
  SELECT p_protocol, r.element, r.n_claims, r.percent_agreement, r.kappa, r.kappa_ci_low, r.kappa_ci_high,
         r.gwet_ac2, r.override_rate, admin.me()
  FROM tracker.reliability(p_protocol) r;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- ======================================================================
-- Pre-fills: agents fill, humans confirm
-- ======================================================================

CREATE FUNCTION tracker.guard_prefill() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE rl text := admin.my_login_role();
BEGIN
  IF rl = 'agent' THEN
    NEW.prefilled_by := admin.me();
    -- Any agent change clears a human confirmation.
    IF TG_TABLE_NAME = 'who_was_studied' THEN NEW.verified_by := NULL; NEW.verified_at := NULL;
    ELSE NEW.confirmed_by := NULL; NEW.confirmed_at := NULL; END IF;
  ELSE
    IF TG_TABLE_NAME = 'who_was_studied' THEN
      IF NEW.verified_by IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.verified_by IS DISTINCT FROM OLD.verified_by) THEN
        IF NEW.verified_by <> admin.me() THEN RAISE EXCEPTION 'You can confirm only as yourself'; END IF;
        NEW.verified_at := now();
      END IF;
    ELSE
      IF NEW.confirmed_by IS NOT NULL AND (TG_OP = 'INSERT' OR NEW.confirmed_by IS DISTINCT FROM OLD.confirmed_by) THEN
        IF NEW.confirmed_by <> admin.me() THEN RAISE EXCEPTION 'You can confirm only as yourself'; END IF;
        NEW.confirmed_at := now();
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER guard_prefill BEFORE INSERT OR UPDATE ON tracker.who_was_studied FOR EACH ROW EXECUTE FUNCTION tracker.guard_prefill();
CREATE TRIGGER guard_prefill BEFORE INSERT OR UPDATE ON tracker.durability      FOR EACH ROW EXECUTE FUNCTION tracker.guard_prefill();

-- Flags: anyone may raise; only a human closes, with a note.
CREATE FUNCTION tracker.guard_flag() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.raised_by := admin.me(); NEW.status := 'open'; NEW.closed_by := NULL; NEW.close_note := NULL; NEW.closed_at := NULL;
    RETURN NEW;
  END IF;
  IF admin.my_login_role() NOT IN ('coder','lead','tiebreak') THEN
    RAISE EXCEPTION 'Only a human can close a flag' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NEW.status <> 'open' THEN
    IF coalesce(length(trim(NEW.close_note)), 0) = 0 THEN RAISE EXCEPTION 'Closing a flag needs a note'; END IF;
    NEW.closed_by := admin.me(); NEW.closed_at := now();
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER guard_flag BEFORE INSERT OR UPDATE ON tracker.flags FOR EACH ROW EXECUTE FUNCTION tracker.guard_flag();

-- ======================================================================
-- Synthesis audits (D3)
-- ======================================================================

CREATE FUNCTION tracker.audit_visible_row(p_study text, p_coder int, p_status text) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE m int := admin.me(); rl text := admin.my_login_role();
BEGIN
  IF rl IS NULL OR rl = 'publisher' THEN RETURN false; END IF;
  IF rl = 'admin' OR p_coder = m THEN RETURN true; END IF;
  IF p_status <> 'submitted' THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM tracker.audits WHERE study_id = p_study AND coder_id = m) THEN
    RETURN EXISTS (SELECT 1 FROM tracker.audits WHERE study_id = p_study AND coder_id = m AND status = 'submitted');
  END IF;
  RETURN true;
END $$;

CREATE FUNCTION tracker.audit_visible(p_audit int) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
  SELECT coalesce((SELECT tracker.audit_visible_row(study_id, coder_id, status) FROM tracker.audits WHERE audit_id = p_audit), false)
$$;

CREATE FUNCTION tracker.guard_audit_answer() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE rl text := admin.my_login_role(); a record;
BEGIN
  SELECT * INTO a FROM tracker.audits WHERE audit_id = CASE WHEN TG_OP = 'DELETE' THEN OLD.audit_id ELSE NEW.audit_id END;
  IF a.status = 'submitted' THEN RAISE EXCEPTION 'Audit % is submitted and locked', a.audit_id USING ERRCODE = 'insufficient_privilege'; END IF;
  IF TG_OP = 'DELETE' THEN
    IF rl = 'agent' AND NOT OLD.is_prefill THEN RAISE EXCEPTION 'Agents cannot remove a human answer' USING ERRCODE = 'insufficient_privilege'; END IF;
    RETURN OLD;
  END IF;
  IF rl = 'agent' THEN
    IF NOT (SELECT agent_prefill_allowed FROM tracker.audit_items WHERE code = NEW.item_code) THEN
      RAISE EXCEPTION 'Agents may not pre-fill item %', NEW.item_code USING ERRCODE = 'insufficient_privilege';
    END IF;
    IF TG_OP = 'UPDATE' AND NOT OLD.is_prefill THEN
      RAISE EXCEPTION 'Agents cannot change a human answer' USING ERRCODE = 'insufficient_privilege';
    END IF;
    NEW.is_prefill := true; NEW.entered_by := admin.me(); NEW.confirmed_by := NULL; NEW.confirmed_at := NULL;
  ELSE
    IF a.coder_id <> admin.me() THEN RAISE EXCEPTION 'Only the audit''s coder can answer it' USING ERRCODE = 'insufficient_privilege'; END IF;
    IF current_setting('hill.confirming', true) = 'on' THEN
      RETURN NEW;   -- tracker.confirm_prefill
    END IF;
    -- A coder's own entry, or an edit of an agent's pre-fill, is a human answer.
    NEW.is_prefill := false; NEW.entered_by := admin.me(); NEW.confirmed_by := NULL; NEW.confirmed_at := NULL;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER guard_audit_answer BEFORE INSERT OR UPDATE OR DELETE ON tracker.audit_answers
  FOR EACH ROW EXECUTE FUNCTION tracker.guard_audit_answer();

CREATE FUNCTION tracker.guard_audit_sample() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
BEGIN
  IF (SELECT status FROM tracker.audits WHERE audit_id = CASE WHEN TG_OP = 'DELETE' THEN OLD.audit_id ELSE NEW.audit_id END) = 'submitted' THEN
    RAISE EXCEPTION 'Audit is submitted and locked';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER guard_audit_sample BEFORE INSERT OR UPDATE OR DELETE ON tracker.audit_samples
  FOR EACH ROW EXECUTE FUNCTION tracker.guard_audit_sample();

CREATE FUNCTION tracker.confirm_prefill(p_audit int, p_item text, p_slot int DEFAULT 0) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
BEGIN
  IF admin.my_login_role() <> 'coder' OR (SELECT coder_id FROM tracker.audits WHERE audit_id = p_audit) <> admin.me() THEN
    RAISE EXCEPTION 'Only the audit''s coder can confirm a pre-fill' USING ERRCODE = 'insufficient_privilege';
  END IF;
  PERFORM set_config('hill.confirming', 'on', true);
  UPDATE tracker.audit_answers SET confirmed_by = admin.me(), confirmed_at = now()
   WHERE audit_id = p_audit AND item_code = p_item AND sample_slot = p_slot AND is_prefill;
  IF NOT FOUND THEN RAISE EXCEPTION 'No agent pre-fill for % on audit %', p_item, p_audit; END IF;
  PERFORM set_config('hill.confirming', 'off', true);
END $$;

CREATE FUNCTION tracker.submit_audit(p_audit int) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
DECLARE a record; missing text; unconfirmed text;
BEGIN
  SELECT * INTO a FROM tracker.audits WHERE audit_id = p_audit;
  IF NOT FOUND OR a.coder_id <> admin.me() OR admin.my_login_role() <> 'coder' THEN
    RAISE EXCEPTION 'Only the coder can submit their own audit' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF (SELECT count(*) FROM tracker.audit_samples WHERE audit_id = p_audit) <> 5 THEN
    RAISE EXCEPTION 'Cannot submit audit %: Part F needs five sampled primary studies', p_audit USING ERRCODE = 'check_violation';
  END IF;
  SELECT string_agg(need.label, ', ' ORDER BY need.label) INTO missing FROM (
    SELECT i.code AS label, i.code, 0 AS slot FROM tracker.audit_items i
     WHERE i.checklist_version = a.checklist_version AND i.part <> 'F'
    UNION ALL
    SELECT i.code || ' (study ' || sm.slot || ')', i.code, sm.slot FROM tracker.audit_items i
      CROSS JOIN tracker.audit_samples sm
     WHERE i.checklist_version = a.checklist_version AND i.part = 'F' AND sm.audit_id = p_audit
  ) need
  WHERE NOT EXISTS (SELECT 1 FROM tracker.audit_answers x
                    WHERE x.audit_id = p_audit AND x.item_code = need.code AND x.sample_slot = need.slot);
  SELECT string_agg(item_code || CASE WHEN sample_slot > 0 THEN ' (study ' || sample_slot || ')' ELSE '' END, ', ' ORDER BY item_code, sample_slot)
    INTO unconfirmed FROM tracker.audit_answers
   WHERE audit_id = p_audit AND is_prefill AND confirmed_by IS NULL;
  IF missing IS NOT NULL OR unconfirmed IS NOT NULL THEN
    RAISE EXCEPTION 'Cannot submit audit %: %', p_audit,
      coalesce('items unanswered: ' || missing || '; ', '') || coalesce('agent pre-fills not confirmed: ' || unconfirmed, '')
      USING ERRCODE = 'check_violation';
  END IF;
  UPDATE tracker.audits SET status = 'submitted', submitted_at = now() WHERE audit_id = p_audit;
END $$;

CREATE FUNCTION tracker.guard_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN NEW.status := 'draft'; RETURN NEW; END IF;
  IF OLD.status = 'submitted' THEN RAISE EXCEPTION 'Audit % is submitted and locked', OLD.audit_id; END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER guard_audit BEFORE INSERT OR UPDATE OR DELETE ON tracker.audits FOR EACH ROW EXECUTE FUNCTION tracker.guard_audit();

-- ======================================================================
-- Releases (Gene approves)
-- ======================================================================

CREATE FUNCTION tracker.guard_release() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
DECLARE st text;
BEGIN
  IF TG_TABLE_NAME = 'releases' THEN
    IF TG_OP = 'INSERT' THEN NEW.status := 'draft'; NEW.approved_by := NULL; NEW.approved_at := NULL; RETURN NEW; END IF;
    IF current_setting('hill.releasing', true) IS DISTINCT FROM 'on'
       AND (NEW.status IS DISTINCT FROM OLD.status OR NEW.approved_by IS DISTINCT FROM OLD.approved_by
            OR NEW.wp_revision_id IS DISTINCT FROM OLD.wp_revision_id) THEN
      RAISE EXCEPTION 'Use tracker.approve_release() or tracker.mark_published()';
    END IF;
    IF OLD.status <> 'draft' AND current_setting('hill.releasing', true) IS DISTINCT FROM 'on' THEN
      RAISE EXCEPTION 'Release % is approved and locked', OLD.release_id;
    END IF;
    RETURN NEW;
  END IF;
  SELECT status INTO st FROM tracker.releases WHERE release_id = CASE WHEN TG_OP = 'DELETE' THEN OLD.release_id ELSE NEW.release_id END;
  IF st <> 'draft' THEN RAISE EXCEPTION 'Release is approved and locked'; END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER guard_release BEFORE INSERT OR UPDATE ON tracker.releases FOR EACH ROW EXECUTE FUNCTION tracker.guard_release();
CREATE TRIGGER guard_release BEFORE INSERT OR UPDATE OR DELETE ON tracker.release_items FOR EACH ROW EXECUTE FUNCTION tracker.guard_release();

CREATE FUNCTION tracker.approve_release(p_release int) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
BEGIN
  IF admin.my_login_role() <> 'lead' THEN RAISE EXCEPTION 'Only the lead approves releases' USING ERRCODE = 'insufficient_privilege'; END IF;
  IF NOT EXISTS (SELECT 1 FROM tracker.release_items WHERE release_id = p_release)
     AND NOT EXISTS (SELECT 1 FROM tracker.gap_register WHERE release_id = p_release) THEN
    RAISE EXCEPTION 'Release % is empty', p_release;
  END IF;
  PERFORM set_config('hill.releasing', 'on', true);
  UPDATE tracker.releases SET status = 'approved', approved_by = admin.me(), approved_at = now()
   WHERE release_id = p_release AND status = 'draft';
  IF NOT FOUND THEN RAISE EXCEPTION 'Release % is not a draft', p_release; END IF;
  PERFORM set_config('hill.releasing', 'off', true);
END $$;

CREATE FUNCTION tracker.mark_published(p_release int, p_wp_revision text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker, admin AS $$
BEGIN
  IF admin.my_login_role() NOT IN ('publisher','lead') THEN RAISE EXCEPTION 'Publisher only' USING ERRCODE = 'insufficient_privilege'; END IF;
  PERFORM set_config('hill.releasing', 'on', true);
  UPDATE tracker.releases SET status = 'published', wp_revision_id = p_wp_revision, published_at = now()
   WHERE release_id = p_release AND status = 'approved';
  IF NOT FOUND THEN RAISE EXCEPTION 'Release % is not approved', p_release; END IF;
  PERFORM set_config('hill.releasing', 'off', true);
END $$;

-- Gap-register entries become public only through an approved release.
CREATE FUNCTION tracker.guard_gap() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
BEGIN
  IF NEW.release_id IS DISTINCT FROM OLD.release_id
     AND (SELECT status FROM tracker.releases WHERE release_id = coalesce(NEW.release_id, OLD.release_id)) <> 'draft' THEN
    RAISE EXCEPTION 'Gap entries can be added to or removed from draft releases only';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER guard_gap BEFORE UPDATE ON tracker.gap_register FOR EACH ROW EXECUTE FUNCTION tracker.guard_gap();

-- Decisions: agents draft, the lead confirms.
CREATE FUNCTION admin.guard_decision() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, admin AS $$
BEGIN
  IF admin.my_login_role() = 'agent' THEN
    IF TG_OP = 'UPDATE' AND OLD.status = 'confirmed' THEN RAISE EXCEPTION 'Confirmed decisions cannot be changed by agents'; END IF;
    NEW.status := 'draft'; NEW.confirmed_by := NULL; NEW.confirmed_at := NULL;
  ELSIF NEW.status = 'confirmed' AND (TG_OP = 'INSERT' OR OLD.status = 'draft') THEN
    NEW.confirmed_by := admin.me(); NEW.confirmed_at := now();
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER guard_decision BEFORE INSERT OR UPDATE ON admin.decisions FOR EACH ROW EXECUTE FUNCTION admin.guard_decision();

-- ======================================================================
-- Internal views (apply the caller's row-level security)
-- ======================================================================

CREATE VIEW tracker.question_splits WITH (security_invoker = true) AS
WITH r AS (
  SELECT c.claim_id, c.protocol_version, a.question_code,
         CASE WHEN a.answer IN ('Y','PY') THEN 'favorable'
              WHEN tracker.is_unf(a.answer, q.ni_reading) THEN 'unfavorable' ELSE 'neutral' END AS reading
  FROM tracker.codings c
  JOIN tracker.answers a ON a.coding_id = c.coding_id
  JOIN tracker.questions q ON q.code = a.question_code
  WHERE c.status = 'submitted'
)
SELECT protocol_version, question_code, count(*) AS claims_split, count(*) >= 3 AS flag_for_rewording
FROM (SELECT claim_id, protocol_version, question_code FROM r
      GROUP BY 1, 2, 3 HAVING count(*) = 2 AND count(DISTINCT reading) = 2) s
GROUP BY 1, 2;

CREATE VIEW tracker.audit_flags_profile WITH (security_invoker = true) AS
SELECT au.audit_id, au.study_id, au.coder_id, au.status, i.part, i.domain,
       count(*) FILTER (WHERE x.answer = 'Flag') AS flags,
       count(x.item_code) AS items_answered,
       count(*) AS items
FROM tracker.audits au
JOIN tracker.audit_items i ON i.checklist_version = au.checklist_version
LEFT JOIN tracker.audit_answers x ON x.audit_id = au.audit_id AND x.item_code = i.code
GROUP BY 1, 2, 3, 4, 5, 6;
COMMENT ON VIEW tracker.audit_flags_profile IS 'Flags profile by domain. No overall verdict (checklist reporting rule).';

-- ======================================================================
-- Public views (read by the publishing job; approved releases only)
-- ======================================================================

CREATE VIEW tracker.released_studies AS
SELECT DISTINCT ri.study_id FROM tracker.release_items ri
JOIN tracker.releases r ON r.release_id = ri.release_id
WHERE r.status IN ('approved','published');

CREATE VIEW tracker.public_census AS
SELECT s.study_id, s.citation, s.doi, s.year, s.strand, s.status, s.wwc_rating, s.wwc_source
FROM tracker.studies s JOIN tracker.released_studies USING (study_id)
WHERE s.status <> 'holding';

CREATE VIEW tracker.public_holding_queue AS
SELECT s.study_id, s.citation, s.doi, s.year, s.strand, s.status_reason
FROM tracker.studies s JOIN tracker.released_studies USING (study_id)
WHERE s.status = 'holding';

CREATE VIEW tracker.public_who_was_studied AS
SELECT w.study_id, w.w1_stage, w.w2_described, w.w3_analyzed, w.w4_omission_acknowledged, w.rating
FROM tracker.who_was_studied w JOIN tracker.released_studies USING (study_id)
WHERE w.verified_by IS NOT NULL;

CREATE VIEW tracker.public_durability AS
SELECT d.study_id, d.timepoint, d.direction
FROM tracker.durability d JOIN tracker.released_studies USING (study_id)
WHERE d.confirmed_by IS NOT NULL;

CREATE VIEW tracker.public_gap_register AS
SELECT g.gap_id, g.topic, g.description, g.related_studies, g.added_on
FROM tracker.gap_register g JOIN tracker.releases r ON r.release_id = g.release_id
WHERE r.status IN ('approved','published');

CREATE VIEW tracker.public_verdicts AS
SELECT rc.claim_id, cl.study_id, cl.main_claim, rc.verdict, rc.severity, rc.context_flag, rc.overstated_type,
       rc.supportable_claim, rc.claim_eval, rc.evidence_eval, rc.reasoning_eval, rc.implications_eval, rc.context_eval,
       rc.protocol_version
FROM tracker.reconciled_claims rc
JOIN tracker.claims cl USING (claim_id)
JOIN tracker.released_studies USING (study_id)
WHERE admin.setting('verdicts_public') = 'on';

-- ======================================================================
-- Row-level security
-- ======================================================================

ALTER TABLE tracker.codings ENABLE ROW LEVEL SECURITY;
CREATE POLICY see ON tracker.codings FOR SELECT USING (tracker.coding_visible(claim_id, coder_id, status));
CREATE POLICY add ON tracker.codings FOR INSERT WITH CHECK (coder_id = admin.me() AND admin.my_login_role() = 'coder');
CREATE POLICY edit ON tracker.codings FOR UPDATE USING (coder_id = admin.me() AND admin.my_login_role() = 'coder');
CREATE POLICY remove ON tracker.codings FOR DELETE USING (coder_id = admin.me() AND admin.my_login_role() = 'coder' AND status = 'draft');

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['answers','element_evaluations'] LOOP
    EXECUTE format('ALTER TABLE tracker.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('CREATE POLICY see ON tracker.%I FOR SELECT USING (tracker.coding_visible_id(coding_id))', t);
    EXECUTE format('CREATE POLICY add ON tracker.%I FOR INSERT WITH CHECK (tracker.owns_draft_coding(coding_id))', t);
    EXECUTE format('CREATE POLICY edit ON tracker.%I FOR UPDATE USING (tracker.owns_draft_coding(coding_id)) WITH CHECK (tracker.owns_draft_coding(coding_id))', t);
    EXECUTE format('CREATE POLICY remove ON tracker.%I FOR DELETE USING (tracker.owns_draft_coding(coding_id))', t);
  END LOOP;
END $$;

ALTER TABLE tracker.audits ENABLE ROW LEVEL SECURITY;
CREATE POLICY see ON tracker.audits FOR SELECT USING (tracker.audit_visible_row(study_id, coder_id, status) OR admin.my_login_role() = 'agent');
CREATE POLICY add ON tracker.audits FOR INSERT WITH CHECK (coder_id = admin.me() AND admin.my_login_role() = 'coder');
CREATE POLICY edit ON tracker.audits FOR UPDATE USING (coder_id = admin.me() AND admin.my_login_role() = 'coder');

ALTER TABLE tracker.audit_answers ENABLE ROW LEVEL SECURITY;
CREATE POLICY see ON tracker.audit_answers FOR SELECT
  USING (tracker.audit_visible(audit_id) OR (admin.my_login_role() = 'agent' AND is_prefill));
CREATE POLICY add ON tracker.audit_answers FOR INSERT WITH CHECK (admin.my_login_role() IN ('coder','agent'));
CREATE POLICY edit ON tracker.audit_answers FOR UPDATE
  USING ((admin.my_login_role() = 'coder' AND (SELECT coder_id FROM tracker.audits a WHERE a.audit_id = audit_answers.audit_id) = admin.me())
         OR (admin.my_login_role() = 'agent' AND is_prefill));
CREATE POLICY remove ON tracker.audit_answers FOR DELETE
  USING ((admin.my_login_role() = 'coder' AND (SELECT coder_id FROM tracker.audits a WHERE a.audit_id = audit_answers.audit_id) = admin.me())
         OR (admin.my_login_role() = 'agent' AND is_prefill));

-- ======================================================================
-- Permissions
-- ======================================================================

REVOKE ALL ON SCHEMA admin, tracker, funding FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA admin, tracker, funding FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA admin, tracker, funding FROM PUBLIC;

GRANT USAGE ON SCHEMA admin, tracker TO hill_lead, hill_coder, hill_tiebreak, hill_agent, hill_publisher;
GRANT USAGE ON SCHEMA funding TO hill_lead, hill_agent;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA admin, tracker, funding TO hill_lead, hill_coder, hill_agent;

-- Functions everyone signed in may call (each checks the caller inside)
GRANT EXECUTE ON FUNCTION admin.me(), admin.my_login_role(), admin.setting(text),
  tracker.is_unf(tracker.answer_code, tracker.ni_reading),
  tracker.coding_visible(text, int, text), tracker.coding_visible_id(int), tracker.assert_visible(int),
  tracker.owns_draft_coding(int), tracker.audit_visible(int), tracker.audit_visible_row(text, int, text)
  TO hill_lead, hill_coder, hill_tiebreak, hill_agent, hill_publisher;
GRANT EXECUTE ON FUNCTION tracker.derive_verdict(tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation),
  tracker.derive_severity(tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation),
  tracker.derive_context_flag(tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation, tracker.evaluation),
  tracker.proposed_evaluation(int, tracker.element), tracker.evaluated_claim_type(int),
  tracker.coding_summary(int), tracker.coding_result(int)
  TO hill_lead, hill_coder, hill_tiebreak, hill_agent;
GRANT EXECUTE ON FUNCTION tracker.submit_coding(int), tracker.agree_reconciliation(text, tracker.element, tracker.evaluation, text),
  tracker.confirm_prefill(int, text, int), tracker.submit_audit(int) TO hill_coder;
GRANT EXECUTE ON FUNCTION tracker.open_reconciliation(text) TO hill_lead, hill_coder, hill_agent;
GRANT EXECUTE ON FUNCTION tracker.finalize_claim(text, tracker.overstated_type, text, text) TO hill_lead, hill_coder;
GRANT EXECUTE ON FUNCTION tracker.decide_reconciliation(text, tracker.element, tracker.evaluation, text) TO hill_lead, hill_tiebreak;
GRANT EXECUTE ON FUNCTION tracker.assign_tiebreak(text, int), tracker.draw_double_sample(text[], numeric, double precision),
  tracker.approve_release(int), admin.set_setting(text, text) TO hill_lead;
GRANT EXECUTE ON FUNCTION tracker.run_reliability(text), tracker.reliability(text) TO hill_lead, hill_agent;
GRANT EXECUTE ON FUNCTION tracker.mark_published(int, text) TO hill_publisher, hill_lead;

-- Admin area
GRANT SELECT ON admin.people, admin.settings TO hill_lead, hill_coder, hill_tiebreak, hill_agent;
GRANT SELECT ON admin.change_log, admin.admin_sessions, admin.logins TO hill_lead;
GRANT SELECT ON admin.decisions TO hill_lead, hill_coder, hill_agent;
GRANT INSERT (decided_on, area, decision, decided_by, source),
      UPDATE (decided_on, area, decision, decided_by, source) ON admin.decisions TO hill_agent;
GRANT INSERT, UPDATE ON admin.decisions TO hill_lead;

-- Reference tables: read only (changed by the administrator with a protocol update)
GRANT SELECT ON tracker.protocol_versions, tracker.questions, tracker.audit_items, tracker.vulnerable_categories
  TO hill_lead, hill_coder, hill_tiebreak, hill_agent;

-- Everything in the tracker is readable by lead, coders, tie-breakers and agents;
-- row-level security hides unsubmitted codings and audits.
GRANT SELECT ON ALL TABLES IN SCHEMA tracker TO hill_lead, hill_coder, hill_tiebreak, hill_agent;
REVOKE SELECT ON tracker.public_census, tracker.public_holding_queue, tracker.public_who_was_studied,
  tracker.public_durability, tracker.public_gap_register, tracker.public_verdicts, tracker.released_studies
  FROM hill_coder, hill_tiebreak, hill_agent;

-- Studies: agents draft; the lead confirms inclusion and sets status
GRANT INSERT (study_id, citation, doi, year, strand, wwc_rating, wwc_source, full_text, notes),
      UPDATE (citation, doi, year, wwc_rating, wwc_source, full_text, notes) ON tracker.studies TO hill_agent;
GRANT INSERT, UPDATE ON tracker.studies TO hill_lead;

-- Claims and assignments
GRANT INSERT (claim_id, study_id, main_claim, claim_type, sub_claims, secondary_claims),
      UPDATE (main_claim, claim_type, sub_claims, secondary_claims) ON tracker.claims TO hill_coder, hill_lead;
GRANT INSERT, DELETE ON tracker.assignments TO hill_lead;

-- Coding: coders only. Status changes only through tracker.submit_coding().
GRANT INSERT (claim_id, supportable_claim, supportable_claim_type, mark_c3_opposite_direction,
              mark_r7_fallacy_carries_claim, mark_i7_no_limitations, final_verdict, final_severity,
              overstated_type, type_reason, override_note),
      UPDATE (supportable_claim, supportable_claim_type, mark_c3_opposite_direction,
              mark_r7_fallacy_carries_claim, mark_i7_no_limitations, final_verdict, final_severity,
              overstated_type, type_reason, override_note),
      DELETE ON tracker.codings TO hill_coder;
GRANT INSERT, UPDATE, DELETE ON tracker.answers, tracker.element_evaluations TO hill_coder;

-- Reported beside the verdict: agents pre-fill, coders confirm
GRANT INSERT (study_id, w1_stage, w2_described, w3_analyzed, w4_omission_acknowledged, quotes),
      UPDATE (w1_stage, w2_described, w3_analyzed, w4_omission_acknowledged, quotes) ON tracker.who_was_studied TO hill_agent;
GRANT INSERT (study_id, w1_stage, w2_described, w3_analyzed, w4_omission_acknowledged, quotes, verified_by),
      UPDATE (w1_stage, w2_described, w3_analyzed, w4_omission_acknowledged, quotes, verified_by) ON tracker.who_was_studied TO hill_coder;
GRANT INSERT (study_id, timepoint, direction, quote, page),
      UPDATE (direction, quote, page) ON tracker.durability TO hill_agent;
GRANT INSERT (study_id, timepoint, direction, quote, page, confirmed_by),
      UPDATE (direction, quote, page, confirmed_by) ON tracker.durability TO hill_coder;

-- Agent work
GRANT INSERT (study_id, topic, quote, page) ON tracker.packets TO hill_agent, hill_coder;
GRANT INSERT (study_id, claim_id, coding_id, audit_id, check_type, message, evidence) ON tracker.flags
  TO hill_agent, hill_coder, hill_lead;
GRANT UPDATE (status, close_note) ON tracker.flags TO hill_coder, hill_lead, hill_tiebreak;
GRANT INSERT, UPDATE ON tracker.reference_checks TO hill_agent;

-- Synthesis audits
GRANT INSERT (study_id) ON tracker.audits TO hill_coder;
GRANT INSERT (audit_id, item_code, sample_slot, answer, value, note, quote, page),
      UPDATE (answer, value, note, quote, page), DELETE ON tracker.audit_answers TO hill_coder;
GRANT INSERT (audit_id, item_code, sample_slot, answer, value, note, quote, page, calculation),
      UPDATE (answer, value, note, quote, page, calculation), DELETE ON tracker.audit_answers TO hill_agent;
-- The agent draws and logs the Part F sample while the audit is a draft.
GRANT INSERT (audit_id, slot, primary_citation, seed, drawn_from) ON tracker.audit_samples TO hill_agent;
ALTER TABLE tracker.audit_samples ALTER COLUMN drawn_by SET DEFAULT admin.me();

-- Releases and gap register
GRANT INSERT (summary_draft), UPDATE (summary_draft) ON tracker.releases TO hill_agent, hill_lead;
GRANT INSERT, DELETE ON tracker.release_items TO hill_agent, hill_lead;
GRANT INSERT (topic, description, related_studies, release_id),
      UPDATE (topic, description, related_studies, release_id) ON tracker.gap_register TO hill_lead;

-- Publishing job: public views only
GRANT SELECT ON tracker.public_census, tracker.public_holding_queue, tracker.public_who_was_studied,
  tracker.public_durability, tracker.public_gap_register, tracker.public_verdicts TO hill_publisher;

-- Funding: agents and the lead may edit everything
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA funding TO hill_agent, hill_lead;

RESET ROLE;
-- HiLL database, Phase 2 build. Part 4: reference data and settings.
-- Question and checklist wording is not in this file. It is loaded separately from a
-- private file (05_wording_private.sql) and is not published until HiLL releases the codebook.
-- Until then each question's wording field holds its code.
SET ROLE hill_owner;

INSERT INTO tracker.protocol_versions (version, instrument, released_on, notes) VALUES
  ('CERIC-T v0.2', 'CERIC-T', '2026-11-09', 'Draft for review; not yet piloted. evidence-tracker/ceric-t-protocol-v0.2-draft.md'),
  ('SAC v0.1', 'Synthesis Audit Checklist', '2026-11-09', 'evidence-tracker/synthesis-audit-checklist-v0.1.md');

INSERT INTO tracker.questions (code, element, position, wording, ni_reading, na_allowed, book_section, protocol_version) VALUES
  ('C1', 'Claim', 1, 'C1', 'unfavorable', false, '3.1', 'CERIC-T v0.2'),
  ('C2', 'Claim', 2, 'C2', 'unfavorable', true, '3.4', 'CERIC-T v0.2'),
  ('C3', 'Claim', 3, 'C3', 'unfavorable', false, '3.3; 10.2.3', 'CERIC-T v0.2'),
  ('C4', 'Claim', 4, 'C4', 'unfavorable', false, '3.2; 5.1.4', 'CERIC-T v0.2'),
  ('C5', 'Claim', 5, 'C5', 'unfavorable', false, '4.3; 10.2.2', 'CERIC-T v0.2'),
  ('C6', 'Claim', 6, 'C6', 'unfavorable', false, '10.2.1', 'CERIC-T v0.2'),
  ('E1', 'Evidence', 1, 'E1', 'unfavorable', false, '4.3; 10.2.2', 'CERIC-T v0.2'),
  ('E2', 'Evidence', 2, 'E2', 'unfavorable', false, '4.1', 'CERIC-T v0.2'),
  ('E3', 'Evidence', 3, 'E3', 'unfavorable', false, '4.1; 10.3.3', 'CERIC-T v0.2'),
  ('E4', 'Evidence', 4, 'E4', 'unfavorable', false, '4.1; 10.3.3', 'CERIC-T v0.2'),
  ('E5', 'Evidence', 5, 'E5', 'unfavorable', false, '10.2; 10.2.2', 'CERIC-T v0.2'),
  ('E6', 'Evidence', 6, 'E6', 'neutral', false, '10.2.2', 'CERIC-T v0.2'),
  ('E7', 'Evidence', 7, 'E7', 'unfavorable', false, '5.4.3; 5.2.3.2', 'CERIC-T v0.2'),
  ('E8', 'Evidence', 8, 'E8', 'unfavorable', true, 'tracker', 'CERIC-T v0.2'),
  ('R1', 'Reasoning', 1, 'R1', 'unfavorable', false, '5.4.3', 'CERIC-T v0.2'),
  ('R2', 'Reasoning', 2, 'R2', 'unfavorable', false, '5.4.3; 10.2.3', 'CERIC-T v0.2'),
  ('R3', 'Reasoning', 3, 'R3', 'unfavorable', false, '5.4.3', 'CERIC-T v0.2'),
  ('R4', 'Reasoning', 4, 'R4', 'unfavorable', false, '5.4.3', 'CERIC-T v0.2'),
  ('R5', 'Reasoning', 5, 'R5', 'unfavorable', false, '5.4.3', 'CERIC-T v0.2'),
  ('R6', 'Reasoning', 6, 'R6', 'neutral', true, '5.4.3; 5.1.4', 'CERIC-T v0.2'),
  ('R7', 'Reasoning', 7, 'R7', 'unfavorable', false, '5.2.3.2; 10.2.3', 'CERIC-T v0.2'),
  ('R8', 'Reasoning', 8, 'R8', 'unfavorable', false, '5.1.2', 'CERIC-T v0.2'),
  ('I1', 'Implications', 1, 'I1', 'unfavorable', false, '6.1; 6.3.1', 'CERIC-T v0.2'),
  ('I2', 'Implications', 2, 'I2', 'unfavorable', false, '6.1.1', 'CERIC-T v0.2'),
  ('I3', 'Implications', 3, 'I3', 'unfavorable', false, '6.2.4; 10.2.4', 'CERIC-T v0.2'),
  ('I4', 'Implications', 4, 'I4', 'unfavorable', false, '10.2.4', 'CERIC-T v0.2'),
  ('I5', 'Implications', 5, 'I5', 'unfavorable', false, '6.2.4', 'CERIC-T v0.2'),
  ('I6', 'Implications', 6, 'I6', 'neutral', true, '10.2.4', 'CERIC-T v0.2'),
  ('I7', 'Implications', 7, 'I7', 'unfavorable', false, '10.2.4; 10.3.2', 'CERIC-T v0.2'),
  ('I8', 'Implications', 8, 'I8', 'neutral', true, '10.2.4', 'CERIC-T v0.2'),
  ('X1', 'Context', 1, 'X1', 'unfavorable', false, '7.1; 7.3', 'CERIC-T v0.2'),
  ('X2', 'Context', 2, 'X2', 'unfavorable', true, '7.2.4; 10.2.5', 'CERIC-T v0.2'),
  ('X3', 'Context', 3, 'X3', 'neutral', true, '10.2.5', 'CERIC-T v0.2'),
  ('X4', 'Context', 4, 'X4', 'neutral', false, '10.2.5', 'CERIC-T v0.2'),
  ('X5', 'Context', 5, 'X5', 'unfavorable', false, '10.2.5', 'CERIC-T v0.2'),
  ('X6', 'Context', 6, 'X6', 'unfavorable', false, '10.2.5', 'CERIC-T v0.2');

-- agent_prefill_allowed: items whose checklist 'who' column names an agent. Every agent entry is a
-- pre-fill that a human must confirm before the audit can be submitted (decision D3).
INSERT INTO tracker.audit_items (code, part, domain, wording, flag_when, who, agent_prefill_allowed, checklist_version) VALUES
  ('A1', 'A', 'Record', 'A1', NULL, NULL, true, 'SAC v0.1'),
  ('A2', 'A', 'Record', 'A2', NULL, NULL, true, 'SAC v0.1'),
  ('A3', 'A', 'Record', 'A3', NULL, NULL, true, 'SAC v0.1'),
  ('A4', 'A', 'Record', 'A4', NULL, NULL, true, 'SAC v0.1'),
  ('B1', 'B', 'Construct validity', 'B1', NULL, NULL, false, 'SAC v0.1'),
  ('B2', 'B', 'Construct validity', 'B2', NULL, NULL, false, 'SAC v0.1'),
  ('B3', 'B', 'Construct validity', 'B3', NULL, NULL, true, 'SAC v0.1'),
  ('B4', 'B', 'Construct validity', 'B4', NULL, NULL, true, 'SAC v0.1'),
  ('B5', 'B', 'Construct validity', 'B5', NULL, NULL, true, 'SAC v0.1'),
  ('C1', 'C', 'Statistical independence', 'C1', NULL, NULL, true, 'SAC v0.1'),
  ('C2', 'C', 'Statistical independence', 'C2', NULL, NULL, true, 'SAC v0.1'),
  ('C3', 'C', 'Statistical independence', 'C3', NULL, NULL, true, 'SAC v0.1'),
  ('D1', 'D', 'Heterogeneity and moderators', 'D1', NULL, NULL, true, 'SAC v0.1'),
  ('D2', 'D', 'Heterogeneity and moderators', 'D2', NULL, NULL, true, 'SAC v0.1'),
  ('D3', 'D', 'Heterogeneity and moderators', 'D3', NULL, NULL, true, 'SAC v0.1'),
  ('D4', 'D', 'Heterogeneity and moderators', 'D4', NULL, NULL, true, 'SAC v0.1'),
  ('D5', 'D', 'Heterogeneity and moderators', 'D5', NULL, NULL, false, 'SAC v0.1'),
  ('D6', 'D', 'Heterogeneity and moderators', 'D6', NULL, NULL, true, 'SAC v0.1'),
  ('D7', 'D', 'Heterogeneity and moderators', 'D7', NULL, NULL, true, 'SAC v0.1'),
  ('D8', 'D', 'Heterogeneity and moderators', 'D8', NULL, NULL, true, 'SAC v0.1'),
  ('D9', 'D', 'Heterogeneity and moderators', 'D9', NULL, NULL, false, 'SAC v0.1'),
  ('E1', 'E', 'Publication bias', 'E1', NULL, NULL, true, 'SAC v0.1'),
  ('E2', 'E', 'Publication bias', 'E2', NULL, NULL, true, 'SAC v0.1'),
  ('E3', 'E', 'Publication bias', 'E3', NULL, NULL, true, 'SAC v0.1'),
  ('E4', 'E', 'Publication bias', 'E4', NULL, NULL, true, 'SAC v0.1'),
  ('E5', 'E', 'Publication bias', 'E5', NULL, NULL, true, 'SAC v0.1'),
  ('E6', 'E', 'Publication bias', 'E6', NULL, NULL, true, 'SAC v0.1'),
  ('E7', 'E', 'Publication bias', 'E7', NULL, NULL, true, 'SAC v0.1'),
  ('E8', 'E', 'Publication bias', 'E8', NULL, NULL, true, 'SAC v0.1'),
  ('F1', 'F', 'Primary-study sample', 'F1', NULL, NULL, false, 'SAC v0.1'),
  ('F2', 'F', 'Primary-study sample', 'F2', NULL, NULL, false, 'SAC v0.1'),
  ('F3', 'F', 'Primary-study sample', 'F3', NULL, NULL, true, 'SAC v0.1'),
  ('F4', 'F', 'Primary-study sample', 'F4', NULL, NULL, true, 'SAC v0.1'),
  ('F5', 'F', 'Primary-study sample', 'F5', NULL, NULL, false, 'SAC v0.1'),
  ('F6', 'F', 'Primary-study sample', 'F6', NULL, NULL, true, 'SAC v0.1'),
  ('F7', 'F', 'Primary-study sample', 'F7', NULL, NULL, true, 'SAC v0.1'),
  ('F8', 'F', 'Primary-study sample', 'F8', NULL, NULL, true, 'SAC v0.1'),
  ('G1', 'G', 'HiLL additions', 'G1', NULL, NULL, true, 'SAC v0.1'),
  ('G2', 'G', 'HiLL additions', 'G2', NULL, NULL, false, 'SAC v0.1'),
  ('G3', 'G', 'HiLL additions', 'G3', NULL, NULL, true, 'SAC v0.1'),
  ('G4', 'G', 'HiLL additions', 'G4', NULL, NULL, true, 'SAC v0.1'),
  ('G5', 'G', 'HiLL additions', 'G5', NULL, NULL, true, 'SAC v0.1'),
  ('G6', 'G', 'HiLL additions', 'G6', NULL, NULL, true, 'SAC v0.1');

INSERT INTO tracker.vulnerable_categories (code, label, grouping) VALUES
  ('disability_iep', 'Students with disabilities receiving special education', 'Disability and learning differences'),
  ('disability_504', 'Students with disabilities under Section 504 / ADA', 'Disability and learning differences'),
  ('neurodivergent', 'Neurodivergent students', 'Disability and learning differences'),
  ('english_learner', 'English learners / multilingual learners', 'Language'),
  ('low_income', 'Students from low-income households', 'Economic and housing circumstances'),
  ('basic_needs_insecure', 'Food- or housing-insecure students', 'Economic and housing circumstances'),
  ('homeless', 'Students experiencing homelessness', 'Economic and housing circumstances'),
  ('migratory', 'Migratory students', 'Economic and housing circumstances'),
  ('foster_care', 'Foster youth and foster care alumni', 'Care and system involvement'),
  ('justice_involved', 'Justice-involved students', 'Care and system involvement'),
  ('military_connected', 'Military-connected students', 'Care and system involvement'),
  ('racially_minoritized', 'Racially and ethnically minoritized students', 'Identity-based marginalization'),
  ('lgbtq', 'LGBTQ+ students', 'Identity-based marginalization'),
  ('immigrant_undocumented', 'Immigrant, refugee and undocumented students', 'Identity-based marginalization'),
  ('rural', 'Rural students', 'Identity-based marginalization'),
  ('first_generation', 'First-generation college students', 'Educational pathway'),
  ('international', 'International students', 'Educational pathway'),
  ('student_parent', 'Student parents', 'Educational pathway'),
  ('nontraditional', 'Nontraditional students', 'Educational pathway'),
  ('low_prior_achievement', 'Students with low prior achievement', 'Educational pathway'),
  ('mental_health', 'Students with mental health needs', 'Health and social connection'),
  ('socially_isolated', 'Lonely or socially isolated students', 'Health and social connection');

-- W2 and W3 may hold only codes from the list
CREATE FUNCTION tracker.valid_categories(c text[]) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, tracker AS $$
  SELECT NOT EXISTS (SELECT 1 FROM unnest(c) x WHERE x NOT IN (SELECT code FROM tracker.vulnerable_categories))
$$;
ALTER TABLE tracker.who_was_studied
  ADD CONSTRAINT w2_codes CHECK (tracker.valid_categories(w2_described)),
  ADD CONSTRAINT w3_codes CHECK (tracker.valid_categories(w3_analyzed));
GRANT EXECUTE ON FUNCTION tracker.valid_categories(text[]) TO hill_lead, hill_coder, hill_agent;

INSERT INTO admin.settings (key, value, note) VALUES
  ('verdicts_public', 'off', 'Verdicts, severity and types are hidden from the public views until v1.0. Only the lead can change this.'),
  ('protocol_version', 'CERIC-T v0.2', 'Version new codings are recorded under'),
  ('checklist_version', 'SAC v0.1', 'Version new synthesis audits are recorded under'),
  ('double_coding_rate', '1.0', '100% during validation; 0.2 once reliability is established');

RESET ROLE;
