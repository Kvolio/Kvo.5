class_name DesignValidator
extends RefCounted

## Tells a designer what is wrong with a ship, and never fixes it for them.
##
## The specification is explicit about this: a player may build an unrealistic design
## if they wish, and the simulation then shows the consequences. So every finding here
## is a WARNING with a stated reason, and none of them prevents anything. A design
## that is too heavy floats deeper and goes slower because the arithmetic says so, not
## because the validator refused it.
##
## The findings are ordered by how much trouble they will cause.

enum Severity { NOTE, WARNING, SERIOUS }


class Finding extends RefCounted:
	var severity: Severity = Severity.NOTE
	var field: String = ""
	var summary: String = ""
	var detail: String = ""

	func to_dict() -> Dictionary:
		return {
			"severity": ["note", "warning", "serious"][int(severity)],
			"field": field, "summary": summary, "detail": detail,
		}


static func validate(spec: ShipSpec, template: ShipStructureTemplate,
		analysis: DesignAnalysis, config: Dictionary) -> Array[Finding]:
	var rules: Dictionary = config.get("validation", {}) as Dictionary
	var stability: Dictionary = config.get("stability", {}) as Dictionary
	var findings: Array[Finding] = []

	_check_weight(findings, analysis, rules)
	_check_stability(findings, analysis, stability)
	_check_proportions(findings, spec, analysis, rules)
	_check_machinery(findings, analysis, rules)
	_check_protection(findings, spec, template, analysis, rules)
	_check_armament(findings, spec, template)

	findings.sort_custom(func(a: Finding, b: Finding) -> bool:
		if a.severity != b.severity:
			return a.severity > b.severity
		return a.field < b.field)
	return findings


static func _add(findings: Array[Finding], severity: Severity, field: String,
		summary: String, detail: String) -> void:
	var finding: Finding = Finding.new()
	finding.severity = severity
	finding.field = field
	finding.summary = summary
	finding.detail = detail
	findings.append(finding)


static func _check_weight(findings: Array[Finding], analysis: DesignAnalysis,
		rules: Dictionary) -> void:
	var tolerance: float = float(rules.get("overweightToleranceFraction", 0.03))
	var excess: float = analysis.overweight_fraction()
	if excess > tolerance:
		_add(findings, Severity.SERIOUS, "displacement",
			"Overweight by %.0f%%" % (excess * 100.0),
			("The design weighs %.0f tonnes against a stated %.0f. She will float deeper "
			+ "than drawn, lose freeboard, and be slower than her power suggests — the "
			+ "commonest way a real design went wrong.")
				% [analysis.full_displacement_t, analysis.stated_displacement_t])
	elif excess < -tolerance * 3.0:
		_add(findings, Severity.NOTE, "displacement",
			"Lighter than stated by %.0f%%" % (-excess * 100.0),
			"There is displacement in hand for more armour, fuel or armament.")

	# Weighing more than the hull displaces at her drawn draft does not stop a ship
	# floating — it makes her float deeper. So say by how much, rather than declaring
	# a failure: extra draft is excess weight over tonnes-per-centimetre immersion, and
	# what matters is how much of her freeboard it eats.
	if analysis.sinkage_m > 0.01:
		var eaten: float = analysis.sinkage_m / maxf(analysis.freeboard_m, 0.1)
		var severity: Severity = Severity.NOTE
		if eaten > 0.5:
			severity = Severity.SERIOUS
		elif eaten > 0.15:
			severity = Severity.WARNING
		_add(findings, severity, "buoyancy",
			"Floats %.2f m deeper than drawn" % analysis.sinkage_m,
			("The hull displaces %.0f tonnes at the stated draft but the design weighs "
			+ "%.0f, so she settles until she displaces her own weight. That costs %.0f%% "
			+ "of her freeboard and puts more of the belt under water where it protects "
			+ "nothing.") % [analysis.buoyancy_t, analysis.full_displacement_t, eaten * 100.0])


static func _check_stability(findings: Array[Finding], analysis: DesignAnalysis,
		stability: Dictionary) -> void:
	var minimum: float = float(stability.get("minimumGmM", 0.9))
	var maximum: float = float(stability.get("maximumGmM", 3.6))

	if analysis.gm_m < 0.0:
		_add(findings, Severity.SERIOUS, "stability",
			"Negative metacentric height — she will not float upright",
			("GM is %.2f m. The centre of gravity is above the metacentre, so she will "
			+ "loll to one side or capsize alongside. Widen the beam, take weight out "
			+ "of the upperworks, or add ballast low down.") % analysis.gm_m)
	elif analysis.gm_m < minimum:
		_add(findings, Severity.SERIOUS, "stability",
			"Dangerously tender: GM only %.2f m" % analysis.gm_m,
			("She rolls slowly and lazily and has very little reserve against flooding "
			+ "or free surface. Too much weight high up — usually armour on the "
			+ "turrets and superstructure, or too narrow a beam for the topweight."))
	elif analysis.gm_m > maximum:
		_add(findings, Severity.WARNING, "stability",
			"Stiff: GM %.2f m" % analysis.gm_m,
			("She will roll back violently quickly, which makes her a poor gun platform "
			+ "and strains the structure. Usually excessive beam for the displacement."))


static func _check_proportions(findings: Array[Finding], spec: ShipSpec,
		analysis: DesignAnalysis, rules: Dictionary) -> void:
	if analysis.length_to_beam > float(rules.get("maxLengthToBeam", 12.0)):
		_add(findings, Severity.WARNING, "hull",
			"Extremely fine: length-to-beam %.1f" % analysis.length_to_beam,
			("Fast for her power, but there is very little beam to give her stability "
			+ "or to put an armour belt behind."))
	elif analysis.length_to_beam < float(rules.get("minLengthToBeam", 4.5)):
		_add(findings, Severity.WARNING, "hull",
			"Very beamy: length-to-beam %.1f" % analysis.length_to_beam,
			"Stable and roomy, and she will need far more power for any given speed.")

	if analysis.draft_to_beam > float(rules.get("maxDraftToBeam", 0.55)):
		_add(findings, Severity.WARNING, "hull",
			"Deep draft for her beam (%.2f)" % analysis.draft_to_beam,
			"Limits where she can operate, and reduces stability for a given displacement.")

	# Freeboard is judged against the ship's length, not against a fixed height. Two and
	# a half metres is normal on a destroyer and alarming on a battleship, so an
	# absolute limit either passes everything or condemns every small ship ever built.
	var min_freeboard: float = maxf(float(rules.get("minFreeboardM", 2.0)),
		spec.length_m * float(rules.get("minFreeboardLengthFraction", 0.018)))
	if analysis.freeboard_m < min_freeboard:
		_add(findings, Severity.SERIOUS, "hull",
			"Only %.1f m of freeboard for a %.0f m hull" % [analysis.freeboard_m, spec.length_m],
			("She will be wet forward and lose speed in any sea, and there is very "
			+ "little reserve buoyancy above the waterline to keep her up when flooded."))


static func _check_machinery(findings: Array[Finding], analysis: DesignAnalysis,
		rules: Dictionary) -> void:
	var margin: float = float(rules.get("machinerySpaceMarginFraction", 0.85))
	if analysis.available_volume_m3 <= 0.0:
		return
	if analysis.machinery_volume_m3 > analysis.available_volume_m3 / maxf(margin, 0.1):
		_add(findings, Severity.WARNING, "propulsion",
			"Not enough room for the machinery",
			("The plant needs about %.0f cubic metres and the hull provides %.0f. "
			+ "Either the machinery spaces have to grow — at the cost of magazines or "
			+ "fuel — or the power has to come down.")
				% [analysis.machinery_volume_m3, analysis.available_volume_m3])

	var difference: float = analysis.estimated_speed_kn - analysis.stated_speed_kn
	if absf(difference) > 2.5:
		_add(findings, Severity.WARNING, "propulsion",
			"Stated speed does not match the power",
			("%.0f shp on %.0f tonnes gives about %.1f knots, not the %.1f claimed. "
			+ "The simulation uses the stated figure to solve the hull's resistance, "
			+ "so a mismatch here means she accelerates unrealistically.")
				% [analysis.group_tonnes("Machinery"), analysis.full_displacement_t,
					analysis.estimated_speed_kn, analysis.stated_speed_kn])


static func _check_protection(findings: Array[Finding], spec: ShipSpec,
		template: ShipStructureTemplate, analysis: DesignAnalysis, rules: Dictionary) -> void:
	var armour_fraction: float = analysis.group_fraction("Armour")
	if armour_fraction > float(rules.get("armourFractionWarning", 0.55)):
		_add(findings, Severity.WARNING, "armour",
			"Armour is %.0f%% of displacement" % (armour_fraction * 100.0),
			("Very heavily protected, at the cost of everything else she could have "
			+ "carried. Historic battleships spent about a third."))

	# A magazine close to the shell plating is far more exposed than one behind a
	# belt, a void and a machinery space. The tracer will find it; say so first.
	# Scaled by beam: a metre of clearance is a different thing on a destroyer than on a
	# battleship. Reported as a warning, not an error — plenty of real ships were built
	# this way and paid for it, which is the point worth making rather than forbidding it.
	var exposure: float = spec.beam_m * float(rules.get("magazineExposureBeamFraction", 0.10))
	for index: int in template.volumes_with_role(ShipStructureBuilder.ROLE_MAGAZINE):
		var volume: GeometryPrimitives.Volume = template.volumes[index]
		var station: float = volume.centre().x / maxf(spec.length_m, 1.0)
		var half_beam: float = spec.hull().half_beam_at(station)
		var clearance: float = half_beam - maxf(absf(volume.minimum.y), absf(volume.maximum.y))
		if clearance < exposure:
			_add(findings, Severity.WARNING, "layout",
				"Magazine within %.1f m of the ship's side" % maxf(clearance, 0.0),
				("%s sits almost against the shell plating. A shell that gets through "
				+ "the side reaches it directly. Move it inboard or put protection "
				+ "between.") % volume.label)
			break

	if spec.ship_type == "battleship" and not spec.armour.has_torpedo_defence():
		_add(findings, Severity.WARNING, "torpedoDefence",
			"No torpedo defence system",
			("A capital ship with no layered underwater protection will be opened up "
			+ "by a single torpedo, whatever her belt is like."))


static func _check_armament(findings: Array[Finding], spec: ShipSpec,
		template: ShipStructureTemplate) -> void:
	if not spec.has_main_battery():
		_add(findings, Severity.WARNING, "armament", "No main battery", "She has nothing to fight with.")
		return

	# Arcs. A mount that cannot bear anywhere useful is weight carried for nothing.
	for mount: MountDef in spec.main_battery.mounts:
		var arc: float = mount.train_max - mount.train_min
		if arc < deg_to_rad(90.0):
			_add(findings, Severity.WARNING, "armament",
				"Turret %s has only %.0f degrees of training" % [mount.mount_id, rad_to_deg(arc)],
				"A mount this restricted is weight and armour spent on very little fire.")

	# Two turrets in the same place cannot both fire.
	for i: int in spec.main_battery.mounts.size():
		for j: int in range(i + 1, spec.main_battery.mounts.size()):
			var a: MountDef = spec.main_battery.mounts[i]
			var b: MountDef = spec.main_battery.mounts[j]
			if absf(a.station - b.station) < 0.04 and absf(a.lateral - b.lateral) < 0.3:
				_add(findings, Severity.SERIOUS, "armament",
					"Turrets %s and %s overlap" % [a.mount_id, b.mount_id],
					("They occupy the same part of the ship. One of them cannot be "
					+ "mounted, let alone fired."))
				return
