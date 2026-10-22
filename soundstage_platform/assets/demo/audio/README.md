# Demo audio

| File | What | Source | Licence |
|---|---|---|---|
| `lights_go_low.lrc` | Enhanced LRC lyrics ("Lights Go Low"), hand-written, with syllable-level `<mm:ss.xx>` word times | Original, written for Soundstage | CC0 1.0 (public domain dedication) |
| `lights_go_low.wav` | 16 s, 22.05 kHz mono PCM: one synthesised note per timed syllable of the LRC (A minor pentatonic, sine + 2 harmonics), a bass note per line and a closing chord | Generated procedurally by `tool/gen_sound_audio.dart` from the LRC, so audio and lyrics are in sync by construction | CC0 1.0 |

Regenerate the clip after editing the lyrics: `dart run tool/gen_sound_audio.dart`.
