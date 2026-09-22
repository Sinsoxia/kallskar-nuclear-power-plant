"""
Neutron instrumentation: check §3.5 against §3.3/§3.4, and derive the filter time constants from §9.5.

Two jobs.

1. CHECK. §3.5's "SR count rate ~ 15/(1-k) cps, about 250 cps with all rods in" is a claim about the §3.3
   reactivity budget and the §3.4 rod worths, so it can be verified rather than trusted. It also fixes what "all
   rods in" means, which the sentence leaves open.

2. DERIVE. The spec gives no instrument noise figures for the neutron channels (only the +-1 K thermocouple noise
   of §2.5). Counting channels need none -- their noise IS Poisson statistics, sigma = sqrt(R/tau), with no free
   parameter. The analogue channels (wide range in Campbell mode, power range on DC ion chambers) do need a
   fractional precision, and those two numbers are choices. What is NOT a choice is the filtering: once the noise
   level is set, the filter time constants follow from a single requirement --

       instrument noise must never, on its own, reach a §9.5 setpoint

   -- applied at 5 sigma. This script computes those constants. The raw numbers show why it matters: 0.5 % power
   range noise differentiated over one 0.1 s tick is 5 %FP/s of pure noise, against a §9.5 flux-rate trip at
   10 %FP/s. Unfiltered, the plant would trip on nothing.

Run: python tools/derive/detectors.py
"""
import math

# §3.3 / §3.4
EXCESS_BOC_PCM = 2250.0
PSS_WORTH_PCM = 3 * 100 + 6 * 400 + 6 * 300 + 6 * 200
SSR_WORTH_PCM = 9 * 330
# §3.5
SR_CONSTANT_CPS = 15.0
SR_ALL_RODS_IN_CPS = 250.0
SR_SPAN = (1.0, 1e6)
WR_SPAN_PCTFP = (1e-8, 150.0)
DND_BACKGROUND_CPS = 40.0
# §9.5 setpoints the noise must stay clear of
FLUX_RATE_TRIP_PCTFPPS = 10.0
PERIOD_ROD_BLOCK_S = 30.0
PERIOD_TRIP_S = 10.0
PR_TRIP_PCTFP = 115.0
DND_ALARM_FACTOR = 3.0
# §14.1
TICK_S = 0.1
# Chosen fractional precisions for the two analogue channel types (D-025)
WR_RELATIVE = 0.02      # Campbell-mode mean-square-voltage, roughly constant across the range
PR_RELATIVE = 0.005     # DC ionisation chamber current at power
SIGMA_MARGIN = 5.0      # noise must sit this many sigma short of any setpoint

checks = []


def check(label, got, want, tol, unit=""):
    ok = abs(got - want) <= tol
    checks.append(ok)
    print(f"  {'ok  ' if ok else 'FAIL'} {label:<48} {got:11.4f} vs {want:9.3f} {unit:<5} (tol {tol:g})")


def k_from_pcm(rho_pcm):
    rho = rho_pcm / 1e5
    return 1.0 / (1.0 - rho)


def sr_cps(k):
    return SR_CONSTANT_CPS / (1.0 - k)


print("§3.5's source range against the §3.3 budget and §3.4 worths")
for label, worth in (("PSS only", PSS_WORTH_PCM), ("PSS and SSR", PSS_WORTH_PCM + SSR_WORTH_PCM)):
    rho = EXCESS_BOC_PCM - worth
    print(f"       {label:<12} rho {rho:7.0f} pcm -> k {k_from_pcm(rho):.5f} -> {sr_cps(k_from_pcm(rho)):7.1f} cps")
rho_all = EXCESS_BOC_PCM - (PSS_WORTH_PCM + SSR_WORTH_PCM)
check("'all rods in' means every rod, SSRs included", sr_cps(k_from_pcm(rho_all)), SR_ALL_RODS_IN_CPS, 5, "cps")
# where the instrument runs out of range
k_top = 1.0 - SR_CONSTANT_CPS / SR_SPAN[1]
print(f"       top of span {SR_SPAN[1]:.0e} cps is 1-k = {SR_CONSTANT_CPS / SR_SPAN[1]:.2e}, "
      f"i.e. rho = {(k_top - 1) / k_top * 1e5:+.1f} pcm -- essentially critical")
print(f"       the formula floors at {SR_CONSTANT_CPS:.0f} cps (k = 0), well above the {SR_SPAN[0]:.0f} cps "
      f"bottom of the §3.5 span")
checks.append(sr_cps(0.0) >= SR_SPAN[0])

print("\nCounting statistics: no free parameter, sigma = sqrt(R/tau)")
print("       rate cps    tau 0.1 s     tau 1 s     tau 2 s     tau 5 s   (relative sigma)")
for rate in (SR_CONSTANT_CPS, SR_ALL_RODS_IN_CPS, 1e4, 1e6, DND_BACKGROUND_CPS):
    row = "   ".join(f"{1.0 / math.sqrt(rate * tau):9.3%}" for tau in (0.1, 1.0, 2.0, 5.0))
    print(f"       {rate:9.0f}   {row}")

print("\nFilter time constants derived from §9.5 (5 sigma clear of every setpoint)")
# Flux rate: a first-order filtered derivative of a signal with relative noise s has
# sigma(dP/dt) ~ sqrt(2) * s * P / tau. Requiring 5 sigma below the trip at full power:
tau_flux = SIGMA_MARGIN * math.sqrt(2.0) * PR_RELATIVE * 100.0 / FLUX_RATE_TRIP_PCTFPPS
print(f"       power range noise {PR_RELATIVE:.1%} over one {TICK_S} s tick is "
      f"{math.sqrt(2.0) * PR_RELATIVE * 100.0 / TICK_S:.1f} %FP/s of pure noise, against a "
      f"{FLUX_RATE_TRIP_PCTFPPS:.0f} %FP/s trip")
print(f"       -> flux-rate filter must be at least {tau_flux:.2f} s")
check("flux-rate filter, rounded up", 0.5, tau_flux, 0.5 - tau_flux + 1e-9, "s")

# Period: T = P / (dP/dt), so noise alone produces an apparent period of tau / (sqrt(2) * s).
# It must stay beyond the rod block, and beyond the §3.5 span end, at 5 sigma.
tau_period_block = SIGMA_MARGIN * PERIOD_ROD_BLOCK_S * math.sqrt(2.0) * WR_RELATIVE
print(f"       wide range noise {WR_RELATIVE:.1%} fakes a period of tau / {math.sqrt(2.0) * WR_RELATIVE:.4f} "
      f"= {1.0 / (math.sqrt(2.0) * WR_RELATIVE):.0f} x tau")
print(f"       -> period filter must be at least {tau_period_block:.2f} s to keep 5 sigma clear of the "
      f"{PERIOD_ROD_BLOCK_S:.0f} s rod block")
check("period filter, rounded up", 5.0, tau_period_block, 5.0 - tau_period_block + 1e-9, "s")
for tau in (1.0, 2.0, 3.0, 5.0):
    apparent = tau / (math.sqrt(2.0) * WR_RELATIVE)
    print(f"          tau {tau:.0f} s -> noise-driven period {apparent:6.0f} s "
          f"({apparent / PERIOD_ROD_BLOCK_S:4.1f} x the rod block, {apparent / PERIOD_TRIP_S:5.1f} x the trip)")

# Source range ratemeter: the 1/M plot is flown at the §3.5 reference rate, so size tau for usable precision there
for target in (0.10, 0.05, 0.03):
    tau = 1.0 / (SR_ALL_RODS_IN_CPS * target * target)
    print(f"       SR ratemeter: {target:.0%} precision at {SR_ALL_RODS_IN_CPS:.0f} cps needs tau = {tau:.2f} s")
check("SR ratemeter tau of 2 s gives", 1.0 / math.sqrt(SR_ALL_RODS_IN_CPS * 2.0), 0.045, 0.005, "relative")

print("       at tau 5 s the noise-driven period is off the §3.5 span entirely (-100 to +3 s), which is the point")
print("       consequence: the period channel is the SLOW protection. A 0.47 s excursion (all RR out, S-19)")
print("       rises e-fold every 0.47 s, so the 115 %FP overpower trip and the 10 %FP/s flux-rate trip reach")
print("       their setpoints long before a 5 s filter has caught up. §9.5 carries all three for that reason.")

print("\nHow far the noise sits from each §9.5 setpoint, with those filters")
pr_sigma = PR_RELATIVE * 100.0
print(f"       power range at 100 %FP: sigma {pr_sigma:.2f} %FP, trip at {PR_TRIP_PCTFP:.0f} -> "
      f"{(PR_TRIP_PCTFP - 100.0) / pr_sigma:.0f} sigma on one channel, and §9.5 needs 2 of 4")
checks.append((PR_TRIP_PCTFP - 100.0) / pr_sigma >= SIGMA_MARGIN)
dnd_sigma_rel = 1.0 / math.sqrt(DND_BACKGROUND_CPS * 2.0)
print(f"       DND at {DND_BACKGROUND_CPS:.0f} cps background with tau 2 s: sigma {dnd_sigma_rel:.1%}, "
      f"alarm at x{DND_ALARM_FACTOR:.0f} -> {(DND_ALARM_FACTOR - 1) / dnd_sigma_rel:.0f} sigma")
checks.append((DND_ALARM_FACTOR - 1) / dnd_sigma_rel >= SIGMA_MARGIN)

print(f"\n{sum(checks)}/{len(checks)} checks pass")
raise SystemExit(0 if all(checks) else 1)
