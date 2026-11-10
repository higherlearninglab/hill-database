"""HiLL database Phase 2 tests.

Part A: the 13 calibration-workbook scenarios must give the workbook's results.
Part B: permissions and safeguards from database-design-v0.1 (guarantees 1-12, D1-D3).
Runs against a local test copy only.
"""
import os
import secrets
import sys
import psycopg

# Connection comes from the standard PostgreSQL environment variables
# (PGHOST, PGPORT, PGDATABASE, PGSSLMODE). The administrator's password is read
# from PGPASSWORD or typed at a hidden prompt; it is never printed or stored.
ADMIN = os.environ.get("HILL_TEST_ADMIN", "postgres")
DB = os.environ.get("PGDATABASE", "hilltest")
if DB in ("hill", "defaultdb"):
    sys.exit("Refusing to run tests in the real database; use a scratch database.")
RESULTS = []
PREFIX = "test_"          # test sign-ins never share a name with real ones
PW = {}                   # one-time random passwords for test sign-ins, never shown


def conn(user):
    if user == "postgres":
        return psycopg.connect(user=ADMIN, dbname=DB, autocommit=True)
    login = PREFIX + user
    return psycopg.connect(user=login, password=PW.get(login), dbname=DB, autocommit=True)


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond), detail))


def expect_error(name, user, sql, params=None, contains=""):
    try:
        with conn(user) as c:
            c.execute(sql, params)
        check(name, False, "no error raised")
    except psycopg.Error as e:
        msg = str(e).split("\n")[0]
        check(name, contains.lower() in msg.lower(), msg)


def q(user, sql, params=None):
    with conn(user) as c:
        cur = c.execute(sql, params)
        return cur.fetchall() if cur.description else None


# ----------------------------------------------------------------------
# Setup: sign-ins (local only; on hill-db Gene sets the passwords herself)
# ----------------------------------------------------------------------
LOGINS = [  # db_login, person, group role, login_role
    ("gene_admin", 1, "hill_owner", "admin"),
    ("gene_lead", 1, "hill_lead", "lead"),
    ("gene_coder", 1, "hill_coder", "coder"),
    ("adam_coder", 2, "hill_coder", "coder"),
    ("third_tiebreak", 3, "hill_tiebreak", "tiebreak"),
    ("agent_claude", 4, "hill_agent", "agent"),
    ("wp_publisher", 5, "hill_publisher", "publisher"),
]
with conn("postgres") as c:
    for login, _, grp, _ in LOGINS:
        c.execute(f"DROP ROLE IF EXISTS {PREFIX}{login}")
    for login, _, grp, _ in LOGINS:
        PW[PREFIX + login] = secrets.token_urlsafe(24)
        c.execute(f"CREATE ROLE {PREFIX}{login} LOGIN PASSWORD '{PW[PREFIX + login]}' IN ROLE {grp}")
with conn("gene_admin") as c:
    c.execute("SET ROLE hill_owner")
    for pid, name, kind in [(1, "Gene Bjorn", "human"), (2, "Adam Burgasser", "human"), (3, "Third coder", "human"),
                            (4, "Claude checks", "agent"), (5, "WordPress publishing job", "service")]:
        c.execute("INSERT INTO admin.people (person_id, name, kind) VALUES (%s,%s,%s)", (pid, name, kind))
    for login, pid, _, lr in LOGINS:
        c.execute("INSERT INTO admin.logins VALUES (%s,%s,%s,true)", (PREFIX + login, pid, lr))

# ----------------------------------------------------------------------
# Part A: workbook scenarios
# ----------------------------------------------------------------------
S, SC, NS = "Supported", "Some concerns", "Not supported"
ELS = ["Claim", "Evidence", "Reasoning", "Implications", "Context"]
# id: answers, evaluated claim is Cause-effect?, marks, coder's final evaluations,
#     workbook proposed evaluations, workbook verdict, severity, context flag, proposed type, override expected
SCEN = [
    ("T1", {}, True, {}, {}, [S, S, S, S, S], "Supported", "No concerns", False, None, False),
    ("T2", {"C4": "N", "R6": "NA"}, False, {}, {"Claim": NS}, [NS, S, S, S, S], "Overstated", "Major concerns", False, "Misleading interpretation", False),
    ("T3", {"E1": "N"}, True, {}, {"Evidence": NS}, [S, NS, S, S, S], "Not supported", "Major concerns", False, None, False),
    ("T4", {"I6": "N"}, True, {}, {"Implications": NS}, [S, S, S, SC, S], "Overstated", "Minor concerns", False, "Inappropriate extrapolation", True),
    ("T5", {"X1": "N"}, True, {}, {"Context": NS}, [S, S, S, S, NS], "Partially supported", "Minor concerns", True, None, False),
    ("T6", {"E6": "NI", "X4": "NI", "R6": "NI"}, True, {}, {}, [S, S, S, S, S], "Supported", "No concerns", False, None, False),
    ("T7", {"R3": "PN"}, False, {}, {"Reasoning": SC}, [S, S, SC, S, S], "Partially supported", "Minor concerns", False, None, False),
    ("T8", {"R3": "PN"}, True, {}, {"Reasoning": NS}, [S, S, NS, S, S], "Not supported", "Major concerns", False, None, False),
    ("T9", {"C3": "N"}, True, {"mark_c3_opposite_direction": True}, {"Claim": NS}, [NS, S, S, S, S], "Overstated", "Major concerns", False, "Misleading reporting", False),
    ("T10", {"I1": "NI"}, True, {}, {"Implications": SC}, [S, S, S, SC, S], "Partially supported", "Minor concerns", False, None, False),
    ("T11", {"C1": "N", "C2": "N", "C6": "N"}, True, {}, {"Claim": NS}, [NS, S, S, S, S], "Overstated", "Major concerns", False, "Misleading reporting", False),
    ("T12", {"E8": "NA", "E2": "NI", "E3": "PN"}, True, {}, {"Evidence": SC}, [S, SC, S, S, S], "Partially supported", "Minor concerns", False, None, False),
    ("T13", {"I6": "N", "I3": "PN"}, True, {}, {"Implications": NS}, [S, S, S, NS, S], "Overstated", "Minor concerns", False, "Inappropriate extrapolation", False),
]
QCODES = [r[0] for r in q("gene_coder", "SELECT code FROM tracker.questions ORDER BY element, position")]
check("A0 36 questions loaded", len(QCODES) == 36, str(len(QCODES)))

coding_ids = {}
for n, (tid, ans, causal, marks, finals, exp_prop, exp_v, exp_s, exp_cf, exp_t, exp_override) in enumerate(SCEN, 1):
    sid = f"S9{n:03d}"
    cid = f"{sid}-C01"
    with conn("agent_claude") as c:
        c.execute("INSERT INTO tracker.studies (study_id, citation, strand) VALUES (%s,%s,'census')", (sid, f"Test study {tid}"))
    # Authors claim cause and effect; T2 has a supportable Correlation claim; T7's claim is a Correlation claim.
    ctype = "Correlation" if tid == "T7" else "Cause-effect"
    with conn("gene_coder") as c:
        c.execute("INSERT INTO tracker.claims (claim_id, study_id, main_claim, claim_type) VALUES (%s,%s,%s,%s)",
                  (cid, sid, f"Claim for {tid}", ctype))
    with conn("gene_lead") as c:
        c.execute("INSERT INTO tracker.assignments (claim_id, coder_id) VALUES (%s, 1)", (cid,))
    with conn("gene_coder") as c:
        sup = ("AI use is associated with the outcome in this sample", "Correlation") if tid == "T2" else (None, None)
        cols = {"claim_id": cid, "supportable_claim": sup[0], "supportable_claim_type": sup[1], **marks}
        coding = c.execute(f"INSERT INTO tracker.codings ({','.join(cols)}) VALUES ({','.join(['%s'] * len(cols))}) RETURNING coding_id",
                           list(cols.values())).fetchone()[0]
        coding_ids[tid] = coding
        for code in QCODES:
            c.execute("INSERT INTO tracker.answers VALUES (%s,%s,%s,NULL)", (coding, code, ans.get(code, "Y")))
        for el in ELS:
            c.execute("INSERT INTO tracker.element_evaluations VALUES (%s,%s,%s,%s,NULL)",
                      (coding, el, finals.get(el, S), f"Test rationale for {el}."))
        prop = [r[1] for r in c.execute("SELECT * FROM tracker.coding_summary(%s)", (coding,)).fetchall()]
        res = c.execute("SELECT * FROM tracker.coding_result(%s)", (coding,)).fetchone()
    check(f"{tid} proposed evaluations match workbook", prop == exp_prop, f"{prop} vs {exp_prop}")
    check(f"{tid} verdict {exp_v}", res[0] == exp_v, str(res[0]))
    check(f"{tid} severity {exp_s}", res[1] == exp_s, str(res[1]))
    check(f"{tid} context flag", res[2] == exp_cf, str(res[2]))
    check(f"{tid} proposed type", res[3] == exp_t, str(res[3]))
    att = res[5] or ""
    check(f"{tid} override note demanded only where the workbook demands it",
          ("differs from Proposed without a note" in att) == exp_override, att)

# Submission: T4 must be refused until an override note is written
expect_error("T4 submit refused without override note", "gene_coder",
             "SELECT tracker.submit_coding(%s)", (coding_ids["T4"],), "differs from Proposed without a note")
with conn("gene_coder") as c:
    c.execute("UPDATE tracker.element_evaluations SET override_note = 'Recommendation is unconditioned and generalizes beyond the sample.' "
              "WHERE coding_id = %s AND element = 'Implications'", (coding_ids["T4"],))
expect_error("Overstated coding refused without a type", "gene_coder",
             "SELECT tracker.submit_coding(%s)", (coding_ids["T4"],), "Overstated type missing")
for tid, *_rest in SCEN:
    exp_t = _rest[8]
    if _rest[5] == "Overstated":
        with conn("gene_coder") as c:
            c.execute("UPDATE tracker.codings SET overstated_type = %s WHERE coding_id = %s", (exp_t, coding_ids[tid]))
ok = 0
for tid, *_rest in SCEN:
    with conn("gene_coder") as c:
        v = c.execute("SELECT tracker.submit_coding(%s)", (coding_ids[tid],)).fetchone()[0]
        ok += v == _rest[5]
check("All 13 scenarios submit with the workbook verdict", ok == 13, f"{ok}/13")

# ----------------------------------------------------------------------
# Part B: permissions and safeguards
# ----------------------------------------------------------------------
T1 = coding_ids["T1"]
# Guarantee 1: agents cannot write appraisal fields
expect_error("G1 agent cannot write an answer", "agent_claude",
             "INSERT INTO tracker.answers VALUES (%s,'C1','Y',NULL)", (T1,), "permission denied")
expect_error("G1 agent cannot change an evaluation", "agent_claude",
             "UPDATE tracker.element_evaluations SET final_evaluation='Supported' WHERE coding_id=%s", (T1,), "permission denied")
expect_error("G1 agent cannot create a coding", "agent_claude",
             "INSERT INTO tracker.codings (claim_id) VALUES ('S9001-C01')", None, "permission denied")
expect_error("G1 agent cannot write a verdict", "agent_claude",
             "UPDATE tracker.codings SET final_verdict='Supported'", None, "permission denied")
expect_error("G1 agent cannot finalize a claim", "agent_claude",
             "SELECT tracker.finalize_claim('S9001-C01')", None, "permission denied")
expect_error("G1 lead sign-in cannot write answers", "gene_lead",
             "INSERT INTO tracker.answers VALUES (%s,'C1','Y',NULL)", (T1,), "permission denied")

# Guarantee 3: submitted codings are locked
q("gene_coder", "UPDATE tracker.answers SET answer='N' WHERE coding_id=%s AND question_code='C1'", (T1,))
q("gene_coder", "UPDATE tracker.element_evaluations SET rationale='x' WHERE coding_id=%s", (T1,))
check("G3 coder's edit of a submitted coding changes nothing",
      q("gene_coder", "SELECT answer FROM tracker.answers WHERE coding_id=%s AND question_code='C1'", (T1,)) == [("Y",)]
      and q("gene_coder", "SELECT count(*) FROM tracker.element_evaluations WHERE coding_id=%s AND rationale='x'", (T1,))[0][0] == 0)
expect_error("G3 even the administrator cannot edit a submitted answer", "gene_admin",
             "UPDATE tracker.answers SET answer='N' WHERE coding_id=%s AND question_code='C1'", (T1,), "locked")
expect_error("G3 even the administrator cannot edit a submitted evaluation", "gene_admin",
             "UPDATE tracker.element_evaluations SET rationale='x' WHERE coding_id=%s", (T1,), "locked")
expect_error("G3 coder cannot set status directly", "gene_coder",
             "UPDATE tracker.codings SET status='draft' WHERE coding_id=%s", (T1,), "permission denied")
expect_error("G3 claim wording fixed after submission", "gene_coder",
             "UPDATE tracker.claims SET main_claim='changed' WHERE claim_id='S9001-C01'", None, "fixed")

# Guarantee 6: NA only where allowed
with conn("agent_claude") as c:
    c.execute("INSERT INTO tracker.studies (study_id, citation, strand) VALUES ('S0100','Double-coded test study','census')")
with conn("gene_coder") as c:
    c.execute("INSERT INTO tracker.claims (claim_id, study_id, main_claim, claim_type) VALUES ('S0100-C01','S0100','Double-coded claim','Cause-effect')")
with conn("gene_lead") as c:
    c.execute("INSERT INTO tracker.assignments (claim_id, coder_id) VALUES ('S0100-C01',1),('S0100-C01',2)")
gene_c = q("gene_coder", "INSERT INTO tracker.codings (claim_id) VALUES ('S0100-C01') RETURNING coding_id")[0][0]
adam_c = q("adam_coder", "INSERT INTO tracker.codings (claim_id) VALUES ('S0100-C01') RETURNING coding_id")[0][0]
expect_error("G6 NA refused on C1", "gene_coder", "INSERT INTO tracker.answers VALUES (%s,'C1','NA',NULL)", (gene_c,), "NA is not allowed")
expect_error("Coder not assigned cannot code the claim", "adam_coder",
             "INSERT INTO tracker.codings (claim_id) VALUES ('S9001-C01')", None, "not assigned")


def fill(user, coding, answers, finals, note=None):
    with conn(user) as c:
        for code in QCODES:
            c.execute("INSERT INTO tracker.answers VALUES (%s,%s,%s,NULL)", (coding, code, answers.get(code, "Y")))
        for el in ELS:
            c.execute("INSERT INTO tracker.element_evaluations VALUES (%s,%s,%s,%s,%s)",
                      (coding, el, finals.get(el, S), f"Rationale for {el}.", note))


fill("gene_coder", gene_c, {}, {})
fill("adam_coder", adam_c, {"I3": "PN", "X6": "PN"}, {"Implications": SC, "Context": SC})

# Guarantee 5: incomplete codings cannot be submitted
with conn("gene_coder") as c:
    c.execute("UPDATE tracker.element_evaluations SET rationale = NULL WHERE coding_id=%s AND element='Context'", (gene_c,))
expect_error("G5 submission refused with a missing rationale", "gene_coder",
             "SELECT tracker.submit_coding(%s)", (gene_c,), "Context rationale missing")
with conn("gene_coder") as c:
    c.execute("UPDATE tracker.element_evaluations SET rationale = 'Rationale for Context.' WHERE coding_id=%s AND element='Context'", (gene_c,))

# Guarantee 2 and D1: blind coding, per person across sign-ins
check("G2 Gene (coder) cannot see Adam's draft answers",
      q("gene_coder", "SELECT count(*) FROM tracker.answers WHERE coding_id=%s", (adam_c,))[0][0] == 0)
check("G2 Gene (lead sign-in) cannot see Adam's draft",
      q("gene_lead", "SELECT count(*) FROM tracker.codings WHERE coding_id=%s", (adam_c,))[0][0] == 0)
expect_error("G2 rule functions refuse another coder's draft", "gene_coder",
             "SELECT * FROM tracker.coding_summary(%s)", (adam_c,), "not visible")
check("G2 agent cannot see unsubmitted codings",
      q("agent_claude", "SELECT count(*) FROM tracker.codings WHERE claim_id='S0100-C01'")[0][0] == 0)
q("adam_coder", "SELECT tracker.submit_coding(%s)", (adam_c,))
check("D1 after Adam submits, Gene's lead sign-in still cannot see it while Gene's own coding is a draft",
      q("gene_lead", "SELECT count(*) FROM tracker.answers WHERE coding_id=%s", (adam_c,))[0][0] == 0)
check("G2 after Adam submits, Gene (coder) still cannot see it",
      q("gene_coder", "SELECT count(*) FROM tracker.answers WHERE coding_id=%s", (adam_c,))[0][0] == 0)
check("G2 agent can see Adam's submitted coding",
      q("agent_claude", "SELECT count(*) FROM tracker.answers WHERE coding_id=%s", (adam_c,))[0][0] == 36)
check("G2 Adam cannot see Gene's draft",
      q("adam_coder", "SELECT count(*) FROM tracker.answers WHERE coding_id=%s", (gene_c,))[0][0] == 0)
q("gene_coder", "SELECT tracker.submit_coding(%s)", (gene_c,))
check("G2 once both submit, each sees the other",
      q("gene_coder", "SELECT count(*) FROM tracker.answers WHERE coding_id=%s", (adam_c,))[0][0] == 36
      and q("adam_coder", "SELECT count(*) FROM tracker.answers WHERE coding_id=%s", (gene_c,))[0][0] == 36)
check("Admin sign-in sees everything (maintenance only, logged)",
      q("gene_admin", "SELECT count(*) FROM tracker.codings")[0][0] == 15)

# Reconciliation and D2
n = q("agent_claude", "SELECT tracker.open_reconciliation('S0100-C01')")[0][0]
check("Reconciliation agenda lists the two differing elements", n == 2, str(n))
expect_error("D2 Gene (lead) cannot decide a claim she coded", "gene_lead",
             "SELECT tracker.decide_reconciliation('S0100-C01','Context','Supported','reason')", None, "cannot decide")
expect_error("D2 unassigned tie-breaker cannot decide", "third_tiebreak",
             "SELECT tracker.decide_reconciliation('S0100-C01','Context','Supported','reason')", None, "not assigned")
expect_error("D2 a coder cannot be made tie-breaker", "gene_lead",
             "SELECT tracker.assign_tiebreak('S0100-C01', 2)", None, "cannot be a coder")
r1 = q("adam_coder", "SELECT tracker.agree_reconciliation('S0100-C01','Implications','Some concerns','Extends beyond population (I3).')")[0][0]
r2 = q("gene_coder", "SELECT tracker.agree_reconciliation('S0100-C01','Implications','Some concerns','Agree: I3 unfavorable on re-read.')")[0][0]
check("Two coders agree an element", r1.startswith("proposed") and r2 == "agreed", f"{r1} / {r2}")
q("gene_lead", "SELECT tracker.assign_tiebreak('S0100-C01', 3)")
q("third_tiebreak", "SELECT tracker.decide_reconciliation('S0100-C01','Context','Supported','Framework is named in section 2.')")
v = q("gene_lead", "SELECT tracker.finalize_claim('S0100-C01')")[0][0]
check("Finalized verdict follows the reconciled evaluations", v == "Partially supported", v)

# Guarantees 7 and 8: publishing
with conn("agent_claude") as c:
    c.execute("INSERT INTO tracker.who_was_studied (study_id, w1_stage, w2_described) VALUES ('S0100','Grades 9-12','{low_income}')")
    rel = c.execute("INSERT INTO tracker.releases (summary_draft) VALUES ('Test release') RETURNING release_id").fetchone()[0]
    c.execute("INSERT INTO tracker.release_items VALUES (%s,'S0100')", (rel,))
expect_error("Unknown vulnerable-student code refused", "agent_claude",
             "UPDATE tracker.who_was_studied SET w3_analyzed='{not_a_code}' WHERE study_id='S0100'", None, "w3_codes")
check("G7 nothing public while the release is a draft", q("wp_publisher", "SELECT count(*) FROM tracker.public_census")[0][0] == 0)
expect_error("G7 agent cannot approve a release", "agent_claude", "SELECT tracker.approve_release(%s)", (rel,), "permission denied")
expect_error("G7 publisher cannot read coding tables", "wp_publisher", "SELECT * FROM tracker.codings", None, "permission denied")
expect_error("G7 publisher cannot call rule functions", "wp_publisher", "SELECT * FROM tracker.coding_summary(1)", None, "permission denied")
q("gene_lead", "SELECT tracker.approve_release(%s)", (rel,))
check("G7 approved release appears in the census", q("wp_publisher", "SELECT study_id FROM tracker.public_census") == [("S0100",)])
check("Unverified who-was-studied pre-fill stays private",
      q("wp_publisher", "SELECT count(*) FROM tracker.public_who_was_studied")[0][0] == 0)
q("gene_coder", "UPDATE tracker.who_was_studied SET verified_by = 1 WHERE study_id='S0100'")
check("Verified who-was-studied is published with its rating",
      q("wp_publisher", "SELECT rating FROM tracker.public_who_was_studied") == [("Described",)])
expect_error("Release items locked after approval", "agent_claude",
             "INSERT INTO tracker.release_items VALUES (%s,'S9001')", (rel,), "locked")
check("G8 verdicts hidden while verdicts_public is off", q("wp_publisher", "SELECT count(*) FROM tracker.public_verdicts")[0][0] == 0)
expect_error("G8 agent cannot turn verdicts on", "agent_claude", "SELECT admin.set_setting('verdicts_public','on')", None, "permission denied")
expect_error("G8 coder cannot turn verdicts on", "gene_coder", "SELECT admin.set_setting('verdicts_public','on')", None, "permission denied")
q("gene_lead", "SELECT admin.set_setting('verdicts_public','on')")
check("G8 verdicts appear once the lead turns them on",
      q("wp_publisher", "SELECT verdict, severity FROM tracker.public_verdicts") == [("Partially supported", "Minor concerns")])
q("gene_lead", "SELECT admin.set_setting('verdicts_public','off')")
q("wp_publisher", "SELECT tracker.mark_published(%s, 'wp-rev-123')", (rel,))
check("Publisher records the WordPress revision", q("gene_lead", "SELECT status, wp_revision_id FROM tracker.releases WHERE release_id=%s", (rel,)) == [("published", "wp-rev-123")])

# Flags
fid = q("agent_claude", "INSERT INTO tracker.flags (coding_id, check_type, message) VALUES (%s,'references','Reference 12 does not resolve') RETURNING flag_id", (T1,))[0][0]
expect_error("Agent cannot close a flag", "agent_claude", "UPDATE tracker.flags SET status='resolved', close_note='x' WHERE flag_id=%s", (fid,), "permission denied")
expect_error("Closing a flag needs a note", "gene_coder", "UPDATE tracker.flags SET status='resolved' WHERE flag_id=%s", (fid,), "needs a note")
q("gene_coder", "UPDATE tracker.flags SET status='resolved', close_note='Checked: DOI typo in the paper; reference exists.' WHERE flag_id=%s", (fid,))
check("A human closes a flag with a note", q("gene_lead", "SELECT status, closed_by FROM tracker.flags WHERE flag_id=%s", (fid,)) == [("resolved", 1)])

# Synthesis audit and D3
with conn("agent_claude") as c:
    c.execute("INSERT INTO tracker.studies (study_id, citation, strand) VALUES ('M0001','Test meta-analysis','synthesis audit')")
aud = q("gene_coder", "INSERT INTO tracker.audits (study_id) VALUES ('M0001') RETURNING audit_id")[0][0]
items = q("gene_coder", "SELECT code, part, agent_prefill_allowed FROM tracker.audit_items ORDER BY code")
with conn("agent_claude") as c:
    for slot in range(1, 6):
        c.execute("INSERT INTO tracker.audit_samples (audit_id, slot, primary_citation, seed, drawn_from) VALUES (%s,%s,%s,'0.42','list of 38 included studies')",
                  (aud, slot, f"Primary study {slot}"))
    c.execute("INSERT INTO tracker.audit_answers (audit_id, item_code, answer, calculation) VALUES (%s,'C1','Flag','k = 31, ES = 74')", (aud,))
expect_error("D3 agent cannot pre-fill a human-only item", "agent_claude",
             "INSERT INTO tracker.audit_answers (audit_id, item_code, answer) VALUES (%s,'B1','No flag')", (aud,), "may not pre-fill")
with conn("gene_coder") as c:
    for code, part, _ in items:
        if code == "C1":
            continue
        slots = range(1, 6) if part == "F" else [0]
        for s in slots:
            c.execute("INSERT INTO tracker.audit_answers (audit_id, item_code, sample_slot, answer) VALUES (%s,%s,%s,'No flag')", (aud, code, s))
q("agent_claude", "UPDATE tracker.audit_answers SET answer='Flag' WHERE audit_id=%s AND item_code='B1'", (aud,))
check("D3 agent cannot change a human answer",
      q("gene_coder", "SELECT answer FROM tracker.audit_answers WHERE audit_id=%s AND item_code='B1'", (aud,)) == [("No flag",)])
expect_error("G11 audit refused with an unconfirmed agent pre-fill", "gene_coder",
             "SELECT tracker.submit_audit(%s)", (aud,), "not confirmed: C1")
q("gene_coder", "SELECT tracker.confirm_prefill(%s,'C1')", (aud,))
q("gene_coder", "SELECT tracker.submit_audit(%s)", (aud,))
prof = q("gene_coder", "SELECT domain, flags FROM tracker.audit_flags_profile WHERE audit_id=%s AND flags > 0", (aud,))
check("Audit produces a flags profile by domain, no verdict", prof == [("Statistical independence", 1)], str(prof))

# Decisions, settings, double sample, reliability, admin sessions
expect_error("Agent cannot confirm a decision", "agent_claude",
             "INSERT INTO admin.decisions (decided_on, area, decision, decided_by, status) VALUES (current_date,'test','x','Gene','confirmed')", None, "permission denied")
did = q("agent_claude", "INSERT INTO admin.decisions (decided_on, area, decision, decided_by) VALUES (current_date,'test','Draft decision','Gene') RETURNING decision_id")[0][0]
q("gene_lead", "UPDATE admin.decisions SET status='confirmed' WHERE decision_id=%s", (did,))
check("Lead confirms an agent's draft decision", q("gene_lead", "SELECT status, confirmed_by FROM admin.decisions WHERE decision_id=%s", (did,)) == [("confirmed", 1)])
draws = q("gene_lead", "SELECT * FROM tracker.draw_double_sample(ARRAY['S9002-C01','S9003-C01','S9004-C01'], 0.2, 0.42)")
check("Double-coding draw is logged with its seed", len(draws) == 3 and q("gene_lead", "SELECT count(*) FROM tracker.double_samples WHERE seed=0.42")[0][0] == 3)
rows = q("gene_lead", "SELECT tracker.run_reliability('CERIC-T v0.2')")[0][0]
rel_rows = q("gene_lead", "SELECT element, n_claims, percent_agreement FROM tracker.reliability_runs ORDER BY element")
check("Reliability runs on independent submissions", rows == 5 and all(r[1] == 1 for r in rel_rows), str(rel_rows))
q("gene_admin", "SELECT admin.begin_admin_session('Phase 2 test')")
check("Administrator session logged", q("gene_lead", "SELECT count(*) FROM admin.admin_sessions")[0][0] == 1)
expect_error("Funding: a funder needs a name", "agent_claude",
             "INSERT INTO funding.funders (name) VALUES (NULL)", None, "null value")
q("agent_claude", "INSERT INTO funding.funders (name, independence_ok) VALUES ('Spencer Foundation', true)")
check("Agents edit the funding area", q("gene_lead", "SELECT count(*) FROM funding.funders")[0][0] == 1)
expect_error("Coders cannot reach the funding area", "gene_coder", "SELECT * FROM funding.funders", None, "permission denied")

# Guarantee 9: change log
expect_error("G9 change log cannot be edited (lead)", "gene_lead", "DELETE FROM admin.change_log", None, "permission denied")
expect_error("G9 change log cannot be edited (administrator)", "gene_admin", "DELETE FROM admin.change_log", None, "append-only")
logged = q("gene_lead", "SELECT count(*), count(DISTINCT db_login) FROM admin.change_log")[0]
check("G9 every change is logged with who made it", logged[0] > 500 and logged[1] >= 6, str(logged))
check("G10 every coding records its protocol version",
      q("gene_admin", "SELECT count(*) FROM tracker.codings WHERE protocol_version <> 'CERIC-T v0.2'")[0][0] == 0)

# ----------------------------------------------------------------------
# Remove the test sign-ins (roles are shared across the whole database cluster)
with conn("postgres") as c:
    for login, *_ in LOGINS:
        c.execute(f"DROP ROLE IF EXISTS {PREFIX}{login}")

passed = sum(1 for _, ok, _ in RESULTS if ok)
for name, ok, detail in RESULTS:
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  -> {detail}"))
print(f"\n{passed}/{len(RESULTS)} passed")
sys.exit(0 if passed == len(RESULTS) else 1)
