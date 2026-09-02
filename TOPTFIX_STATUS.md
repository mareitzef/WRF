# VPRM `Topt` fix and the online Topt-percentile ensemble

Branch `vprm-topt-fix-percentile-ensemble`, tag **`v0.3`**
(pairs with WPS v0.2; data release: Zenodo record 20395680).

---

## The bug

In `chem/module_ghg_fluxes.F` — subroutines `VPRM` and `dflux_dT` — the per-channel optimum
temperature `Topt` was assigned with Fortran `DATA` statements placed *inside* a runtime
`SELECT CASE(config_flags%vprm_opt)` / `if (p_ebio_gee_t == …)` block:

```fortran
CASE ('VPRM_table_MULTI')
   if (p_ebio_gee_t == p_ebio_gee) then
      DATA Topt /14.250, 23.580, .../     ! <-- never executed
   else if (p_ebio_gee_t == p_ebio_gee_2) then
      DATA Topt /9.7, 23.580, .../        ! <-- never executed
```

`DATA` is a **compile-time initializer**: it ignores runtime control flow entirely. With several
`DATA Topt` statements for one array the compiler keeps only the **first in source order** — the
`CASE('VPRM_table_US')` values `Topt = 20,20,20,20,20,22,18,0`. ifort issued no warning.

**Every parallel VPRM channel therefore ran with the same wrong `Topt`**, regardless of
`p_ebio_gee_t`, even though `rad0`/`lambda`/`alpha`/`RESP0` *did* vary correctly per channel
(those come from `chemics_init.F`, which uses proper executable assignment).

| field | affected? |
|---|---|
| `EBIO_GEE`, `EBIO_GEE_2` … `_5`, `EBIO_GEE_DPDT` | **yes** — ran at Topt=20/18 |
| `EBIO_GEE_REF`, `EBIO_GEE_DPDT_REF` | no — intended Topt equals the value the bug forced |
| `EBIO_RES*` | no — respiration has no Topt dependence |

Magnitude of the correction at midday 2012-07-27: **7–34 %** in the affected GEE channels.

### The fix

Replace every in-branch `DATA Topt /…/` with an executable assignment `Topt = (/…/)`, preceded
by a default before the `SELECT CASE`, and drop the duplicated lines. Applied in **both**
subroutines.

> **If you add a channel, never use `DATA` for a value that depends on runtime state.** This is
> the trap the whole bug rests on, and the compiler will not warn you.

## The extension: online Topt-percentile ensemble

Five new parallel channels (9–13) carry the p10/p25/p50/p75/p90 Topt-percentile ensemble, so it
is produced **online in one run** instead of five offline recompute passes:

```
EBIO_GEE_P10  EBIO_GEE_P25  EBIO_GEE_P50  EBIO_GEE_P75  EBIO_GEE_P90
EBIO_RES_P10  EBIO_RES_P25  EBIO_RES_P50  EBIO_RES_P75  EBIO_RES_P90
```

Existing channel names and indices are **unchanged** — the new fields are appended, so
downstream code reading `EBIO_GEE_2` by name is unaffected.

Parameters come from `WRF_VPRM_post/vprm_params_topt_p{10,25,50,75,90}.csv` in the
`WRF_VPRM_inComplexTopo` repo. Each member carries a self-consistent (Topt, PAR0, lambda)
triple — they are coupled by equifinality and must not be varied independently.

> **`lambda` must be negated when transcribed into the Fortran tables.** The CSVs store a
> positive light-use efficiency; WRF uses the GEE sign convention and clamps with
> `min(0.0,…)`, so a positive lambda silently zeroes every flux. An all-zero `EBIO_GEE_P*`
> field is the signature of getting this wrong.

The five `EBIO_RES_P*` are **identical to one another** by construction: alpha and beta are not
varied across members, because respiration carries no Topt dependence.

The new channels are **diagnostic only** — they feed no `co2_bio` tracer, so they add no
advected species.

## Files changed (5 files, +235/−29)

```
Registry/registry.chem      10 new eghg_bio state vars, 20 new misc param vars,
                            extended the ebioco2 (bio_emiss_opt==16) package list
chem/module_ghg_fluxes.F    the Topt fix (both subroutines) + 5 new dispatch branches
chem/chemics_init.F         new subroutine VPRM_par_initialize_percentiles + call site
chem/emissions_driver.F     5 new CALL VPRM blocks + dummy args + locals
chem/chem_driver.F          pass the 20 new grid% params through
```

`frame/module_state_description.F` and `inc/*.inc` are Registry-generated and deliberately not
committed — `./compile` regenerates them.

**A Registry change requires a full rebuild** (`./clean`, not `./clean -a`, then `./compile
em_real`): the new state variables change the `grid` derived type, so every object file must be
recompiled. Plain `./clean` preserves `configure.wrf`, `Registry/Registry` and
`run/namelist.input`; `-a` destroys them.

## Validation

Each resolution was cross-validated against an independent offline recomputation of the VPRM
equations (`WRF_VPRM_post/recompute_vprm_fluxes.py`) driven by that run's own archived T2 and
SWDOWN — a check that is immune to meteorological differences between runs:

| resolution | max abs. GPP difference | RECO difference |
|---|---|---|
| 54 km | 0.004 % | **0.000 %** |
| 9 km | 0.015 % | **0.000 %** |
| 3 km | 0.025 % | **0.000 %** |
| 1 km | 0.028 % | **0.000 %** |

RECO agrees exactly, which pins down the alpha/beta transcription and the unit conversion
(`mol km^-2 hr^-1` → `umol m^-2 s^-1` is a factor 1/3600). GPP agrees at float32 level.

At 54 km and 27 km — serial or near-serial, same MPI decomposition as the reference runs — the
unaffected control channels reproduce the pre-fix output **bit-for-bit** while the corrected
channels change. That is the sharpest confirmation that the fix altered exactly what it should.

`WRF_VPRM_post/verify_toptfix_channels.py` automates all of this and is re-runnable per
resolution.

### Comparing against older runs

Two effects will make control channels differ for reasons that are **not** the fix:

- **MPI decomposition.** WRF is not bit-reproducible across different rank counts. Over a 30 h
  window round-off diverges chaotically and cloud fields shift, giving local `SWDOWN`
  differences of hundreds of W m^-2. The 3 km reference used 256 ranks; the v0.3 run used 64.
- **`radt`.** The 9 km namelist previously had an empty `radt = ,`; it is now `radt = 9`.

The meteorology-independent control is `EBIO_RES_DPDT_REF` (= alpha*vegfra). It matches at
exactly `rel = 0` in every comparison, including 3 km — useful for confirming that the grid and
static fields are right when everything else legitimately differs.

## Known issue (pre-existing, not introduced here)

`EBIO_GEE` carries a few NaN cells — 2 of 10 528 at 9 km, 44 at 3 km — present identically in
the pre-fix runs. VPRM computes `Wscale = (1+LSWI)/(1+LSWI_MAX)` with no guard for the
non-xeric vegetation classes, so a cell whose `LSWI_MAX` is the fill value `-1` divides by zero.
WRF guards this only for `m==4 .OR. m==7`. It is a property of the VPRM input fields, not of the
flux code, and is left unfixed as out of scope.
