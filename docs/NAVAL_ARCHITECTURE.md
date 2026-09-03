# Weighing a design

> Armour is expensive because it is **weighed**, not because a number says so.

`src/sim/naval_arch/` takes a ship — historical preset or player design, the code cannot
tell them apart — and works out what she weighs, where her centre of gravity is, how
stable she is and how fast she will go. The battle engine consumes the result; the
designer has no privileged path into combat.

---

## Why this module decides whether the designer is worth anything

Every tradeoff the ship designer is supposed to expose is **arithmetic**, not a rule:

```
thicker belt → more plate area × thickness × density → heavier
            → deeper draft, less freeboard, higher KG
            → same power pushing more ship → slower
```

Nothing in the code connects those consequences to each other. There is no "armour
costs speed" coefficient. There is plate, and plate has mass.

This is asserted directly — `test_thickening_the_belt_costs_displacement_and_speed`
doubles Iowa's belt and requires that she gets heavier and slower — and that test is
what caught the model's worst early flaw. Fuel used to be computed as *whatever was left
over* after everything else had been weighed, which meant the computed displacement
equalled the stated one **by construction**. The model could never be wrong, and
thickening a belt cost nothing but bunkerage. Fuel now comes from the data (full load
less standard displacement, which is what the difference between those two figures
means), so the displacement is a real prediction that can miss.

---

## The weight groups

| Group | Where it comes from |
|---|---|
| Hull structure | Cubic-number method: `W = C · L·B·D / 1000` |
| Superstructure and upperworks | Its own plating geometry, plus a fit-out allowance per m³ |
| **Armour** | **Every plate the structure builder produced: area × thickness × density** |
| Machinery | Power over specific power, which itself scales with ship size |
| Armament | Guns, mountings and ammunition, scaling with the **cube** of calibre |
| Crew, stores | Complement × an allowance per head |
| Fuel and reserve feed water | Full load less standard displacement, from the data |

Two of those deserve a note.

**Armour is not estimated.** It is summed over the real faces, which is what makes the
geometry's honesty load-bearing: a plate the wrong size is now a lie about the ship's
*weight*, not merely about her protection. Every armour-geometry fix in this project
was found by weighing a real ship and comparing.

**Machinery's specific power scales with displacement** — `28.7 × (57540/Δ)^0.256`.
A destroyer's plant was optimised for weight above all else; a battleship's carried
redundancy, huge reduction gears and subdivided armoured spaces. Without the scaling a
Fletcher's engines come out at 56% of her displacement.

---

## Stability

```
GM = KB + BM − KG
```

- **KG** comes from the weight groups, so a top-heavy design is genuinely top-heavy.
  Pile armour on the turrets and the centre of gravity rises until she is a bad gun
  platform, and nothing had to be told to do that.
- **BM = I/V**, with `I` **integrated over the hull's own stations** rather than taken
  from a form coefficient. One coefficient cannot describe a destroyer's fine waterplane
  and a battleship's full one at once; assuming a single value made every ship but the
  one it was fitted to read as far stiffer than she was.
- **KB** is a fraction of draft.

The superstructure is a weight group for exactly this reason. It is light — a few per
cent — but it sits higher above the keel than anything else aboard, and leaving it out
put every ship's centre of gravity more than a metre too low. A destroyer suffered
worst, because on her it is proportionally the largest thing above water.

---

## Speed

Admiralty coefficient, `V = (P·C / Δ^(2/3))^(1/3)`, with `C` fitted from real ships per
type: destroyer 150, cruiser 200, battleship 245, carrier 240. The length-to-beam bonus
that used to sit on top of this was removed — fineness is already inside the per-type
coefficient, and applying it twice made Baltimore a 37-knot ship.

---

## Calibration, and where it still misses

Checked against five ships spanning 2,500 to 73,000 tonnes:

| | displacement | speed | GM |
|---|---|---|---|
| USS Iowa | +4.8% | 32.3 vs 33.0 kn | 2.5 (real ~2.9) |
| IJN Yamato | +4.6% | 27.3 vs 27.0 kn | 3.4 (real ~3.0) |
| USS Baltimore | −0.1% | 33.1 vs 33.0 kn | 2.2 (real ~1.8) |
| USS Fletcher | +4.4% | 36.2 vs 36.5 kn | 1.9 (real ~1.0) |
| **Bismarck** | **+17.0%** | 29.0 vs 30.1 kn | 4.2 (real ~4.0) |

**Bismarck is the known outlier, and it is asserted as one** rather than quietly
excluded, so the test fails and says so the moment the armour geometry improves. The
cause is that generated plate gives her more armour than she carried: her citadel really
was unusually long and she really did spend an enormous fraction of herself on
protection, so the model exaggerates what was already extreme.

The residual bias across the roster is the same in kind — armour weighed from generated
geometry runs somewhat heavy against published totals, worst on the most heavily
armoured ships. The validator's overweight tolerance is set at 6% to cover it, and says
so in `data/config/naval_architecture.json` rather than pretending the model is tighter
than it is.

---

## The validator warns; it never fixes

The specification is explicit: a player may build an unrealistic design, and the
simulation then shows the consequences. So every finding states a reason and none
prevents anything. A design that is too heavy floats deeper and goes slower because the
arithmetic says so, not because the validator refused it.

Two rules learned from firing it at real ships:

- **Thresholds that are proportional in reality must be proportional here.** Freeboard
  is judged against length and magazine exposure against beam. Two and a half metres of
  freeboard is normal on a destroyer and alarming on a battleship, so an absolute limit
  either passes everything or condemns every small ship ever built.
- **Say what happens, not that it is forbidden.** A ship heavier than her drawn draft
  allows does not fail to float; she settles until she displaces her own weight. The
  finding reports the sinkage in metres and what fraction of her freeboard it eats, and
  its severity follows from that.

A validator that fires on Yamato is a validator nobody reads.
