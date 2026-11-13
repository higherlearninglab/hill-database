"""V1 and V3 of the CERIC-T v0.4 validation plan, computed outside the database.

Reads lines of claim_id,study_id,element,level_coder_1,level_coder_2 on standard input
(the output of agreement_pairs_v04.sql; levels 0 Supported, 1 Some concerns, 2 Not supported).

V1: Cohen's kappa for each element with a 95% percentile interval from a bootstrap that resamples
    studies, not Claims, because Claims from one study are not independent.
V3: the Stuart-Maxwell test of marginal homogeneity for each element, with the count of differences
    in each direction.

Standard library only. The bootstrap uses a fixed seed, so a rerun on the same data gives the same interval.
"""
import csv, math, random, sys
from collections import defaultdict

ELEMENTS = ["Claim", "Evidence", "Reasoning", "Implications", "Context"]
REPS, SEED = 5000, 20261111


def kappa(pairs):
    n = len(pairs)
    if n == 0:
        return None
    po = sum(a == b for a, b in pairs) / n
    pe = sum((sum(a == g for a, _ in pairs) / n) * (sum(b == g for _, b in pairs) / n) for g in range(3))
    return None if pe >= 1 else (po - pe) / (1 - pe)


def bootstrap(by_study, reps=REPS, seed=SEED):
    rng = random.Random(seed)
    studies = sorted(by_study)
    out = []
    for _ in range(reps):
        sample = [p for s in (rng.choice(studies) for _ in studies) for p in by_study[s]]
        k = kappa(sample)
        if k is not None:
            out.append(k)
    out.sort()
    if not out:
        return None, None, 0
    return out[int(0.025 * (len(out) - 1))], out[int(0.975 * (len(out) - 1))], len(out)


def stuart_maxwell(pairs):
    """Chi-square (2 df) and p for a 3 x 3 table; None when the test cannot be computed."""
    n = [[sum(1 for a, b in pairs if a == i and b == j) for j in range(3)] for i in range(3)]
    row = [sum(n[i]) for i in range(3)]
    col = [sum(n[i][j] for i in range(3)) for j in range(3)]
    d = [row[0] - col[0], row[1] - col[1]]
    v11 = row[0] + col[0] - 2 * n[0][0]
    v22 = row[1] + col[1] - 2 * n[1][1]
    v12 = -(n[0][1] + n[1][0])
    det = v11 * v22 - v12 * v12
    if det == 0:
        return None, None
    chi2 = (d[0] * d[0] * v22 - 2 * d[0] * d[1] * v12 + d[1] * d[1] * v11) / det
    return chi2, math.exp(-chi2 / 2)          # survival function of chi-square with 2 degrees of freedom


def main():
    data = defaultdict(lambda: defaultdict(list))
    for r in csv.reader(sys.stdin):
        if len(r) != 5:
            continue
        _, study, element, a, b = r
        data[element][study].append((int(a), int(b)))
    if not data:
        print("No Claims have been submitted by both coders under CERIC-T v0.4 yet.")
        return
    print("V1. Kappa for each element, with a 95%% interval from %d bootstrap samples that resample studies" % REPS)
    print("%-13s %7s %8s %7s  %-17s %s" % ("element", "claims", "studies", "kappa", "95% interval", "target 0.70"))
    for el in ELEMENTS:
        by_study = data.get(el, {})
        pairs = [p for ps in by_study.values() for p in ps]
        k = kappa(pairs)
        lo, hi, used = bootstrap(by_study) if by_study else (None, None, 0)
        ks = "  n/a" if k is None else "%5.2f" % k
        ci = "n/a" if lo is None else "%5.2f to %5.2f" % (lo, hi)
        note = "" if k is None else ("meets" if k >= 0.70 else "below")
        if used and used < REPS:
            note += " (%d samples had no variation and were left out)" % (REPS - used)
        print("%-13s %7d %8d %7s  %-17s %s" % (el, len(pairs), len(by_study), ks, ci, note))
    print()
    print("V3. Stuart-Maxwell test of marginal homogeneity, and the direction of differences")
    print("%-13s %9s %8s  %-22s %s" % ("element", "chi2(2)", "p", "coder 1 more favorable", "coder 2 more favorable"))
    for el in ELEMENTS:
        pairs = [p for ps in data.get(el, {}).values() for p in ps]
        chi2, p = stuart_maxwell(pairs)
        c1 = sum(a < b for a, b in pairs)
        c2 = sum(a > b for a, b in pairs)
        if chi2 is None:
            print("%-13s %9s %8s  %-22d %d   (not computable: too few differences)" % (el, "n/a", "n/a", c1, c2))
        else:
            print("%-13s %9.2f %8.3f  %-22d %d" % (el, chi2, p, c1, c2))
    print()
    print("With few Claims these tests have little power; read them beside V2, not as a pass mark.")


if __name__ == "__main__":
    main()
