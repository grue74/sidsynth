# SidSynth

The main web page of SidSynth, the family of Commodore 64 SID synthesizers
built on one shared core (synthcore): SID303 (acid bass), SID808 (drum
machine) and SID101 (lead synth), and the synths to come.

    python make_site.py [--no-synths]

writes `site/`, ready to upload as it is: the main page at the root, each
synth's page in its folder (`site/sid303/`, `site/sid808/`, `site/sid101/`). This is the
family's one web site, and all web work happens here: each synth's
`make_site.py` (in `projects/<synth>`, next to this folder) writes its own
folder here, and this runs them first. `--no-synths` keeps the synth
folders as they are and only rewrites the main page.

| File | What |
|---|---|
| `make_site.py` | the page (template, the synths' cards, the core diagram) and the build |
| `assets/favicon.svg` | the icon, a SID chip on orange; `favicon-32.png` and `apple-touch-icon.png` are rendered from it |

To add a synth: an entry in `SYNTHS` in `make_site.py` (its folder, card
screenshot and facts), its `make_site.py` writing to
`../sidsynth/site/<synth>/`, and a `../` link back from its own page.

Copyright (C) 2026 Jarkko Lehti. GPL-3.0-or-later.
