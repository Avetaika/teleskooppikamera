# HANDOVER: projektin siirto toiselle avustajalle (esim. ChatGPT / Codex)

Päivitetty: 2026-09-29. Tämä tiedosto on tarkoitettu **toiselle tekoälyavustajalle**, joka jatkaa projektia, jos Claude Coden käyttöraja täyttyy. Käyttäjä (Henri) puhuu suomea; **vastaa hänelle suomeksi**, koodi ja commit-viestit englanniksi.

## 1. Mikä tämä on
iPhone 17 -sovellus, joka toimii kaukoputken okulaarikamerana (Sky-Watcher Heritage 150P + Virtuoso GTi, afokaalinen Celestron NexYZ). **MVP:n tavoite:** kalibroitu liikeohje. Ruutu kertoo isolla punaisella nuolella, mihin suuntaan SynScanin ohjaimen tattia painetaan (`TATTI ←`), jotta tähti saadaan ristikkoon katsomatta ohjetta. Myöhemmin: EAA (live-pinoaminen), plate solving, jalustan suora ohjaus.

Repo: https://github.com/Avetaika/teleskooppikamera (julkinen, haara `main`). Paikallinen kansio: `C:\Users\Henri\Documents\Teleskooppikamera`.

**Lue tässä järjestyksessä:** `CLAUDE.md` → `plan.md` (arkkitehtuuri, matematiikka, vaiheet) → `decisions.md` (D-01…) → `docs/ohje.md` (Henrin tehtävälista) → `docs/install.md`.

## 2. Ympäristön rajoitteet (tärkeät)
- Henrillä on **vain Windows 11, ei Macia**. iOS-sovellus voidaan **kääntää vain GitHub Actionsissa** (`macos-26`, Xcode 26.6). Paikallista `xcodebuild`ia ei ole.
- Paikallinen Swift 6.4 on asennettu, mutta **Visual Studio Build Tools puuttuu**, joten `swift test` ei käänny paikallisesti. **Totuus on Linux-CI** (`core-tests`).
- `Core/` (Swift-paketti `TeleskooppiCore`) saa importata **vain `Foundation`in** (ei simd, Accelerate, CoreGraphics, AVFoundation, Metal, UIKit, SwiftUI, os.log, Combine). Kaikki logiikka testataan siellä synteettisellä datalla. `App/` on ohut kerros (kamera, Metal, UI).
- Sovellus on Swift 6, tiukka rinnakkaisuustarkistus. `.xcodeproj` generoidaan CI:ssä XcodeGenillä (`App/project.yml`), sitä ei versioida.
- Puhelin: iPhone 17, ilmoittaa itsensä iOS 27.0:ksi; sovellus käännetään iOS 26.0 -kohteelle (toimii molemmilla).
- Työnkulku: kehitä haarassa → push → `gh run watch` / `gh run view <id> --log-failed` → kun `core-tests` ja `ios-build` ovat vihreitä, yhdistä mainiin. Älä `git add -A` (useita agentteja on työskennellyt samassa kansiossa).
- Commit-viestin loppuun käytetty rivi: `Co-Authored-By: <malli> <noreply@anthropic.com>` (Claude-avustajilla; sinä käytä omaa).

## 3. Tila (2026-09-29)

| Vaihe | Sisältö | Tila |
|---|---|---|
| 0 | Työkaluketju, kamerasovellus, kyvykkyysraportti, CI, `docs/install.md` | ✅ main, CI vihreä. **Ei vielä asennettu puhelimeen** (Sideloadly-ongelma, ks. 4) |
| 1 | `Core`: geometria, synteettinen taivas, simuloitu jalusta, kalibrointi, liikeohje, aurinko. 59 testiä, kiertokulman virhe p95 0,78° / 1000 satunnaistapausta | ✅ main |
| 2 | Metal-livekuva, yö-UI, kamerasäädöt, aurinkomuistutus | haara `phase2` vihreä; **yhdistäminen mainiin kesken** (agentti käynnissä) |
| 3–4 (ydin) | Nauhoitusformaatti, StarDetector, StarTracker, ShiftEstimator, FieldCircleDetector, CLI | haara `core34-clean` vihreä; **yhdistäminen kesken** |
| 3–4 (sovellus) | Nauhoitus/toisto sovellukseen, tunnistus livenä | ei aloitettu |
| 5 | Kalibrointi + liikeohje sovelluksessa (MVP:n ydin) | ei aloitettu |
| 6 | Profiilit, palaute, viimeistely → MVP | ei aloitettu |

Tarkista `git branch -r` ja `gh run list`, onko haarat yhdistetty. Vaiheiden tarkat testit ja hyväksymiskriteerit: `plan.md` luku 10.

## 4. Avoin ongelma: Sideloadly-asennus
Henri yritti asentaa allekirjoittamatonta IPA:ta (`ios-build`-ajon artefakti `ipa`) Sideloadly v0.70.0:lla. Virhe: `Install failed: Guru Meditation … Login failed: 404` (Applen kirjautumispalvelu). Yritettävät korjaukset: iTunes-uloskirjautuminen/sisäänkirjautuminen, iTunes+iCloud Applen sivuilta (ei Storesta), sovelluskohtainen salasana, reaaliaikaisen virustorjunnan tauko, Sideloadlyn päivitys. Vaihtoehdot: ks. `docs/install.md` (kohta ”Vaihtoehtoiset asennustavat”, jos lisätty) tai:
1. **AltStore Classic / SideStore** (ilmainen Apple ID, sama 7 päivän raja).
2. **Maksullinen Apple Developer -tili (99 $/v)** + CI:n allekirjoitus App Store Connect API -avaimella + **TestFlight** (ei tarvitse PC:tä, 90 päivän käännökset). Vaatii Henrin päätöksen ja maksun; tee vain, jos hän erikseen pyytää.

## 5. Seuraavat askeleet (järjestyksessä)
1. Varmista, että `phase2` ja `core34-clean` on yhdistetty mainiin ja main on vihreä.
2. Henri saa IPA:n puhelimeen → hän lähettää `capability-*.txt` ja `app-log.txt` → täytä `docs/device-iphone17.md` ”Mitattu”-sarake.
3. **Vaihe 3 (sovellus):** `SessionRecorder` sovellukseen (käyttää Coren `SessionWriter`ia), `ReplayFrameSource`, tiedostonjako. Nauhoita oikeita kehyksiä.
4. **Vaihe 4 (sovellus):** ota `StarDetector`/`StarTracker`/`ShiftEstimator` käyttöön livekuvassa (2× binnattu Y-taso, ≤ 15 Hz), overlay.
5. **Vaihe 5:** `CalibrationSession` + UI-kulku (`plan.md` 4.3, 4.6), STOP-signaali (ääni + haptiikka), `GuidanceEngine` nuolena, konventioasetus. **Tarkista kentällä:** onko SynScanin tatti analoginen vai on/off ja liikkuuko vinottain (`decisions.md` D-24, vaikuttaa kalibroinnin harhaan).
6. Vaihe 6 ja sen jälkeen `plan.md` luvun 10 taulukko.

## 6. Tärkeimmät suunnittelupäätökset lyhyesti
- Kalibrointi kahdella liikkeellä (tatti YLÖS, OIKEALLE), 2×2-matriisi kuvakoordinaateista, kierto Procrustes-menetelmällä, peilaus determinantin etumerkistä. Suunta sovitetusta suorasta (väli ja ajelehtiminen eivät vääristä). `plan.md` luku 4.
- Kuvakoordinaatit ovat kameran natiivipuskurissa (u oikealle, v alas); kaikki kierrot yhdellä 3×3-matriisilla Metal-shaderissa (D-05, D-10).
- Renderöinti `AVCaptureVideoDataOutput` + Metal, ei preview layeria (D-04).
- Ohjauskonventio ”ikkuna”: tähti ristikon vasemmalla → nuoli vasemmalle → tatti vasemmalle; käännettävissä asetuksella (D-09).
- Pisin valotus videossa ≈ 1 s; Apple tekee kohinanpoiston aina; EAA:ssa myöhemmin 12 MP Bayer RAW (D-22).
- Jalustan suora ohjaus (myöhemmin): UDP 11880, Sky-Watcher motor controller -protokolla. Ensin vain luku. **Aurinkokieltoalue ja kuolleen miehen kytkin ennen ensimmäistä liikekomentoa** (D-19, D-20).

## 7. Turvallisuus
Kaukoputken **ei koskaan** saa osoittaa aurinkoon tai sen lähelle (silmä- ja kennovaara). Parvekkeen näkymä on luoteeseen; syys-lokakuun iltapäivinä aurinko on lännessä näkymän reunassa. Päivätestit aamupäivällä. Mikään koodi ei saa liikuttaa jalustaa ilman aurinkokieltoaluetta.

## 8. Työtapa Henrin kanssa
- Hän haluaa, että isot työt pilkotaan ja delegoidaan aliagenteille/rinnakkaisiin tehtäviin, ja että jokainen vaihe päättyy testiin.
- Kirjaa merkittävät valinnat `decisions.md`:hen (seuraava vapaa numero D-25 tai suurempi; tarkista tiedosto) ja vaiheiden tila `plan.md` luvun 10 kohtiin.
- Laitteelta mitatut arvot → `docs/device-iphone17.md`.
- Älä tee peruuttamattomia tai ulospäin näkyviä toimia (julkaisu, tilin luonti, maksut, salasanojen syöttö) ilman Henrin erillistä lupaa.
- Ole rehellinen testituloksista: jos jokin ei ole vielä laitteella todennettu, sano se.

## 9. Pikakäskyt
```bash
git fetch && git branch -r            # haarat
gh run list --limit 8                 # CI-tila
gh run view <id> --log-failed         # virheet
gh run download <id> --name ipa       # IPA Henrille
```
