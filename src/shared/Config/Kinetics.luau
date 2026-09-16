--!strict
-- Kinetics constants. Spec §3.1, §14.2.
-- NOTE (D-011): the six group βᵢ sum to 360.3 pcm, not the rounded β_eff of 360. The amplitude equation must use
-- Σβᵢ so a critical reactor stays exactly critical; betaEff_pcm is kept as the §3.7 validation target.
local P = require(script.Parent.Provenance)
local spec = P.spec

return {
	betaEff_pcm = spec(360, "§3.1"),
	generationTime_s = spec(4.0e-7, "§3.1 (Λ)"),
	meanDelayedLifetime_s = spec(10.7, "§3.1"),

	-- Six delayed-neutron groups blended for MOX (Pu-239, U-238 fast fission, U-235)
	groups = spec({
		lambda_ps = { 0.0130, 0.0315, 0.135, 0.345, 1.37, 3.82 },
		abundance = { 0.024, 0.198, 0.185, 0.366, 0.171, 0.056 },
		beta_pcm = { 8.8, 71.3, 66.6, 131.8, 61.6, 20.2 },
	}, "§3.1"),

	-- No xenon in a fast spectrum; Np-239 → Pu-239 adds reactivity over the week after shutdown
	np239Worth_pcm = spec(30, "§3.1 note: about +30 pcm over the week after shutdown"),
	np239HalfLife_d = spec(2.36, "§3.1 note"),

	-- Prompt-jump amplitude is valid while ρ stays below this fraction of β; above it, hand over to a scripted event
	promptJumpLimit_fracBeta = spec(0.9, "§14.2: 'holds while ρ stays below about 0.9β'"),
}
