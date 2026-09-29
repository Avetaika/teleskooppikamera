# teleskooppi-cli

Kehityskomentorivityökalu ytimelle (`Core/`, vain Foundation). Toimii Windowsilla, Linuxilla ja macOS:llä. Ei ulkoisia riippuvuuksia.

```
swift run --package-path Core teleskooppi-cli <komento> [valinnat]
swift build --package-path Core -c release   # nopeampi; binääri: Core/.build/release/teleskooppi-cli
```

Alla `cli` tarkoittaa jompaakumpaa yllä olevista. `cli help` tulostaa kaikki valinnat.

## simulate

Simuloitu kaksisiirtoinen kalibrointi (`SimulatedMount` + `SyntheticSky`). Kirjoittaa avainkehykset (PGM), `track.pgm`-kuvan, `summary.txt` ja `summary.json` hakemistoon `--out` (oletus `sim-out`).

```
cli simulate --seed 7 --theta 123 --mirror --backlash 5 --level 3 --out sim-out
cli simulate --seed 3 --random --no-images      # plan.md 4.8:n satunnaisalueet
cli simulate --runs 1000 --seed 1               # eräajo: vain tilastot (kiertokulmavirhe, kesto, epäonnistumiset)
```

Muut valinnat: `--drift`, `--jitter`, `--alt`, `--misalign`, `--analog`, `--dropout`, `--fps`.

## simulate --record

Renderöi jokaisen kehyksen ja kirjoittaa täyden nauhoitteen (`session-YYYYMMDD-HHMMSS.tcs/`, D-11) valittuun hakemistoon. Perusajo kirjataan myös `meta.json`:iin vertailukalibroinniksi.

```
cli simulate --seed 7 --record recordings/sim
cli simulate --seed 7 --record recordings/sim --scale 0.4 --fps 10   # nopea, pieni kuva
```

Nauhoitteet ovat `recordings/`-hakemistossa, joka ei ole gitissä. Pienet testikatkelmat kuuluvat kansioon `Core/Tests/Fixtures/`.

## sun

Auringon atsimuutti ja korkeus (aurinkoturvallisuuden tarkistukseen, D-19). Oletus: nyt, Helsinki.

```
cli sun
cli sun --date 2026-09-29T15:30:00Z --lat 60.17 --lon 24.94
```

Tulostaa varoituksen, jos aurinko on ylhäällä länsi-/luoteissektorissa.

## info

Yhteenveto nauhoitteesta: laite, formaatti, kehysmäärä, kesto, keskimääräinen fps, kehysvälien aukot, profiili, kalibrointi ja tapahtumat. Ilmoittaa katkenneesta viimeisestä kehyksestä.

```
cli info recordings/sim/session-20260929-153000.tcs
```

## export-pgm

Vie kehykset PGM-kuviksi (`frame-000123.pgm`), esim. katsottavaksi tai ulkoisiin työkaluihin.

```
cli export-pgm recordings/sim/session-20260929-153000.tcs --from 100 --to 200 --step 5 --out pgm-out
```

## replay

Ajaa nauhoitteen läpi tunnistuksen (`StarDetector` + `StarTracker`) ja kalibrointitilakoneen ja tulostaa raportin: näytteiden osuus, analyysiaika/kehys, kehotteet, tulos ja ero `meta.calibration`-arvoon.

```
cli replay recordings/sim/session-20260929-153000.tcs
cli replay <session> --shift                      # päiväkuva: koko kuvan siirtymä (ShiftEstimator)
cli replay <session> --from 50 --to 900 --verbose # rivi per kehys
cli replay <session> --cx 480 --cy 360 --radius 380 --lock-x 500 --lock-y 300
cli replay <session> --no-markers                 # ohita calibration.start / calibration.end -tapahtumat
```

Oletukset: optinen keskipiste ja kenttäsäde `meta.profile`:stä (muuten kuvan keskipiste ja 0,53 × korkeus); lukittava tähti `star.select`-tapahtumasta (muuten kirkkain lähellä keskustaa).
