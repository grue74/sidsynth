# The band: SID101, SID303 and SID808 played by Steinberg Pro-16

A cover of *Trip 2 Jupiter* (Torben Hansen / Metal, 1994; HVSC
`/MUSICIANS/M/Metal/Trip_2_Jupiter.sid`) played by the SidSynth synths,
conducted by the 1986 C64 MIDI sequencer Steinberg Pro-16, four VICEs in
real time joined by virtual MIDI cables.

| File | What |
|---|---|
| `sidlog.py` | a VICE SID dump (`vsid -sounddev dump`) as the SID's state per frame |
| `transcribe.py` | the cover as a MIDI file from the tune's SID writes: SID101 the arpeggios (ch 1), SID303 the sliding bass (ch 2), SID808 drums written for it (ch 10); 64 bars at 94 BPM |
| `vmidi.py` | virtual MIDI ports through the teVirtualMIDI driver (installed with loopMIDI), with ctypes |
| `vice.py`, `vice_band.py` | one VICE in the desktop session (schtasks /it: from the services session GTK VICE runs at ~15 %), driven by its remote monitor; the WinMM MIDI device numbers VICE uses |
| `pro16.py` | Pro-16 2.4 in VICE, played from a script: its keyboard scan and RUN/STOP read patched to a mailbox |
| `session.py` | the ports and Pro-16 together: setup, recording a part on Pro-16's own MIDI clock, playing |
| `record_cover.py` | records the cover's three parts into Pro-16 and saves the song on a disk |
| `play_band.py` | Pro-16 loads the song and plays it to the three synths; their sound recorded |
| `mix_band.py` | the three live recordings mixed (play_band.py calls it): each matched to its exact render and moved onto the song (each VICE drifts), balanced |
| `levels.py` | the balance: each part's loudness measured (EBU R128), its gain to the target (the lead 2 LU over bass and drums) |
| `feeds.py` | each synth's part as a test build playing it by itself (the core's test feed, in the synth's own ticks; a wrapper source, the synth projects unchanged) |
| `pro16_render.py` | Pro-16 playing the song rendered frame by frame (checkpoints on its playback loop, the cycle counter numbering the frames) |
| `compose.py` | the presentation video: the four screens 2x2, the three synths' sound mixed (and as .mp3) |
| `router.py` | the router alone (record / play / direct modes), for use without the scripts |
| `sync.py` | a part's sound against the song's notes: its lag, and resampling a drifting part onto the notes |
| `songs.py` | the songs (`--song cover`, the default, or `--song glide`): file, Pro-16 name, bars, tempo, set-up, video labels |
| `glide_path.py` | *Glide Path*, the band's own demo tune: SID101's lead (glides, bends, the wheel, sync sweeps, the arpeggiator), every sound set by controllers |

Not in git: `work/` (the dump, the MIDI file, disks, recordings) and
`pro16/` (Pro-16 from frank-buss.de/c64/midi/pro-16.zip, distributed by
Frank Buss with Steinberg's permission).

    python sidlog.py ...                      # (a library)
    vsid -console -warp -silent -sounddev dump -soundarg work/t2j.dump -soundwarpmode 0 -limitcycles 182000000 Trip_2_Jupiter.sid
    python transcribe.py work/t2j.dump work/cover.mid
    python record_cover.py work/cover.mid work/songs.d64 work/trip2jupiter.d64
    # each part rendered in emulated time (the video's, and the live mix's reference)
    python feeds.py work/cover.mid work/feeds
    python ../../c64tools/vicerec.py work/feeds/sid101-cover.prg work/video/sid101.mp4 --frame-addr <video_frame> --seconds 168 --sid 8580 --skip 1   # and sid303, sid808
    python play_band.py work/trip2jupiter.d64 work/band work/cover.mid
    python mix_band.py work/band work/cover.mid       # (play_band.py does it: mix again)
    # the presentation video (glitch-free: everything rendered in emulated time)
    python pro16_render.py work/trip2jupiter.d64 work/video/pro16.mp4
    python compose.py work/video work/trip2jupiter-band.mp4

## Glide Path

The band's own tune (125 BPM, SID101's own tempo, so its arpeggiator on
its internal clock keeps time; 49 bars). Every sound change is a
controller in the file, which Pro-16 records and plays like the notes
(its input filters at start drop only controllers 3, 123 and 127). The
checks compare note ons, controllers and pitch bends clock by clock.

    python glide_path.py work/glide-path.mid          # + work/glide-path-cues.txt
    python record_cover.py work/glide-path.mid work/songs.d64 work/glide-path.d64 --song glide
    python feeds.py work/glide-path.mid work/feeds --song glide
    # vicerec.py each work/feeds/<synth>-glide.prg -> work/glide-video/<synth>.mp4 (--seconds 99), one at a time (port 6502)
    python play_band.py work/glide-path.d64 work/glide-band work/glide-path.mid --song glide
    python pro16_render.py work/glide-path.d64 work/glide-video/pro16.mp4 --seconds 99 --song glide
    python compose.py work/glide-video work/glide-path-band.mp4 --song glide

The parts line up by measurement (`sync.py`): `compose.py` moves each
render's sound onto its notes (vicerec's sound-to-picture placing is off
by tens of ms, differently per synth: the cover's renders +178, +143 and
-109 ms), and `mix_band.py` matches each live part to its render and
resamples it onto the song (each VICE's WAV runs at its own speed, about
0.2 % apart). Both mixes set each part's level by its measured loudness
(`levels.py`). The renders come before the live mix.
