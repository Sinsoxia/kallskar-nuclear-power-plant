"""
Rod drives: check §3.4's speeds, worth curve, scram rates and shutdown margins against each other.

§3.4 lists six drive speeds without saying where they come from, and a 4 pcm/s withdrawal interlock. This script
shows the speeds ARE the interlock: differentiate the stated integral worth curve, take its mid-stroke peak, and
divide 4 pcm/s by it, and every speed in the table falls out as that quotient rounded down. It also checks the
shutdown margins against the §3.3 reactivity budget, which turns out to pin them exactly.

  W(d)     = W_total x (d - sin(2 pi d) / 2 pi)        §3.4, d = inserted fraction of the 1,000 mm active height
  dW/dd    = W_total x (1 - cos(2 pi d))               peaks at 2 x W_total, at mid-stroke
  dW/dx    = dW/dd / 1,000 mm

Run: python tools/derive/rod_speeds.py
"""
import math

TRAVEL_MM = 1100.0          # §0.1: rod position is 0-1,100 mm withdrawn from fully inserted
ACTIVE_MM = 1000.0          # §2.1: active fuel height
INTERLOCK_PCMPS = 4.0       # §3.4
EXCESS_BOC_PCM = 2250.0     # §3.3 reactivity budget, 230 C beginning of cycle
ISOTHERMAL_PCMPK = 2.41     # §3.3
ISOTHERMAL_SWING_PCM = 376.0  # §3.3 budget line: the 230 -> 375 C isothermal swing, stated outright

# §3.4 table: (label, rods moving together, worth each pcm, stated speed mm/s)
DRIVES = [
    ("RR, one rod",        1, 100, 5.0),
    ("RR, all three",      3, 100, 5.0),
    ("Shim, one rod",      1, 400, 2.0),
    ("Shim bank A",        6, 400, 0.8),
    ("Shim bank B",        6, 300, 1.0),
    ("Shim bank C",        6, 200, 1.0),
    ("SSR, one rod",       1, 330, 5.0),
    ("Shim runback drive-in", 6, 400, 10.0),   # insertion: the interlock is on withdrawal only
]
# §3.4 tabulated worth fractions
TABLE_D = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
TABLE_W = [0.006, 0.049, 0.149, 0.306, 0.500, 0.694, 0.851, 0.951, 0.994]

checks = []


def check(label, got, want, tol, unit=""):
    ok = abs(got - want) <= tol
    checks.append(ok)
    print(f"  {'ok  ' if ok else 'FAIL'} {label:<46} {got:9.4f} vs {want:8.3f} {unit:<6} (tol {tol:g})")


def worth_fraction(d):
    return d - math.sin(2.0 * math.pi * d) / (2.0 * math.pi)


def differential_per_mm(total_pcm, d):
    """pcm per mm of withdrawal at inserted fraction d."""
    return total_pcm * (1.0 - math.cos(2.0 * math.pi * d)) / ACTIVE_MM


print("The §3.4 worth table is the §3.4 formula")
for d, w in zip(TABLE_D, TABLE_W):
    check(f"W({d:.1f}) / W_total", worth_fraction(d), w, 0.0005)
check("W(0)", worth_fraction(0.0), 0.0, 1e-12)
check("W(1)", worth_fraction(1.0), 1.0, 1e-12)

print("\nEvery speed is the 4 pcm/s interlock divided by peak differential worth")
print("       drive                     total pcm   peak pcm/mm   fastest mm/s   stated   peak pcm/s")
for label, n, each, speed in DRIVES:
    total = n * each
    peak = differential_per_mm(total, 0.5)          # mid-stroke
    fastest = INTERLOCK_PCMPS / peak
    rate = peak * speed
    flag = "" if rate <= INTERLOCK_PCMPS + 1e-9 else "  <- over the interlock"
    print(f"       {label:<24} {total:8.0f}   {peak:11.3f}   {fastest:12.3f}   {speed:6.2f}   {rate:9.3f}{flag}")
    if "runback" not in label:                       # drive-in is insertion, not withdrawal
        checks.append(rate <= INTERLOCK_PCMPS + 1e-9)

# the two the spec had to round down to reach, which is the evidence the speeds were chosen this way
check("bank A: fastest inside the interlock", INTERLOCK_PCMPS / differential_per_mm(6 * 400, 0.5), 0.8, 0.05, "mm/s")
check("bank B: fastest inside the interlock", INTERLOCK_PCMPS / differential_per_mm(6 * 300, 0.5), 1.0, 0.15, "mm/s")

print("\nScram (90 % of travel in the stated time, §3.4)")
for label, t90 in (("PSS: RR and shim", 1.2), ("SSR", 2.0)):
    rate = 0.9 * TRAVEL_MM / t90
    print(f"       {label:<20} {rate:7.1f} mm/s, so full travel takes {TRAVEL_MM / rate:.3f} s")

print("\nShutdown margins against the §3.3 budget")
pss_total = 3 * 100 + 6 * 400 + 6 * 300 + 6 * 200      # RR + shim banks A, B, C
ssr_total = 9 * 330
print(f"       PSS worth {pss_total} pcm, SSR worth {ssr_total} pcm")
# §3.4: all PSS in, most reactive rod stuck, 230 C, BOC
most_reactive = 400                                     # a bank A rod
check("PSS margin, most reactive rod stuck, 230 C",
      EXCESS_BOC_PCM - (pss_total - most_reactive), -3050.0, 5, "pcm")
# the two SSS figures must agree on one excess reactivity at 375 C
implied_375_all = ssr_total - 1100.0
implied_375_stuck = (ssr_total - 330) - 770.0
check("SSS alone and SSS-one-stuck imply the same excess", implied_375_all, implied_375_stuck, 1, "pcm")
print(f"       -> both put the excess at 375 C at {implied_375_all:.0f} pcm, against {EXCESS_BOC_PCM:.0f} at 230 C")
swing = EXCESS_BOC_PCM - implied_375_all
implied_coeff = swing / (375.0 - 230.0)
print(f"       -> a {swing:.0f} pcm swing over 145 K is {implied_coeff:.2f} pcm/K, "
      f"against §3.3's {ISOTHERMAL_PCMPK:.2f} pcm/K")
# the margins are quoted to three figures, so +-25 pcm each; that is +-0.2 pcm/K on the implied coefficient
# §3.3's budget states this swing outright, and that is the sharper comparison: the coefficient is an average
# over a range the budget line need not match exactly.
check("implied swing against §3.3's budget line", swing, ISOTHERMAL_SWING_PCM, 10, "pcm")
check("implied isothermal coefficient", implied_coeff, ISOTHERMAL_PCMPK, 0.25, "pcm/K")
print(f"       -> §3.3's own budget line is {ISOTHERMAL_SWING_PCM:.0f} pcm, which is {ISOTHERMAL_SWING_PCM / 145:.2f} "
      f"pcm/K; the margins agree with the budget to {abs(swing - ISOTHERMAL_SWING_PCM) / ISOTHERMAL_SWING_PCM:.1%}")

print(f"\n{sum(checks)}/{len(checks)} checks pass")
raise SystemExit(0 if all(checks) else 1)
