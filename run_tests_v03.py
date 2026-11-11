"""HiLL database tests for CERIC-T v0.3 and the five-rating scale.

Run against a scratch database built from hill-db-phase2.sql, hill-db-v03.sql, hill-db-rating-scale.sql
and hill-db-no-rating-override.sql, in that order.

Part A: rule scenarios for protocol and decision rules v0.3 (half rule, triggers, CER summary, tier, the five ratings).
Part B: permissions and safeguards (guarantees 1-12, D1-D3).
Part C: what v0.3 adds (versions side by side, S1 and tier reconciliation, publication status, no rating override).
Runs against a scratch copy only.
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
# Part A: rule scenarios (v0.3)
# ----------------------------------------------------------------------
S, SC, NS = "Supported", "Some concerns", "Not supported"
ELS = ["Claim", "Evidence", "Reasoning", "Implications", "Context"]
CE, CO, DE = "Cause-effect", "Correlation", "Description of a phenomenon"
MI, MR, IE = "Misleading interpretation", "Misleading reporting", "Inappropriate extrapolation"
WHY = "The Claim as stated goes beyond what the Evidence and Reasoning support."
def U(*codes, a="N"):
    return {c: a for c in codes}
# id, what it shows, answers, claim type, marks, supportable claim written?, S1, S1 reason, coder's final evaluations,
#   expected proposed evaluations, rating, severity, context flag, proposed type, override note expected
SCEN = [
 ("V01", "all favorable", {}, CE, {}, False, "Y", None, {}, [S, S, S, S, S], "Supported", "No concerns", False, None, False),
 ("V02", "C4 with S1 No: narrower Claim supported", {"C4": "N", "R6": "NA"}, CE, {}, True, "N", WHY, {"Claim": NS}, [NS, S, S, S, S], "Overstated", "Major concerns", False, None, False),
 ("V03", "C4 with S1 Probably yes: Claim Not supported", {"C4": "N", "R6": "NA"}, CE, {}, True, "PY", "The causal wording appears once; elsewhere the Claim is stated as an association.", {"Claim": NS}, [NS, S, S, S, S], "Overstated", "Major concerns", False, MI, False),
 ("V04", "E1 alone", U("E1"), CE, {}, False, "N", WHY, {"Evidence": NS}, [S, NS, S, S, S], "Not supported", "Major concerns", False, None, False),
 ("V05", "E2 alone", U("E2", a="PN"), CE, {}, False, "PN", WHY, {"Evidence": NS}, [S, NS, S, S, S], "Not supported", "Major concerns", False, None, False),
 ("V06", "E7 No information is neutral", U("E7", a="NI"), CE, {}, False, "Y", None, {}, [S, S, S, S, S], "Supported", "No concerns", False, None, False),
 ("V07", "E7 Probably no", U("E7", a="PN"), CE, {}, False, "N", WHY, {"Evidence": NS}, [S, NS, S, S, S], "Not supported", "Major concerns", False, None, False),
 ("V08", "E9 alone", U("E9"), CE, {}, False, "N", WHY, {"Evidence": NS}, [S, NS, S, S, S], "Not supported", "Major concerns", False, None, False),
 ("V09", "E6 for a Correlation Claim", {"E6": "PN", "R6": "NA"}, CO, {}, False, "PY", None, {"Evidence": SC}, [S, SC, S, S, S], "Supported with concerns", "Minor concerns", False, None, False),
 ("V10", "E6 for a Cause-effect Claim", U("E6", a="PN"), CE, {}, False, "N", WHY, {"Evidence": NS}, [S, NS, S, S, S], "Not supported", "Major concerns", False, None, False),
 ("V11", "E10 for a Cause-effect Claim", U("E10"), CE, {}, False, "N", WHY, {"Evidence": NS}, [S, NS, S, S, S], "Not supported", "Major concerns", False, None, False),
 ("V12", "E10 for a Correlation Claim", {"E10": "N", "R6": "NA"}, CO, {}, False, "Y", None, {"Evidence": SC}, [S, SC, S, S, S], "Supported with concerns", "Minor concerns", False, None, False),
 ("V13", "E9, E10, R6 Not applicable for a Description Claim", {"E9": "NA", "E10": "NA", "R6": "NA"}, DE, {}, False, "Y", None, {}, [S, S, S, S, S], "Supported", "No concerns", False, None, False),
 ("V14", "Evidence 4 of 10: below half", {**U("E3", "E4", "E5", "E8"), "R6": "NA"}, CO, {}, False, "PY", None, {"Evidence": SC}, [S, SC, S, S, S], "Supported with concerns", "Minor concerns", False, None, False),
 ("V15", "Evidence 5 of 10: half rule", {**U("E3", "E4", "E5", "E6", "E8"), "R6": "NA"}, CO, {}, False, "N", WHY, {"Evidence": NS}, [S, NS, S, S, S], "Not supported", "Major concerns", False, None, False),
 ("V16", "Claim 3 of 7: below half", U("C1", "C2", "C6"), CE, {}, False, "Y", None, {"Claim": SC}, [SC, S, S, S, S], "Supported with concerns", "Minor concerns", False, None, False),
 ("V17", "Claim 4 of 7: half rule", U("C1", "C2", "C6", "C7"), CE, {}, False, "Y", None, {"Claim": NS}, [NS, S, S, S, S], "Overstated", "Major concerns", False, MR, False),
 ("V18", "C3 with the opposite-direction mark", U("C3"), CE, {"mark_c3_opposite_direction": True}, False, "PY", None, {"Claim": NS}, [NS, S, S, S, S], "Overstated", "Major concerns", False, MR, False),
 ("V19", "C7 is an ordinary question", U("C7"), CE, {}, False, "Y", None, {"Claim": SC}, [SC, S, S, S, S], "Supported with concerns", "Minor concerns", False, None, False),
 ("V20", "R3 for a Correlation Claim", {"R3": "PN", "R6": "NA"}, CO, {}, False, "Y", None, {"Reasoning": SC}, [S, S, SC, S, S], "Supported with concerns", "Minor concerns", False, None, False),
 ("V21", "R3 for a Cause-effect Claim", U("R3", a="PN"), CE, {}, False, "N", WHY, {"Reasoning": NS}, [S, S, NS, S, S], "Not supported", "Major concerns", False, None, False),
 ("V22", "R6 No information is neutral", U("R6", a="NI"), CE, {}, False, "Y", None, {}, [S, S, S, S, S], "Supported", "No concerns", False, None, False),
 ("V23", "R6 No", U("R6"), CE, {}, False, "N", WHY, {"Reasoning": NS}, [S, S, NS, S, S], "Not supported", "Major concerns", False, None, False),
 ("V24", "Reasoning 3 of 8: below half", U("R1", "R2", "R4"), CE, {}, False, "PY", None, {"Reasoning": SC}, [S, S, SC, S, S], "Supported with concerns", "Minor concerns", False, None, False),
 ("V25", "Reasoning 4 of 8: half rule", U("R1", "R2", "R4", "R5"), CE, {}, False, "N", WHY, {"Reasoning": NS}, [S, S, NS, S, S], "Not supported", "Major concerns", False, None, False),
 ("V26", "R7 with the fallacy mark", U("R7"), CE, {"mark_r7_fallacy_carries_claim": True}, False, "N", WHY, {"Reasoning": NS}, [S, S, NS, S, S], "Not supported", "Major concerns", False, None, False),
 ("V27", "I6 alone; coder overrides Implications to Not supported", U("I6"), CE, {}, False, "Y", None, {"Implications": NS}, [S, S, S, SC, S], "Supported with concerns", "Minor concerns", False, IE, True),
 ("V28", "I6 with I9", {"I6": "N", "I9": "PN"}, CE, {}, False, "Y", None, {"Implications": NS}, [S, S, S, NS, S], "Supported with concerns", "Minor concerns", False, IE, False),
 ("V29", "I1 No information", U("I1", a="NI"), CE, {}, False, "Y", None, {"Implications": SC}, [S, S, S, SC, S], "Supported with concerns", "Minor concerns", False, None, False),
 ("V30", "Implications 3 of I2-I9 plus I1: I1 is not counted", U("I1", "I2", "I3", "I4"), CE, {}, False, "Y", None, {"Implications": SC}, [S, S, S, SC, S], "Supported with concerns", "Minor concerns", False, None, False),
 ("V31", "Implications 4 of I2-I9: half rule", U("I2", "I3", "I4", "I5"), CE, {}, False, "Y", None, {"Implications": NS}, [S, S, S, NS, S], "Supported with concerns", "Minor concerns", False, IE, False),
 ("V32", "I7 with the no-limitations mark", U("I7"), CE, {"mark_i7_no_limitations": True}, False, "Y", None, {"Implications": NS}, [S, S, S, NS, S], "Supported with concerns", "Minor concerns", False, None, False),
 ("V33", "Co1 alone: context flag", U("Co1"), CE, {}, False, "Y", None, {"Context": NS}, [S, S, S, S, NS], "Supported with concerns", "Minor concerns", True, None, False),
 ("V34", "Co3 Probably no", U("Co3", a="PN"), CE, {}, False, "Y", None, {"Context": NS}, [S, S, S, S, NS], "Supported with concerns", "Minor concerns", True, None, False),
 ("V35", "Co3, Co4, Co7 No information are neutral", U("Co3", "Co4", "Co7", a="NI"), CE, {}, False, "Y", None, {}, [S, S, S, S, S], "Supported", "No concerns", False, None, False),
 ("V36", "Co7 Not applicable (preprint), Co2 Not applicable", U("Co7", "Co2", a="NA"), CE, {}, False, "Y", None, {}, [S, S, S, S, S], "Supported", "No concerns", False, None, False),
 ("V37", "Co7 No (predatory venue)", U("Co7"), CE, {}, False, "Y", None, {"Context": SC}, [S, S, S, S, SC], "Supported with concerns", "Minor concerns", False, None, False),
 ("V38", "Context 3 of 8: below half", U("Co2", "Co5", "Co6"), CE, {}, False, "Y", None, {"Context": SC}, [S, S, S, S, SC], "Supported with concerns", "Minor concerns", False, None, False),
 ("V39", "Context 4 of 8: half rule", U("Co2", "Co5", "Co6", "Co8"), CE, {}, False, "Y", None, {"Context": NS}, [S, S, S, S, NS], "Supported with concerns", "Minor concerns", True, None, False),
 ("V40", "S1 No with every element Supported", {}, CE, {}, False, "N", WHY, {}, [S, S, S, S, S], "Overstated", "Major concerns", False, None, False),
 ("V41", "S1 Probably no with an Implications problem", {"I6": "N", "I9": "PN"}, CE, {}, False, "PN", WHY, {"Implications": NS}, [S, S, S, NS, S], "Overstated", "Major concerns", False, None, False),
 ("V42", "E1 No information only: not enough reported", U("E1", a="NI"), CE, {}, False, "N", WHY, {"Evidence": NS}, [S, NS, S, S, S], "Cannot be evaluated", None, False, None, False),
 ("V43", "Evidence half rule through No information only", {**U("E3", "E4", "E5", "E6", "E8", a="NI"), "R6": "NA"}, CO, {}, False, "PN", WHY, {"Evidence": NS}, [S, NS, S, S, S], "Cannot be evaluated", None, False, None, False),
 ("V44", "E1 No information with E3 No: the Evidence fails", {"E1": "NI", "E3": "N"}, CE, {}, False, "N", WHY, {"Evidence": NS}, [S, NS, S, S, S], "Not supported", "Major concerns", False, None, False),
 ("V45", "R3 No information only for a Cause-effect Claim", U("R3", a="NI"), CE, {}, False, "N", WHY, {"Reasoning": NS}, [S, S, NS, S, S], "Cannot be evaluated", None, False, None, False),
 ("V46", "Evidence unreported but Reasoning fails", {"E1": "NI", "R6": "N"}, CE, {}, False, "N", WHY, {"Evidence": NS, "Reasoning": NS}, [S, NS, NS, S, S], "Not supported", "Major concerns", False, None, False),
 ("V47", "Reasoning half rule through No information only", U("R1", "R2", "R4", "R5", a="NI"), CE, {}, False, "PN", WHY, {"Reasoning": NS}, [S, S, NS, S, S], "Cannot be evaluated", None, False, None, False),
 ("V48", "Coder overrides Evidence to Not supported with every answer favorable", {}, CE, {}, False, "N", WHY, {"Evidence": NS}, [S, S, S, S, S], "Not supported", "Major concerns", False, None, True),
]
NSC = len(SCEN)
NI_ONLY = {"V42": {"Evidence"}, "V43": {"Evidence"}, "V45": {"Reasoning"}, "V46": {"Evidence"}, "V47": {"Reasoning"}}
PV = "CERIC-T v0.3"
QCODES = [r[0] for r in q("gene_coder", "SELECT code FROM tracker.questions WHERE protocol_version = %s ORDER BY element, position", (PV,))]
check("A0 42 questions loaded for v0.3", len(QCODES) == 42, str(len(QCODES)))
check("A0 new codings are recorded under v0.3", q("gene_coder", "SELECT admin.setting('protocol_version')")[0][0] == PV)

coding_ids = {}
for n, (tid, what, ans, ctype, marks, sup, s1, why, finals, exp_prop, exp_v, exp_s, exp_cf, exp_t, exp_override) in enumerate(SCEN, 1):
    sid = f"S9{n:03d}"
    cid = f"{sid}-C01"
    with conn("agent_claude") as c:
        c.execute("INSERT INTO tracker.studies (study_id, citation, strand) VALUES (%s,%s,'census')", (sid, f"Test study {tid}"))
    with conn("gene_coder") as c:
        c.execute("INSERT INTO tracker.claims (claim_id, study_id, main_claim, claim_type) VALUES (%s,%s,%s,%s)",
                  (cid, sid, f"Claim for {tid}", ctype))
    with conn("gene_lead") as c:
        c.execute("INSERT INTO tracker.assignments (claim_id, coder_id) VALUES (%s, 1)", (cid,))
    with conn("gene_coder") as c:
        s = ("AI use is associated with the outcome in this sample", "Correlation") if sup else (None, None)
        cols = {"claim_id": cid, "supportable_claim": s[0], "supportable_claim_type": s[1],
                "cer_summary": s1, "cer_summary_reason": why, "evidence_tier": "Promising", **marks}
        coding = c.execute(f"INSERT INTO tracker.codings ({','.join(cols)}) VALUES ({','.join(['%s'] * len(cols))}) RETURNING coding_id",
                           list(cols.values())).fetchone()[0]
        coding_ids[tid] = coding
        for code in QCODES:
            c.execute("INSERT INTO tracker.answers (coding_id, question_code, answer) VALUES (%s,%s,%s)", (coding, code, ans.get(code, "Y")))
        for el in ELS:
            c.execute("INSERT INTO tracker.element_evaluations VALUES (%s,%s,%s,%s,NULL)",
                      (coding, el, finals.get(el, S), f"Test rationale for {el}."))
        prop = [r[1] for r in c.execute("SELECT * FROM tracker.coding_summary(%s)", (coding,)).fetchall()]
        res = c.execute("SELECT * FROM tracker.coding_result(%s)", (coding,)).fetchone()
        fs = c.execute("SELECT tracker.coding_falls_short(%s)", (coding,)).fetchone()[0]
    att = res[5] or ""
    eff = [finals.get(el, S) for el in ELS]
    parts = [f"{el} (not enough reported)" if el in NI_ONLY.get(tid, ()) else f"{el} ({ev})" for el, ev in zip(ELS, eff) if ev != S]
    if s1 in ("PN", "N"):
        parts.insert(sum(1 for el, ev in zip(ELS[:3], eff[:3]) if ev != S), "CER summary (Probably no)" if s1 == "PN" else "CER summary (No)")
    exp_fs = ", ".join(parts) or None
    okall = (prop == exp_prop and res[0] == exp_v and res[1] == exp_s and res[2] == exp_cf and res[3] is None
             and fs == exp_fs and ("differs from Proposed without a note" in att) == exp_override)
    check(f"{tid} {what}: {exp_v}, {exp_s}; falls short at {exp_fs}", okall, f"proposed {prop}; result {res[:4]}; falls short {fs}; attention {att}")

# Submission: V27 must be refused until an override note is written
expect_error("V27 submit refused without override note", "gene_coder",
             "SELECT tracker.submit_coding(%s)", (coding_ids["V27"],), "differs from Proposed without a note")
with conn("gene_coder") as c:
    c.execute("UPDATE tracker.element_evaluations SET override_note = 'Recommendation is unconditioned and generalizes beyond the sample.' "
              "WHERE coding_id = %s AND element = 'Implications'", (coding_ids["V27"],))
    c.execute("UPDATE tracker.element_evaluations SET override_note = 'The article reports no usable data for the Claim.' "
              "WHERE coding_id = %s AND element = 'Evidence'", (coding_ids["V48"],))
check("No Overstated type is asked for under v0.3",
      "type" not in (q("gene_coder", "SELECT attention FROM tracker.coding_result(%s)", (coding_ids["V27"],))[0][0] or ""))
q("gene_coder", "UPDATE tracker.codings SET overstated_type = %s WHERE coding_id = %s", (IE, coding_ids["V28"]))
expect_error("An Overstated type cannot be recorded under v0.3", "gene_coder",
             "SELECT tracker.submit_coding(%s)", (coding_ids["V28"],), "Overstated types are not used")
q("gene_coder", "UPDATE tracker.codings SET overstated_type = NULL WHERE coding_id = %s", (coding_ids["V28"],))
check("Falls-short line names elements in CERIC order with the CER summary after Reasoning",
      q("gene_coder", "SELECT tracker.falls_short('N','Some concerns','Supported','Not supported','Some concerns','Supported', false, false)")[0][0]
      == "Claim (Some concerns), Reasoning (Not supported), CER summary (No), Implications (Some concerns)")
check("Rule order: a failed element outranks an unreported one; an unreported one outranks the CER summary",
      q("gene_coder", """SELECT tracker.derive_rating('N','Supported','Not supported','Not supported','Supported','Supported', true, false)::text,
                                tracker.derive_rating('N','Not supported','Not supported','Supported','Supported','Supported', true, false)::text,
                                tracker.derive_rating('N','Supported','Some concerns','Supported','Not supported','Not supported', false, false)::text,
                                tracker.derive_rating('Y','Supported','Supported','Supported','Not supported','Supported', false, false)::text,
                                tracker.derive_rating('Y','Not supported','Supported','Supported','Supported','Supported', false, false)::text""")[0]
      == ("Not supported", "Cannot be evaluated", "Overstated", "Supported with concerns", "Overstated"))
ok = 0
for row in SCEN:
    with conn("gene_coder") as c:
        v = c.execute("SELECT tracker.submit_coding(%s)", (coding_ids[row[0]],)).fetchone()[0]
        ok += v == row[10]
check(f"All {NSC} scenarios submit with the expected rating", ok == NSC, f"{ok}/{NSC}")

# ----------------------------------------------------------------------
# Part B: permissions and safeguards
# ----------------------------------------------------------------------
T1 = coding_ids["V01"]
# Guarantee 1: agents cannot write appraisal fields
expect_error("G1 agent cannot write an answer", "agent_claude",
             "INSERT INTO tracker.answers VALUES (%s,'C1','Y',NULL)", (T1,), "permission denied")
expect_error("G1 agent cannot change an evaluation", "agent_claude",
             "UPDATE tracker.element_evaluations SET final_evaluation='Supported' WHERE coding_id=%s", (T1,), "permission denied")
expect_error("G1 agent cannot create a coding", "agent_claude",
             "INSERT INTO tracker.codings (claim_id) VALUES ('S9001-C01')", None, "permission denied")
expect_error("G1 agent cannot write a rating", "agent_claude",
             "UPDATE tracker.codings SET final_rating='Supported'", None, "permission denied")
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


def fill(user, coding, answers, finals, note=None, s1="Y", why=None, tier="Promising", codes=None):
    with conn(user) as c:
        if s1:
            c.execute("UPDATE tracker.codings SET cer_summary=%s, cer_summary_reason=%s, evidence_tier=%s WHERE coding_id=%s",
                      (s1, why, tier, coding))
        for code in (codes or QCODES):
            c.execute("INSERT INTO tracker.answers (coding_id, question_code, answer) VALUES (%s,%s,%s)", (coding, code, answers.get(code, "Y")))
        for el in ELS:
            c.execute("INSERT INTO tracker.element_evaluations VALUES (%s,%s,%s,%s,%s)",
                      (coding, el, finals.get(el, S), f"Rationale for {el}.", note))


fill("gene_coder", gene_c, {}, {})
fill("adam_coder", adam_c, {"I3": "PN", "Co6": "PN"}, {"Implications": SC, "Context": SC})

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
      q("agent_claude", "SELECT count(*) FROM tracker.answers WHERE coding_id=%s", (adam_c,))[0][0] == 42)
check("G2 Adam cannot see Gene's draft",
      q("adam_coder", "SELECT count(*) FROM tracker.answers WHERE coding_id=%s", (gene_c,))[0][0] == 0)
q("gene_coder", "SELECT tracker.submit_coding(%s)", (gene_c,))
check("G2 once both submit, each sees the other",
      q("gene_coder", "SELECT count(*) FROM tracker.answers WHERE coding_id=%s", (adam_c,))[0][0] == 42
      and q("adam_coder", "SELECT count(*) FROM tracker.answers WHERE coding_id=%s", (gene_c,))[0][0] == 42)
check("Admin sign-in sees everything (maintenance only, logged)",
      q("gene_admin", "SELECT count(*) FROM tracker.codings")[0][0] == NSC + 2)

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
check("Finalized rating follows the reconciled evaluations", v == "Supported with concerns", v)

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
check("G8 ratings hidden while ratings_public is off", q("wp_publisher", "SELECT count(*) FROM tracker.public_ratings")[0][0] == 0)
expect_error("G8 agent cannot turn ratings on", "agent_claude", "SELECT admin.set_setting('ratings_public','on')", None, "permission denied")
expect_error("G8 coder cannot turn ratings on", "gene_coder", "SELECT admin.set_setting('ratings_public','on')", None, "permission denied")
q("gene_lead", "SELECT admin.set_setting('ratings_public','on')")
check("G8 ratings appear once the lead turns them on",
      q("wp_publisher", "SELECT rating, severity FROM tracker.public_ratings") == [("Supported with concerns", "Minor concerns")])
q("gene_lead", "SELECT admin.set_setting('ratings_public','off')")
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
check("Audit produces a flags profile by domain, no rating", prof == [("Statistical independence", 1)], str(prof))

# Decisions, settings, double sample, reliability, admin sessions
expect_error("Agent cannot confirm a decision", "agent_claude",
             "INSERT INTO admin.decisions (decided_on, area, decision, decided_by, status) VALUES (current_date,'test','x','Gene','confirmed')", None, "permission denied")
did = q("agent_claude", "INSERT INTO admin.decisions (decided_on, area, decision, decided_by) VALUES (current_date,'test','Draft decision','Gene') RETURNING decision_id")[0][0]
q("gene_lead", "UPDATE admin.decisions SET status='confirmed' WHERE decision_id=%s", (did,))
check("Lead confirms an agent's draft decision", q("gene_lead", "SELECT status, confirmed_by FROM admin.decisions WHERE decision_id=%s", (did,)) == [("confirmed", 1)])
draws = q("gene_lead", "SELECT * FROM tracker.draw_double_sample(ARRAY['S9002-C01','S9003-C01','S9004-C01'], 0.2, 0.42)")
check("Double-coding draw is logged with its seed", len(draws) == 3 and q("gene_lead", "SELECT count(*) FROM tracker.double_samples WHERE seed=0.42")[0][0] == 3)
rows = q("gene_lead", "SELECT tracker.run_reliability('CERIC-T v0.3')")[0][0]
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

# ----------------------------------------------------------------------
# Part C: what v0.3 adds
# ----------------------------------------------------------------------
# Attention items for the CER summary and the Evidence tier
with conn("agent_claude") as c:
    c.execute("INSERT INTO tracker.studies (study_id, citation, strand) VALUES ('S0200','Attention test study','census')")
with conn("gene_coder") as c:
    c.execute("INSERT INTO tracker.claims (claim_id, study_id, main_claim, claim_type) VALUES ('S0200-C01','S0200','Attention claim','Cause-effect')")
q("gene_lead", "INSERT INTO tracker.assignments (claim_id, coder_id) VALUES ('S0200-C01',1)")
att_c = q("gene_coder", "INSERT INTO tracker.codings (claim_id) VALUES ('S0200-C01') RETURNING coding_id")[0][0]
fill("gene_coder", att_c, {"E1": "N", "C5": "PN"}, {"Evidence": NS, "Claim": SC}, s1=None)
def attention(cid=att_c):
    return q("gene_coder", "SELECT attention FROM tracker.coding_result(%s)", (cid,))[0][0] or ""
a0 = attention()
check("C1 submission needs the CER summary and the Evidence tier",
      "CER summary not answered" in a0 and "Evidence tier not chosen" in a0 and "supportable claim missing" in a0, a0)
check("C1 no rating is proposed until the CER summary is answered",
      q("gene_coder", "SELECT proposed_rating FROM tracker.coding_result(%s)", (att_c,))[0][0] is None)
expect_error("C14 a coder cannot set their own rating under v0.3", "gene_coder",
             "UPDATE tracker.codings SET final_rating='Supported', override_note='Test' WHERE coding_id=%s", (att_c,), "cannot be overridden")
expect_error("C14 a coder cannot set their own severity under v0.3", "gene_coder",
             "UPDATE tracker.codings SET final_severity='No concerns', override_note='Test' WHERE coding_id=%s", (att_c,), "cannot be overridden")
q("gene_coder", "UPDATE tracker.codings SET cer_summary='PY', evidence_tier='Moderate', supportable_claim='Narrower claim', supportable_claim_type='Correlation' WHERE coding_id=%s", (att_c,))
a1 = attention()
check("C2 S1 cannot be Yes or Probably yes when Evidence is Not supported", "cannot be Yes or Probably yes" in a1, a1)
check("C2 S1 Yes or Probably yes with a supportable claim needs a note", "add a note" in a1, a1)
expect_error("C2 submission refused while S1 contradicts the Evidence evaluation", "gene_coder",
             "SELECT tracker.submit_coding(%s)", (att_c,), "cannot be Yes or Probably yes")
q("gene_coder", "UPDATE tracker.codings SET cer_summary='N' WHERE coding_id=%s", (att_c,))
check("C3 S1 No needs a one-sentence reason", "without a reason" in attention(), attention())
q("gene_coder", "UPDATE tracker.codings SET cer_summary_reason=%s WHERE coding_id=%s", (WHY, att_c))
check("C3 with the reason written, nothing is outstanding", attention() == "", attention())
expect_error("C4 S1 accepts only Y, PY, PN, N", "gene_coder",
             "UPDATE tracker.codings SET cer_summary='NI' WHERE coding_id=%s", (att_c,), "check")
expect_error("C4 Evidence tier accepts only the five values", "gene_coder",
             "UPDATE tracker.codings SET evidence_tier='Tier 5' WHERE coding_id=%s", (att_c,), "evidence_tier")
check("C4 fifth tier value is accepted",
      q("gene_coder", "UPDATE tracker.codings SET evidence_tier='No Rationale Demonstrated' WHERE coding_id=%s RETURNING evidence_tier::text", (att_c,))[0][0] == "No Rationale Demonstrated")
expect_error("C5 agent cannot answer the CER summary", "agent_claude",
             "UPDATE tracker.codings SET cer_summary='Y' WHERE coding_id=%s", (T1,), "permission denied")
expect_error("C5 agent cannot set the Evidence tier", "agent_claude",
             "UPDATE tracker.codings SET evidence_tier='Strong' WHERE coding_id=%s", (T1,), "permission denied")
expect_error("C5 lead sign-in cannot answer the CER summary", "gene_lead",
             "UPDATE tracker.codings SET cer_summary='Y' WHERE coding_id=%s", (att_c,), "permission denied")
q("gene_coder", "SELECT tracker.submit_coding(%s)", (att_c,))
expect_error("C5 S1 and tier are locked after submission", "gene_admin",
             "UPDATE tracker.codings SET cer_summary='Y' WHERE coding_id=%s", (att_c,), "locked")

# Not applicable only where v0.3 allows it
na_c_claim = 'S0201-C01'
with conn("agent_claude") as c:
    c.execute("INSERT INTO tracker.studies (study_id, citation, strand) VALUES ('S0201','NA test study','census')")
with conn("gene_coder") as c:
    c.execute("INSERT INTO tracker.claims (claim_id, study_id, main_claim, claim_type) VALUES (%s,'S0201','NA claim','Cause-effect')", (na_c_claim,))
q("gene_lead", "INSERT INTO tracker.assignments (claim_id, coder_id) VALUES (%s,1)", (na_c_claim,))
na_c = q("gene_coder", "INSERT INTO tracker.codings (claim_id) VALUES (%s) RETURNING coding_id", (na_c_claim,))[0][0]
bad = []
for code in QCODES:
    try:
        q("gene_coder", "INSERT INTO tracker.answers (coding_id, question_code, answer) VALUES (%s,%s,'NA')", (na_c, code))
    except psycopg.Error:
        bad.append(code)
allowed = sorted(set(QCODES) - set(bad))
check("C6 Not applicable is accepted on exactly C2, E9, E10, R6, I6, I8, Co2, Co3, Co7",
      allowed == sorted(["C2", "E9", "E10", "R6", "I6", "I8", "Co2", "Co3", "Co7"]), str(allowed))
expect_error("C6 a v0.3 coding cannot answer a v0.2 question code", "gene_coder",
             "INSERT INTO tracker.answers (coding_id, question_code, answer) VALUES (%s,'X1','Y')", (na_c,), "answers_question_fkey")
check("C6 every answer carries its coding's protocol version",
      q("gene_admin", "SELECT count(*) FROM tracker.answers a JOIN tracker.codings c USING (coding_id) WHERE a.protocol_version IS DISTINCT FROM c.protocol_version")[0][0] == 0)

# Versions side by side: a coding recorded under v0.2 still uses the v0.2 questions and rules
check("C7 both question sets are kept",
      q("gene_coder", "SELECT protocol_version, count(*) FROM tracker.questions GROUP BY 1 ORDER BY 1") == [("CERIC-T v0.2", 36), ("CERIC-T v0.3", 42)])
with conn("gene_admin") as c:
    c.execute("SET ROLE hill_owner")
    c.execute("UPDATE admin.settings SET value='CERIC-T v0.2' WHERE key='protocol_version'")
with conn("agent_claude") as c:
    c.execute("INSERT INTO tracker.studies (study_id, citation, strand) VALUES ('S0202','v0.2 test study','census')")
with conn("gene_coder") as c:
    c.execute("INSERT INTO tracker.claims (claim_id, study_id, main_claim, claim_type) VALUES ('S0202-C01','S0202','v0.2 claim','Cause-effect')")
q("gene_lead", "INSERT INTO tracker.assignments (claim_id, coder_id) VALUES ('S0202-C01',1)")
old_c = q("gene_coder", "INSERT INTO tracker.codings (claim_id) VALUES ('S0202-C01') RETURNING coding_id")[0][0]
with conn("gene_admin") as c:
    c.execute("SET ROLE hill_owner")
    c.execute("UPDATE admin.settings SET value='CERIC-T v0.3' WHERE key='protocol_version'")
OLD = [r[0] for r in q("gene_coder", "SELECT code FROM tracker.questions WHERE protocol_version='CERIC-T v0.2' ORDER BY element, position")]
fill("gene_coder", old_c, {"C1": "N", "C2": "N", "C6": "N"}, {"Claim": NS}, s1=None, codes=OLD)
r02 = q("gene_coder", "SELECT * FROM tracker.coding_result(%s)", (old_c,))[0]
p02 = [r[1] for r in q("gene_coder", "SELECT * FROM tracker.coding_summary(%s)", (old_c,))]
check("C7 a v0.2 coding keeps the v0.2 rules (three unfavorable Claim answers; no CER summary)",
      p02 == [NS, S, S, S, S] and r02[0] == "Overstated" and r02[5] == "Overstated type missing; ", f"{p02} {r02}")
expect_error("C7 a v0.2 coding cannot answer a v0.3-only question", "gene_coder",
             "INSERT INTO tracker.answers (coding_id, question_code, answer) VALUES (%s,'Co1','Y')", (old_c,), "answers_question_fkey")
check("G10 every coding records its protocol version",
      q("gene_admin", "SELECT protocol_version, count(*) FROM tracker.codings GROUP BY 1 ORDER BY 1")
      == [("CERIC-T v0.2", 1), ("CERIC-T v0.3", NSC + 4)])

# Reconciling the CER summary and the Evidence tier
def double(sid, g_s1, a_s1, g_tier, a_tier, a_ans=None, a_fin=None):
    cid = f"{sid}-C01"
    with conn("agent_claude") as c:
        c.execute("INSERT INTO tracker.studies (study_id, citation, strand) VALUES (%s,'Double test','census')", (sid,))
    with conn("gene_coder") as c:
        c.execute("INSERT INTO tracker.claims (claim_id, study_id, main_claim, claim_type) VALUES (%s,%s,'Double claim','Cause-effect')", (cid, sid))
    q("gene_lead", "INSERT INTO tracker.assignments (claim_id, coder_id) VALUES (%s,1),(%s,2)", (cid, cid))
    g = q("gene_coder", "INSERT INTO tracker.codings (claim_id) VALUES (%s) RETURNING coding_id", (cid,))[0][0]
    a = q("adam_coder", "INSERT INTO tracker.codings (claim_id) VALUES (%s) RETURNING coding_id", (cid,))[0][0]
    fill("gene_coder", g, {}, {}, s1=g_s1, why=WHY if g_s1 in ("PN", "N") else None, tier=g_tier)
    fill("adam_coder", a, a_ans or {}, a_fin or {}, s1=a_s1, why=WHY if a_s1 in ("PN", "N") else None, tier=a_tier)
    q("gene_coder", "SELECT tracker.submit_coding(%s)", (g,))
    q("adam_coder", "SELECT tracker.submit_coding(%s)", (a,))
    return cid

d1 = double("S0301", "Y", "PN", "Strong", "Moderate")
n = q("gene_coder", "SELECT tracker.open_reconciliation(%s)", (d1,))[0][0]
items = q("gene_coder", "SELECT item, value_a, value_b FROM tracker.reconciliation_items WHERE claim_id=%s ORDER BY item", (d1,))
check("C8 S1 and tier disagreements go on the reconciliation agenda", n == 2 and items == [("CER summary", "Y", "PN"), ("Evidence tier", "Strong", "Moderate")], f"{n} {items}")
po = q("gene_coder", "SELECT pending, rating::text FROM tracker.claim_outcome(%s)", (d1,))[0]
check("C8 before everything is settled, the outcome lists what is pending and gives no rating",
      "CER summary on S0301-C01 is not reconciled yet" in po[0] and "Evidence tier" in po[0] and po[1] is None, str(po))
expect_error("C8 agent cannot ask for a claim's outcome", "agent_claude", "SELECT * FROM tracker.claim_outcome(%s)", (d1,), "permission denied")
expect_error("C8 a coder of another claim cannot ask for this claim's outcome", "third_tiebreak", "SELECT * FROM tracker.claim_outcome(%s)", (d1,), "permission denied")
expect_error("C8 a claim cannot be finalized while S1 is unreconciled", "gene_coder",
             "SELECT tracker.finalize_claim(%s)", (d1,), "CER summary on S0301-C01 is not reconciled")
expect_error("C8 agent cannot agree an item", "agent_claude",
             "SELECT tracker.agree_item(%s,'CER summary','PN','x')", (d1,), "permission denied")
expect_error("C8 an item needs a valid value", "gene_coder",
             "SELECT tracker.agree_item(%s,'CER summary','NI','reason')", (d1,), "not a valid value")
expect_error("C8 an item needs a reason", "gene_coder",
             "SELECT tracker.agree_item(%s,'Evidence tier','Strong','  ')", (d1,), "reason is required")
r1 = q("gene_coder", "SELECT tracker.agree_item(%s,'CER summary','PN','On re-reading, the Claim as stated is causal and the design is not.')", (d1,))[0][0]
mid = q("adam_coder", "SELECT resolution FROM tracker.reconciliation_items WHERE claim_id=%s AND item='CER summary'", (d1,))[0][0]
r2 = q("adam_coder", "SELECT tracker.agree_item(%s,'CER summary','PN','Agree.')", (d1,))[0][0]
check("C8 two coders agree the CER summary", r1.startswith("proposed") and mid is None and r2 == "agreed", f"{r1} / {mid} / {r2}")
expect_error("C8 the tier must be settled before finalizing", "gene_coder",
             "SELECT tracker.finalize_claim(%s)", (d1,), "Evidence tier on S0301-C01 is not reconciled")
expect_error("D2 Gene (lead) cannot decide an item on a claim she coded", "gene_lead",
             "SELECT tracker.decide_item(%s,'Evidence tier','Moderate','reason')", (d1,), "cannot decide")
expect_error("D2 unassigned tie-breaker cannot decide an item", "third_tiebreak",
             "SELECT tracker.decide_item(%s,'Evidence tier','Moderate','reason')", (d1,), "not assigned")
q("gene_lead", "SELECT tracker.assign_tiebreak(%s, 3)", (d1,))
q("third_tiebreak", "SELECT tracker.decide_item(%s,'Evidence tier','Moderate','Comparison group without random assignment.')", (d1,))
pre = q("gene_coder", "SELECT pending, rating::text, severity::text, cer_summary::text, evidence_tier::text, falls_short FROM tracker.claim_outcome(%s)", (d1,))[0]
check("C8 once settled, the outcome is shown before finalizing",
      pre == (None, "Overstated", "Major concerns", "PN", "Moderate", "CER summary (Probably no)"), str(pre))
check("C8 looking at the outcome records nothing", q("gene_lead", "SELECT count(*) FROM tracker.reconciled_claims WHERE claim_id=%s", (d1,))[0][0] == 0)
v = q("adam_coder", "SELECT tracker.finalize_claim(%s)", (d1,))[0][0]
fin = q("gene_lead", "SELECT rating::text, severity::text, cer_summary::text, evidence_tier::text, protocol_version, falls_short, overstated_type::text FROM tracker.reconciled_claims WHERE claim_id=%s", (d1,))
check("C8 final rating follows the agreed CER summary; the agreed tier and the falls-short line are recorded",
      v == "Overstated" and fin == [("Overstated", "Major concerns", "PN", "Moderate", PV, "CER summary (Probably no)", None)], f"{v} {fin}")

d2 = double("S0302", "Y", "PY", "Promising", "Promising", {"I3": "PN"}, {"Implications": SC})
n2 = q("gene_coder", "SELECT tracker.open_reconciliation(%s)", (d2,))[0][0]
check("C9 Yes versus Probably yes is not a disagreement; the element difference is", n2 == 1
      and q("gene_coder", "SELECT count(*) FROM tracker.reconciliation_items WHERE claim_id=%s", (d2,))[0][0] == 0, str(n2))
q("gene_coder", "SELECT tracker.agree_reconciliation(%s,'Implications','Some concerns','I3 unfavorable on re-read.')", (d2,))
q("adam_coder", "SELECT tracker.agree_reconciliation(%s,'Implications','Some concerns','Agree.')", (d2,))
v2 = q("gene_coder", "SELECT tracker.finalize_claim(%s)", (d2,))[0][0]
fin2 = q("gene_lead", "SELECT cer_summary::text, evidence_tier::text, falls_short FROM tracker.reconciled_claims WHERE claim_id=%s", (d2,))
check("C9 the less certain of two favorable answers is kept", v2 == "Supported with concerns" and fin2 == [("PY", "Promising", "Implications (Some concerns)")], f"{v2} {fin2}")
expect_error("C9 the old name 'Partially supported' is gone", "gene_lead", "SELECT 'Partially supported'::tracker.rating", None, "invalid input value")
d3 = double("S0303", "N", "PN", "Promising", "Promising", {"E1": "NI"}, {"Evidence": NS})
q("gene_coder", "SELECT tracker.open_reconciliation(%s)", (d3,))
q("gene_coder", "SELECT tracker.agree_reconciliation(%s,'Evidence','Not supported','The methods are not described, so E1 cannot be answered.')", (d3,))
q("adam_coder", "SELECT tracker.agree_reconciliation(%s,'Evidence','Not supported','Agree.')", (d3,))
v3 = q("gene_coder", "SELECT tracker.finalize_claim(%s)", (d3,))[0][0]
fin3 = q("gene_lead", "SELECT rating::text, cer_summary::text, falls_short FROM tracker.reconciled_claims WHERE claim_id=%s AND severity IS NULL", (d3,))
check("C9b an agreed Evidence evaluation resting only on No information gives Cannot be evaluated, with no severity",
      v3 == "Cannot be evaluated" and fin3 == [("Cannot be evaluated", "PN", "Evidence (not enough reported), CER summary (Probably no)")], f"{v3} {fin3}")
expect_error("C9b every other rating must carry a severity", "gene_admin",
             "UPDATE tracker.reconciled_claims SET severity = NULL WHERE claim_id = 'S0302-C01'", None, "severity_by_rating")
left = q("gene_admin", """SELECT 'function ' || proname FROM pg_proc p JOIN pg_namespace n ON n.oid = pronamespace
                           WHERE nspname IN ('tracker','admin','funding') AND (prosrc ~* 'verdict' OR proname ~* 'verdict')
                          UNION ALL SELECT 'column ' || table_name || '.' || column_name FROM information_schema.columns
                           WHERE table_schema IN ('tracker','admin','funding') AND column_name ~* 'verdict'
                          UNION ALL SELECT 'view ' || viewname FROM pg_views WHERE schemaname IN ('tracker','admin','funding') AND (definition ~* 'verdict' OR viewname ~* 'verdict')
                          UNION ALL SELECT 'type ' || typname FROM pg_type WHERE typname ~* 'verdict'
                          UNION ALL SELECT 'value ' || enumlabel FROM pg_enum WHERE enumlabel ~* 'verdict'
                          UNION ALL SELECT 'comment ' || description FROM pg_description WHERE description ~* 'verdict'
                          UNION ALL SELECT 'setting ' || key FROM admin.settings WHERE key ~* 'verdict' OR note ~* 'verdict' OR value ~* 'verdict'
                          UNION ALL SELECT 'question ' || code FROM tracker.questions WHERE wording ~* 'verdict'""")
check("C13 the word 'verdict' appears nowhere in the database's names, rules, comments, settings or questions", left == [], str(left))
sub = q("postgres", """SELECT count(*), count(*) FILTER (WHERE final_rating IS NULL),
                               count(*) FILTER (WHERE final_severity IS NULL AND final_rating <> 'Cannot be evaluated')
                        FROM tracker.codings WHERE status = 'submitted' AND protocol_version = %s""", (PV,))[0]
check("C14 every submitted v0.3 coding carries the derived rating and severity", sub[0] > 0 and sub[1] == 0 and sub[2] == 0, str(sub))
ri = q("gene_lead", "SELECT * FROM tracker.reliability_items(%s)", (PV,))
check("C10 agreement on S1 and tier is reported", ri == [("CER summary", 4, 75.0), ("Evidence tier", 4, 75.0)] or
      [(r[0], r[1], float(r[2])) for r in ri] == [("CER summary", 4, 75.0), ("Evidence tier", 4, 75.0)], str(ri))
expect_error("C10 coders cannot run the agreement report", "gene_coder", "SELECT * FROM tracker.reliability_items(%s)", (PV,), "permission denied")
check("C10 reconciliation items are logged", q("gene_lead", "SELECT count(*) FROM admin.change_log WHERE table_name LIKE '%%reconciliation_items'")[0][0] >= 5)

# Publication status
q("agent_claude", "UPDATE tracker.studies SET publication_status='preprint or working paper' WHERE study_id='S0100'")
expect_error("C11 a predatory venue needs its basis", "agent_claude",
             "UPDATE tracker.studies SET publication_status='predatory venue' WHERE study_id='S0100'", None, "predatory_needs_basis")
expect_error("C11 agent cannot confirm publication status", "agent_claude",
             "UPDATE tracker.studies SET publication_confirmed_by=1 WHERE study_id='S0100'", None, "permission denied")
check("C11 an unconfirmed publication status stays private",
      q("wp_publisher", "SELECT publication_status FROM tracker.public_census WHERE study_id='S0100'") == [(None,)])
q("gene_coder", "UPDATE tracker.studies SET publication_confirmed_by=1 WHERE study_id='S0100'")
check("C11 a confirmed publication status is published",
      q("wp_publisher", "SELECT publication_status FROM tracker.public_census WHERE study_id='S0100'") == [("preprint or working paper",)])
q("gene_lead", "SELECT admin.set_setting('ratings_public','on')")
check("C12 the published rating carries the CER summary and the Evidence tier",
      q("wp_publisher", "SELECT rating::text, cer_summary::text, evidence_tier::text, falls_short FROM tracker.public_ratings WHERE claim_id='S0100-C01'")
      == [("Supported with concerns", "Y", "Promising", "Implications (Some concerns)")])
q("gene_lead", "SELECT admin.set_setting('ratings_public','off')")
expect_error("C12 publisher cannot read reconciliation items", "wp_publisher", "SELECT * FROM tracker.reconciliation_items", None, "permission denied")


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
