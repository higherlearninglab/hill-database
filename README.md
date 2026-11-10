# HiLL database

The database behind the [Higher Learning Lab](https://higherlearninglab.org) Evidence Tracker on AI, learning and attachment, and HiLL's funding records.

This repository holds the structure only. It contains no study data, no coding results and no passwords.

## What it guarantees

The database enforces these rules itself, so they do not depend on any person or AI agent following instructions.

1. **Appraisal is human.** AI agents can prepare packets of quoted passages, pre-fill factual fields and raise flags. They cannot write a CERIC-T signalling answer, an element evaluation, a rationale, a verdict, a severity rating or an Overstated type.
2. **Blind double-coding.** Each coder sees only their own answers on a claim until both coders have submitted.
3. **Submitted codings are locked.** Later changes go through reconciliation, with a recorded reason.
4. **Every departure from the rules is explained.** If a coder's evaluation differs from the one the rules propose, an override note is required.
5. **No incomplete records.** A coding cannot be submitted without all 36 answers, five evaluations and five rationales.
6. **"Not applicable" only where the protocol allows it.**
7. **Nothing is public without the lead's approval** of a release.
8. **Verdicts stay held** until the rubric reaches version 1.0 and the lead turns them on.
9. **Full history.** Every change is recorded in an append-only log.
10. **Every coding records the protocol version** it was coded under.
11. **Agent pre-fills in synthesis audits must be confirmed** by a human before the audit can be submitted.
12. **No one settles a disagreement on their own coding.**

## Files

| File | What it is |
|---|---|
| `hill-db-phase2.sql` | The full structure: roles, tables, the CERIC-T v0.2 rule functions, safeguards and public views, plus reference data: the 36 CERIC-T questions and 43 Synthesis Audit Checklist items by code, and the 22 vulnerable-student categories. Question and checklist wording is held back until HiLL publishes the codebook |
| `run_tests.py` | 145 automated tests: the 13 scenarios from the CERIC-T calibration workbook, and a test of every safeguard above, run by signing in as each role |
| `test-results-2026-11-09.txt` | Test results from the first build |

## Running the tests

Run the tests in a scratch database only, never the live one. The script refuses to run in a database named `hill` or `defaultdb`.

```
createdb hilltest
psql -d hilltest -v ON_ERROR_STOP=1 -f hill-db-phase2.sql
PGDATABASE=hilltest HILL_TEST_ADMIN=<admin user> python3 run_tests.py
```

The tests create temporary sign-ins prefixed `test_`, with random one-time passwords, and remove them when they finish.

## Sources

- CERIC-T protocol and decision rules, version 0.2 (draft), Higher Learning Lab, November 2026.
- Bjorn, G., & Burgasser, A. J. *How to Critically Read the Scientific Research Literature.* Cambridge University Press.
- HiLL Synthesis Audit Checklist, version 0.1.
