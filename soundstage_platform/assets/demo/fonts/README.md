# Demo fonts

Bundled for the T0.7 sound demo (`assets/demo/sound.stage.json`) and runtime tests. Both are
variable fonts from the Google Fonts repository (`github.com/google/fonts`, `ofl/` directory),
licensed under the **SIL Open Font License 1.1**. Each font's licence text is next to it.

| File | Family | Axes | Licence | Source |
|---|---|---|---|---|
| `Fraunces-Variable.ttf` | Fraunces (Undercase Type) | `opsz` 9–144, `wght` 100–900 (default 900), `SOFT` 0–100, `WONK` 0–1 | OFL 1.1 (`Fraunces-OFL.txt`) | `ofl/fraunces/Fraunces[SOFT,WONK,opsz,wght].ttf` |
| `SpaceGrotesk-Variable.ttf` | Space Grotesk (Florian Karsten) | `wght` 300–700 (default 300) | OFL 1.1 (`SpaceGrotesk-OFL.txt`) | `ofl/spacegrotesk/SpaceGrotesk[wght].ttf` |

Metrics (read with fontTools, used as reference values in `test/runtime/fonts_test.dart`):

| File | unitsPerEm | OS/2 | sCapHeight | sxHeight | typo asc/desc | win asc/desc |
|---|---|---|---|---|---|---|
| Fraunces | 2000 | v4 | 1400 | 964 | 1956 / −510 | 2340 / 609 |
| Space Grotesk | 1000 | v4 | 700 | 486 | 984 / −292 | 1150 / 292 |
