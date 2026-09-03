# Sources and confidence

Historical sources disagree. Displacements are quoted standard or full load or
somewhere between; trial speeds were achieved light and in flat water; armour
thicknesses are given at one point on a plate that tapers. So this project does not
pretend to a single true value. It records what it used, where that came from, and
how much to trust it — and puts every number in an editable file so a correction is a
data edit rather than a code change.

## How it works

Every ship file in `data/ships/` carries:

- **`sources`** — the references the figures came from.
- **`notes`** — what is interesting or unusual about the design, in plain language.
- **`_note` / `_speedNote` / `_turningNote`** on individual fields, where a specific
  number needs explaining (why 33 knots and not 32.5; why an inclined belt taper is
  recorded at its thickest point).

Shell files in `data/ammo/` and material entries in `data/materials/armor.json` carry
a **`confidence`** marker:

| | meaning |
|---|---|
| `high` | Well documented and consistent across sources. |
| `medium` | Sources vary; the value used is a reasonable reading of them. |
| `low` | Genuinely uncertain, disputed, or derived rather than documented. Expect to revisit it. |

## The values most worth doubting

**Japanese armour quality.** `jpn_vh` carries a quality factor of 0.92 against US
Class A at 1.00. Post-war US testing of captured Japanese plate suggested it was
inferior, particularly in the very thick sections used on Yamato, but the size of the
penalty is disputed and the testing methodology has been questioned since. This one
number decides whether Yamato's 410 mm belt behaves like 410 mm. It is marked `low`
and is the first thing to change if she feels wrong.

**Every other armour quality factor.** National test standards differed, and plate
quality varied between batches within a single navy. The factors here are a
defensible middle reading, not a measurement.

**Tactical diameters.** Turning circles were measured at particular speeds and
loadings, and most are not published at all. Where no trial figure was available, a
value typical for the ship's size and rudder arrangement is used and marked `low`.

**The 4.7"/45 Mark IX.** Its solved ballistic form factor (1.214) falls outside the
plausible band for a shell of that shape, which means one of the published figures
used for it — mass, muzzle velocity or maximum range — is unreliable. Flagged in the
data rather than quietly accepted. See `docs/BALLISTICS.md`.

**Trial speeds.** Where a design speed and a deep-load speed both exist, the deep-load
figure is used, because ships fight at full load. Fletcher is entered at 36.5 knots
rather than the 38 usually quoted for exactly this reason.

## Belt tapers

A belt is not a slab. It carries its full thickness over the strake around the waterline
and tapers below it, where its job is to catch shells that fell short and travelled on
underwater rather than to resist a direct hit. `lowerEdgeThicknessMm` records the lower
figure; where a scheme states none the plate is modelled as uniform.

| Ship | Belt | Lower edge |
|---|---|---|
| USS Iowa | 307 mm | 41 mm — doubles as torpedo protection |
| USS South Dakota | 310 mm | 218 mm |
| IJN Yamato | 410 mm | 75 mm — the lower belt *was* her holding bulkhead |
| Bismarck | 320 mm | 170 mm |
| HMS King George V | 374 mm | 140 mm |
| HMS Vanguard | 356 mm | 114 mm |
| USS Baltimore | 152 mm | 102 mm |

Ships absent from this table (Cleveland, Mogami, Admiral Hipper, the carriers) are
modelled as uniform because no lower-edge figure was to hand — not because they had
none. Adding one is adding a number to `data/ships/`.

## Where the weight model still misses

`docs/NAVAL_ARCHITECTURE.md` records the calibration against five ships and the residual
bias: armour weighed from generated plate geometry runs somewhat heavy against published
totals, worst on the most heavily armoured ships. Bismarck is the outlier at +17%, and
that is asserted by test rather than excluded, so it will stop being true visibly.

## Principal references

- Friedman, *US Battleships / US Cruisers / US Destroyers / US Aircraft Carriers: An Illustrated Design History*
- Garzke & Dulin, *Battleships* (United States; Axis and Neutral)
- Raven & Roberts, *British Battleships of World War Two*
- Brown, *Nelson to Vanguard: Warship Design and Development 1923–1945*
- Lacroix & Wells, *Japanese Cruisers of the Pacific War*
- Skulski, *The Battleship Yamato*
- Whitley, *German Cruisers of World War Two*
- Lengerer, *The Aircraft Carriers Shokaku and Zuikaku* (Warship series)
- Jurens, *The Loss of HMS Hood — A Re-Examination*
- NavWeaps.com, for gun, mounting and ammunition particulars and range tables
- US Navy Bureau of Ships booklets of general plans

## Correcting something

1. Edit the value in `data/`.
2. Update its `confidence` and add a note saying what changed and why.
3. Run `tools/test.sh`. The roster suite checks internal consistency, and the
   ballistics suite checks trajectories against published range tables — so a
   correction that breaks something else will say so.
