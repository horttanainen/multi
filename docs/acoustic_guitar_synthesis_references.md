# Acoustic Guitar Synthesis References

This is the tracked source map for the single-pluck acoustic guitar work. Keep
this list limited to local PDFs or web pages/papers with usable readable
content. Do not add placeholder citations that only point to a stub page.

The local PDFs are stored in `docs/references/acoustic_guitar_synthesis/`, which
is ignored by git because of the repository `references/` ignore rule. The
tracked source map lives here so we can keep the working context in the repo.

## Local Papers

### Woodhouse, "On the synthesis of guitar plucks"

- Local file: `docs/references/acoustic_guitar_synthesis/Guitar_I.pdf`
- Read status: extracted with `pypdf` on 2026-05-03.
- Supports: `guitar-modal`, `guitar-contact-pick-modal`,
  `guitar-two-pol-modal`, `guitar-sms-fit`, `guitar-admittance-pluck`
- Paper takeaways:
  - The body is characterized by input admittance at the bridge, or an
    admittance matrix when both string polarizations are included.
  - The target response is coupled string/body vibration after a pluck, not a
    string oscillator plus an independent body impact.
  - The strongest methods in the paper's comparison are first-order modal
    synthesis and frequency-domain synthesis with string damping included.
  - The paper explicitly warns that the tested digital-waveguide approach was
    unsatisfactory for accurate guitar plucks in that setup, largely because of
    low string damping and stability/accuracy issues.
  - Pluck position and pluck angle matter because they change how the two string
    polarizations couple into body motion.

### Lee/French, "Circuit based classical guitar model"

- Local file: `docs/references/acoustic_guitar_synthesis/j.apacoust.2015.04.006.pdf`
- Read status: extracted with `pypdf` on 2026-05-03.
- Supports: `guitar-ks`, `guitar-commuted`, body-filter experiments
  and `guitar-admittance-pluck`
- Paper takeaways:
  - The body circuit is fitted to measured bridge/tie-block admittance, including
    top-plate and air-cavity resonances.
  - The string and body are integrated at the bridge boundary; the reflected
    wave back to the string and transmitted force to the body depend on
    frequency-dependent mechanical impedance.
  - In their comparison, the bridge-force-derived waveform sounded closer to the
    recorded guitar than the bridge-velocity-derived waveform.
  - Low body anchors around `101.6 Hz`, `118.8 Hz`, and `204.7 Hz` are useful
    starting points, but the paper fits many more resonances and phase response.

## Accessible Web References

### Columbia DSP: "Synthesizing a Guitar Using Physical Modeling Techniques"

- URL: `https://www.ee.columbia.edu/~ronw/dsp/`
- Supports: `guitar-ks`, `guitar-commuted`
- Notes: a simple waveguide sounds like a plucked string, but not a guitar,
  until excitation/body filtering is improved.

### Julius O. Smith, "Commuted Synthesis"

- URL: `https://www.dsprelated.com/freebooks/pasp/Commuted_Synthesis.html`
- Supports: `guitar-commuted`, future `guitar-hybrid-attack`
- Notes: because string and body are close to linear/time-invariant, excitation
  and resonator can be commuted into an aggregate excitation table.

### Laurson/Erkut/Valimaki/Kuuskankare, "Methods for Modeling Realistic Playing in Acoustic Guitar Synthesis"

- Full-text URL found: `https://www.researchgate.net/publication/234820549_Methods_for_Modeling_Realistic_Playing_in_Acoustic_Guitar_Synthesis`
- Metadata URL: `https://research.aalto.fi/en/publications/methods-for-modeling-realistic-playing-in-acoustic-guitar-synthes`
- Supports: `guitar-commuted`, `guitar-two-pol-modal`,
  future performance/articulation work
- Notes: describes commuted waveguide guitar synthesis with pluck/body
  wavetables, pluck-shaping filter, pluck-position comb filter, loop filters,
  variable delays, two polarization string models, and sympathetic coupling.

### Erkut/Karjalainen, "Finite Difference Method vs. Digital Waveguide Method in String Instrument Modeling and Synthesis"

- Full-text URL found: `https://www.researchgate.net/publication/228555575_Finite_difference_method_vs_digital_waveguide_method_in_string_instrument_modeling_and_synthesis`
- Supports: future `guitar-fdtd-lite`, `guitar-commuted`
- Notes: compares 1-D finite-difference string models with digital waveguides;
  FDTD-style approaches are more flexible for local excitation/interactions but
  cost more than commuted waveguide synthesis.

### AAS Strum GS-2 Manual

- URL: `https://www.applied-acoustics.com/strum-gs-2/manual/`
- Supports: `guitar-contact-pick-modal`, `guitar-two-pol-modal`
- Notes: separates string, pick/finger action, mute/palm, body, and effects.
  Pick parameters and body decay/tone are first-class controls.

### MTG/UPF SMS Tools and Serra/Smith Spectral Modeling Synthesis

- URL: `https://www.upf.edu/web/mtg/sms-tools`
- URL: `https://repositori.upf.edu/handle/10230/33796?locale-attribute=en`
- Supports: `guitar-sms-fit`
- Notes: deterministic sinusoids plus stochastic/noise residual are useful as
  a diagnostic upper-bound direction for partial/noise envelope control.

### Native Instruments Session Guitarist Picked Acoustic

- URL: `https://www.native-instruments.com/en/products/komplete/guitar/session-guitarist-picked-acoustic/`
- Supports: future `guitar-hybrid-attack`
- Notes: commercial sample-based guitars lean heavily on real recorded
  articulations, microphone setups, picking/finger styles, and performance
  controls.

### Modartt Pianoteq Guitar

- URL: `https://www.modartt.com/guitar`
- Supports: `guitar-two-pol-modal`, future sympathetic-string experiments
- Notes: commercial physical models emphasize sympathetic resonance,
  gesture/noise details, palm mute, slides, harmonics, and playing interaction.

### Fréour/Gautier/David/Curtit, "Extraction and analysis of body-induced partials of guitar tones"

- DOI/source page: `https://doi.org/10.1121/1.4937749`
- Search result source: `https://ouci.dntb.gov.ua/en/works/42gQOyBl/`
- Supports: bridge/body candidate design and body-transient diagnostics.
- Notes: guitar plucks include quasi-harmonic string modes coupled to the body
  plus short, quickly decaying body-mode transient components. This supports
  testing body response as bridge-coupled color, while watching that transient
  body sound does not become an audible separate hit.

### Le Carrou/Chadefaux/Fabre, "The Roving Wire-Breaking Technique"

- Source page: `https://www.sciencedirect.com/science/article/pii/S0003682X17309908`
- Supports: bridge-coupling parameter search.
- Notes: bridge mobility/admittance characterizes string/body coupling and
  governs the duration/power compromise for plucked strings. The mobility matrix
  also distinguishes the two string-polarization directions and their cross
  coupling.

### Välimäki/Erkut/Laurson, "Sound Synthesis of Plucked String Instruments Using a Commuted Waveguide Model"

- Source page: `https://research.aalto.fi/en/publications/sound-synthesis-of-plucked-string-instruments-using-a-commuted-wa`
- Supports: future commuted/body-response candidate work.
- Notes: commuted waveguide synthesis remains a relevant direction for
  precomputed excitation/body-response handling, but it should be tested as a
  separate candidate and not mixed into the maintained baseline without listener
  approval.

## Current Probe Candidate Map

Active default candidate:

- `guitar-modal-pluck`: maintained baseline path. It uses modal sustain with a
  coherent pluck-shaped excitation, short contact transient, and body-color
  path. This is the only candidate rendered by default while body coupling is
  being corrected.

Explicit body-coupling test candidate:

- `guitar-bridge-body-pluck`: starts from the maintained modal pluck voice but
  routes body color from bridge-force/string-motion input instead of feeding
  contact directly into body resonators. It is not part of the default round and
  must be promoted only after listener approval.

Parked legacy candidates:

- `guitar-modal`: damped modal/body baseline.
- `guitar-contact-pick-modal`: modal sustain plus sharper pick/string contact.
- `guitar-two-pol-modal`: two modal polarizations with different
  damping/frequency motion.
- `guitar-commuted`: body-shaped aggregate excitation into a simple string loop.
- `guitar-sms-fit`: sinusoid-plus-noise diagnostic candidate.
- `guitar-ks`: waveguide/Karplus-Strong candidate with body filtering.
- `guitar-waveguide-raw`: raw baseline only, not a candidate instrument.

These legacy candidates remain callable through explicit `--candidate`
arguments, but they are removed from the default scoring loop because listener
feedback rejected them or found them less useful than the accepted
`guitar-modal-pluck` baseline.

## Body Coupling Constraint

The next body-model work should follow the paper notes above: the body is a
coupled resonant response to string/bridge motion. It should not read as a
separate per-note impact sound. When a candidate creates a distinct knock,
thump, or drum-like onset for every note, treat that as a model failure before
continuing phrase-level tuning.

Rejected correction, 2026-05-03: removing the attack-body layer and synthetic
contact/release path from `guitar-modal-pluck` produced
`guitar_event_phrase_no_added_noise_pass1`, which listener feedback rejected.
The maintained path was restored to the last accepted baseline state. Future
body work should be tested as explicit candidates, not silently promoted into
the maintained instrument.

Explicit candidate pass, 2026-05-03: `guitar-bridge-body-pluck` adds the
bridge/body coupling change as its own instrument so it can be A/B tested against
`guitar-modal-pluck` without changing the accepted baseline.
