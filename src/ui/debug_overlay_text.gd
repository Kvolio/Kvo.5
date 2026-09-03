class_name DebugOverlayText
extends RefCounted

## The causality chain as lines of text.
##
## Separated from the overlay for the same reason the combat log's formatting is: this
## is the part that reads a `HitReport` and says what the shell did, and it should be
## readable from a headless dump and testable without a scene tree.


## The whole chain as lines of text.
##
## Static and world-free, so the same formatting serves the overlay, a headless dump
## and any future export. Three versions of this would eventually disagree about what
## happened, which would defeat the purpose of having it at all.
static func describe(report: HitReport) -> Array[String]:
	var out: Array[String] = []
	out.append("%s, %.0f mm, %.0f kg" % [
		report.shell_name, report.calibre_mm, report.mass_kg])
	out.append("    fired at %.1f km, %.0f s in the air" % [
		report.range_m / 1000.0, report.time_of_flight])
	out.append("    striking %.0f m/s, falling %.1f deg, aspect %.0f deg%s" % [
		report.striking_velocity, report.descent_angle_deg, report.aspect_deg,
		"" if report.hit_above_water else ", below the waterline"])
	out.append("")

	for interaction: HitReport.LayerInteraction in report.interactions:
		out.append("%d. %s%s" % [interaction.order + 1,
			_kind(interaction.kind),
			"" if interaction.label.is_empty() else "  %s" % interaction.label])
		out.append("    %.1f m in, %.0f m/s -> %.0f m/s" % [
			interaction.distance_m, interaction.speed_before, interaction.speed_after])
		var outcome: PenetrationOutcome = interaction.outcome
		if outcome == null:
			continue
		out.append("    %s: %.0f mm at %.0f deg = %.0f mm effective, against %.0f mm capability" % [
			_result(outcome.result), _plate_thickness(interaction),
			outcome.obliquity_deg, outcome.effective_thickness_mm,
			outcome.penetration_capability_mm])
		if outcome.normalization_deg > 0.01:
			out.append("    cap bit and turned it %.1f deg towards the normal" %
				outcome.normalization_deg)
		out.append("    shell %.0f%% intact, cap %s, fuze %s" % [
			outcome.projectile_integrity * 100.0,
			_cap(outcome.cap_status), _fuze(outcome.fuze_state)])
		if not outcome.diagnostics.is_empty():
			out.append("    %s" % outcome.diagnostics)

	out.append("")
	out.append("Terminated: %s%s" % [
		HitReport.termination_to_string(report.termination),
		" — burst inside" if report.detonated else ""])
	out.append("    path %.1f m, deepest plate beaten %.0f mm" % [
		report.path_length_m, report.deepest_penetration_mm])

	if report.damage != null:
		out.append("")
		out.append("Effects")
		for effect: DamageReport.Effect in report.damage.effects:
			out.append("    %s %s%s" % [String(effect.kind), effect.label,
				"" if effect.note.is_empty() else " — %s" % effect.note])
		out.append("    integrity %+.3f, %d casualties" % [
			report.damage.integrity_delta(), report.damage.crew_casualties])
	return out


static func _plate_thickness(interaction: HitReport.LayerInteraction) -> float:
	if interaction.outcome == null:
		return 0.0
	# Recovered from the effective thickness rather than stored twice: two fields that
	# are meant to agree eventually will not.
	var secant: float = 1.0 / maxf(cos(deg_to_rad(minf(interaction.outcome.obliquity_deg, 80.0))), 0.17)
	return interaction.outcome.effective_thickness_mm / maxf(secant, 0.001)


static func _kind(kind: HitReport.InteractionKind) -> String:
	return ["ARMOUR", "STRUCTURE", "entered", "left", "COMPONENT", "exited the hull"][int(kind)]


static func _result(result: PenetrationOutcome.Result) -> String:
	return ["penetrated", "partial", "stopped", "ricochet", "shattered"][int(result)]


static func _cap(status: PenetrationOutcome.Cap) -> String:
	return ["none", "intact", "stripped"][int(status)]


static func _fuze(state: PenetrationOutcome.Fuze) -> String:
	return ["unarmed", "armed", "triggered", "failed"][int(state)]
