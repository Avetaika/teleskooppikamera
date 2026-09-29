# Päätösloki

Jokainen merkittävä valinta, sen perustelu ja hylätyt vaihtoehdot. Uusin päätös alimpana. Jos päätös muuttuu, vanhaa ei poisteta: se merkitään **KORVATTU → D-nn**.

Muoto: **D-nn · otsikko** · päivämäärä · tila (VOIMASSA / AVOIN / KORVATTU)

---

### D-01 · Suunnitelma ennen koodia · 2026-09-29 · VOIMASSA
Ensimmäinen työ on `plan.md` + `decisions.md`, ei sovelluskoodia (briefin kohta 9).
**Miksi:** kalibroinnin matematiikka, alustarajoitteet ja Windows-kehitysketju vaikuttavat kaikki arkkitehtuuriin. Virheellinen perusoletus olisi kallis korjata myöhemmin.

### D-02 · Kehitysketju: Windows + GitHub Actions (macos-26) + XcodeGen + Sideloadly · 2026-09-29 · VOIMASSA
Käyttäjällä ei ole Macia. iOS-sovellus käännetään GitHub Actionsin `macos-26`-koneella. Xcode 26.6 kiinnitetään ja deployment target on iOS 26.0. Projekti määritellään XcodeGenillä (`project.yml`); `.xcodeproj`ia ei versioida. Allekirjoittamaton `.ipa` asennetaan Sideloadlyllä ilmaisella Apple ID:llä (toissijainen tunnus).
**Hylätyt:** Xcode Cloud (ensimmäinen määritys vaatii Macin ja maksullisen tilin). Tuist (Swift-manifestit ilman tyyppitarkistusta Windowsilla). Käsin ylläpidetty `.xcodeproj` (hauras). Pilvi-Mac-vuokraus (kallis, turha tähän).
**Myöhemmin:** maksullinen tili → allekirjoitus CI:ssä + TestFlight (90 päivän käännökset).
**Avoin:** repo julkinen (macOS-minuutit ilmaisia) vai yksityinen (noin 200 macOS-min/kk).

### D-03 · Puhdas Swift-ydin `TeleskooppiCore`, testattava Windowsilla · 2026-09-29 · VOIMASSA
Kaikki kalibroinnin, tunnistuksen, ohjauksen, simulaation ja nauhoiteformaatin logiikka on Swift Packagessa, joka importtaa vain `Foundation`in. Kielletyt: `simd`, `Accelerate`, `AVFoundation`, `Metal`, `CoreGraphics`, `UIKit`/`SwiftUI`, `os.log` ja `Combine`. Nopeat polut tehdään sovelluskerroksessa tai `#if canImport(simd)` -haarassa.
**Miksi:** ilman Macia ainoa nopea kehityssilmukka on Windowsilla. Brief vaatii kalibroinnin ja liikeohjeen puhtaina, synteettisesti testattavina malleina. Lisäksi `teleskooppi-cli` voi ajaa nauhoitteita Windowsilla pilvisinä iltoina.
**Hinta:** ei SIMD-kiihdytystä ytimessä. Tunnistus binnatulle 960×720-kuvalle on silti CPU:lla riittävän nopea (varmistetaan vaiheessa 4).

### D-04 · Renderöinti: AVCaptureVideoDataOutput + Metal (ei AVCaptureVideoPreviewLayer) · 2026-09-29 · VOIMASSA
**Miksi:** näytön muunnos (mielivaltainen kierto, flip, ristikon keskitys, skaalaus), punatila, venytys ja myöhemmin EAA-pinoaminen tehdään samassa paikassa. Preview layer tukee vain 90°:n kiertoja eikä pikselikäsittelyä. Kehykset tarvitaan joka tapauksessa tunnistukseen. `CVMetalTextureCache` antaa puskurin tekstuurina ilman kopiota.
**Hinta:** enemmän koodia, ja viive riippuu omasta putkesta. Mitataan vaiheessa 2.
**Vaihe 0:** preview layeria saa käyttää väliaikaisesti ”hello camera” -testissä.

### D-05 · Kamerapuskuri natiivissa asennossa, kaikki kierrot shaderissa · 2026-09-29 · VOIMASSA
Yhteyden `videoRotationAngle` jätetään sensorin natiiviasentoon. Kalibrointi, tunnistus ja nauhoitteet käyttävät samaa kuvakoordinaatistoa; näyttömuunnos on yksi 3×3-matriisi.
**Miksi:** yksi koordinaatisto kaikelle, ei laitteen asennosta riippuvia kiertoja, ja nauhoite on toistettavissa täsmälleen.

### D-06 · Kalibrointi kahdella liikkeellä, pikakalibrointi yhdellä · 2026-09-29 · VOIMASSA
Oletus on tatti YLÖS + tatti OIKEALLE. Pikakalibrointi (vain YLÖS) on sallittu, kun profiilissa on täysi kalibrointi ja vain kiertokulma on muuttunut.
**Miksi:** yksi liike ei havaitse toisen akselin kääntöä (SynScanin asetus tai ohjaimen mappaus) eikä anna laatumittaria (kohtisuoruus). Toinen liike maksaa noin 5 s.

### D-07 · Liikkeen suunta sovitetusta suorasta, liikkeen alku kuvasta · 2026-09-29 · VOIMASSA
Siirtymävektoria ei lasketa ”paikka ennen – paikka jälkeen” -erotuksena. Liikkeen alku tunnistetaan kynnyksellä (ajelehtimiskorjattuna), ja suunta saadaan liikeradan pisteisiin sovitetusta suorasta (TLS).
**Miksi:** välys, kiihdytys ja jarrutus eivät vääristä suuntaa, eikä esiliikettä tarvita. Sama menetelmä antaa sovitusjäännöksen laatumittariksi.

### D-08 · Näytölle ortogonaalinen muunnos (Procrustes), ohjeeseen täysi matriisi · 2026-09-29 · VOIMASSA
Näyttömuunnos on kierto θ + valinnainen flip. Matriisin epäkohtisuoruutta ei vääristetä kuvaan. Liikeohje käyttää täyttä matriisia `M⁻¹`.
**Miksi:** vääristetty kuva olisi harhaanjohtava. Ohjeen tarkkuus ei silti kärsi, koska `M⁻¹` huomioi mittausten todellisen geometrian (myös cos ALT -skaalan).

### D-09 · Ohjauskonventio ”ikkuna”, käännettävissä · 2026-09-29 · VOIMASSA
Tähti ristikon vasemmalla → nuoli vasemmalle → tatti vasemmalle. Asetus ”käänteinen” kääntää nuolen.
**Miksi:** briefin konventio. Kalibroinnin jälkeen ruutu ja tatti liikkuvat samaan suuntaan. Kokemus kaukoputkella voi silti yllättää, joten kääntö on yksi valinta. Vahvistetaan vaiheen 5 kenttätestissä.

### D-10 · Overlay SwiftUI:lla, kuva Metalilla, yhteinen muunnosmatriisi · 2026-09-29 · VOIMASSA
**Miksi:** ristikko, nuolet ja tekstit on nopeampi ja saavutettavampi tehdä SwiftUI:lla. Sama `DisplayTransform` takaa, että overlay ja kuva täsmäävät. Uudelleenarvioidaan, jos overlay-viive näkyy (esim. tähden merkki laahaa kuvan perässä).

### D-11 · Nauhoiteformaatti: binnattu Y-taso raakana + JSON-metatiedot + tapahtumaloki · 2026-09-29 · VOIMASSA
Hakemisto `session-YYYYMMDD-HHMMSS.tcs/` sisältää:
- `meta.json` (laite, formaatti, profiili, kalibrointi)
- `frames.bin` (jokaiselle kehykselle otsake: aikaleima, valotus, ISO, linssi, w, h, stride; perässä 8-bittinen luma, oletuksena 2×-binnattu 960×720)
- `events.jsonl` (UI- ja kalibrointitapahtumat, tunnistukset)

Nopeus on säädettävä (oletus 10 fps, noin 7 Mt/s). Täysresoluutio on valinnainen.
**Miksi:** häviötön, jolloin himmeät tähdet säilyvät (HEVC tuhoaisi ne). Luettavissa ytimestä Windowsilla ilman riippuvuuksia. Kalibrointi käyttää vain lumaa. Myöhemmin EAA:ta varten lisätään RAW/10-bit-variantti.
**Hylätyt:** HEVC (häviöllinen), PNG-sekvenssi (pakkaus vaatisi riippuvuuden Windowsilla ja olisi hidas puhelimessa), zlib (kohinainen kuva pakkautuu huonosti, lisäarvo pieni).

### D-12 · Koko kuvan siirtymäestimaattori MVP:hen · 2026-09-29 · VOIMASSA
`ShiftEstimator` (binnattu, normalisoitu ristikorrelaatio, karkeasta tarkkaan, alipikselitarkennus) tuottaa `TrackSample`-näytteitä samaan rajapintaan kuin tähden seuranta.
**Miksi:** kalibroinnin voi testata päivällä ilman tähteä (brief), ja komponenttia käytetään myöhemmin EAA-kohdistukseen ja vanhentumisen tunnistukseen.

### D-13 · Käyttöliittymän suunta lukittu · 2026-09-29 · VOIMASSA
Sovellus on lukittu yhteen asentoon (oletus pysty, profiilikohtainen asetus pysty/vaaka).
**Miksi:** puhelimen asento okulaarissa on mielivaltainen. Automaattinen kääntö muuttaisi UI:n sen mukaan, eikä ”ruutu ylös” olisi vakio.

### D-14 · Videoformaatti 4:3 (esim. 1920×1440), fyysinen laajakulmakamera · 2026-09-29 · VOIMASSA (🔬 formaatti vahvistetaan vaiheessa 0)
`builtInWideAngleCamera`, ei virtuaalista monikameraa. 4:3-formaatti, koska okulaarin ympyrä (≈ 52°) on korkeampi kuin 16:9-kuvan pystykenttä (≈ 43°). 4:3:ssa (≈ 50°) ympyrä mahtuu lähes kokonaan.
**Miksi:** optinen keskipiste ja kenttäraja tunnistetaan helpommin, eikä kuvaa hukata.

### D-15 · Kielet: koodi englanniksi, UI ja dokumentaatio suomeksi · 2026-09-29 · VOIMASSA
UI-tekstit ovat String Catalogissa, joten kieliä voi lisätä myöhemmin.

### D-16 · Minimi iOS 26, vain iPhone · 2026-09-29 · VOIMASSA
Ainoa kohdelaite on iPhone 17. Uusimmat API:t ovat käytettävissä ilman yhteensopivuuskerroksia. `TARGETED_DEVICE_FAMILY = 1`. iPad tulee mukaan vain suoratoiston vastaanottimena, erillisenä kohteena myöhemmin.

### D-17 · Optinen keskipiste: napautus varmana perustana, automaattinen ympyräntunnistus lisänä · 2026-09-29 · VOIMASSA
Ristikko siirretään näytön keskelle (kierto optisen keskipisteen ympäri).
**Miksi:** yöllä kaupunkitaivaalla kenttäraja ei aina erotu. Napautus toimii aina; automaattinen tunnistus (ympyräsovitus näkyviin kaarenosiin, RANSAC) toimii päivällä ja kirkkaalla taustalla.

### D-18 · Fyysiset napit: AVCaptureEventInteraction · 2026-09-29 · VOIMASSA (🔬)
Äänenvoimakkuusnapit ja Bluetooth-kameralaukaisin (esittäytyy äänenvoimakkuusnappina) ohjaavat toimintoja ”Kalibroi / seuraava / STOP-kuittaus”.
**Miksi:** hanskat, eikä putkeen tai puhelimeen tarvitse koskea kalibroinnin aikana.

### D-19 · Aurinkomuistutus MVP:ssä, ohjelmallinen esto jalustaohjauksen mukana · 2026-09-29 · VOIMASSA
MVP näyttää auringon atsimuutin ja korkeuden kiinteillä Helsingin koordinaateilla (ei sijaintilupaa). Jalustaohjauksessa on 30°:n kieltoalue, ja se toteutetaan ennen ensimmäistä liikekomentoa.
**Miksi:** näkymä on luoteeseen, ja syys-lokakuun iltapäivinä aurinko on lännessä, lähellä näkymän reunaa.

### D-20 · Jalustayhteys: ensin vain luku, liike vasta turvamekanismien jälkeen · 2026-09-29 · VOIMASSA
Järjestys: (1) asennon luku UDP 11880:sta tai toisen puhelimen SynScanin Stellarium-/sarjaprotokollasta, (2) aurinkokieltoalue ja kuolleen miehen kytkin (syke → automaattinen `:K`), (3) liikekomennot, (4) Xbox-ohjain kamerapuhelimeen.
**Miksi:** SynScan-manuaalin mukaan useampi asiakas saa lukea, mutta vain yksi saa liikuttaa. Speed-tilassa akseli liikkuu, kunnes se saa stop-komennon, joten kaatuminen tai WiFi-katko ilman sykettä jättäisi jalustan liikkeelle. SynScan ei estä käsiliikettä kohti aurinkoa.

### D-21 · Plate solving: vihjeellinen, 25 mm okulaarilla · 2026-09-29 · VOIMASSA (myöhempi vaihe)
Ensin nova.astrometry.net (online, vaatii jalustan station-tilan). Sitten oma vihjeellinen ratkaisija (Gaia/Tycho ≤ mag 12,5 HEALPix-laattoina, kymmeniä Mt; tetra3rs/olive-solve tai oma kolmiosovitin).
**Miksi:** jalusta tietää suunnan ±1–2°, joten sokean haun satojen Mt:n tietokannat ovat turhia. 10 mm:n kentässä (≈ 0,7°) on vain noin 10–30 tähteä kaupunkitaivaalla, joten ratkaisu tehdään 25 mm:llä ja suurennosten offsetit lasketaan.

### D-22 · EAA-järjestys: YUV-pinoaminen ensin, Bayer-RAW myöhemmin · 2026-09-29 · VOIMASSA (myöhempi vaihe)
v0: 8-bit YUV + globaali sävykartoitus, kohdistus translaatio + kierto. v1: laatupisteytys, darkit, 10-bit-vertailu. v2: 12 MP Bayer-RAW.
**Miksi:** v0 käyttää MVP:n komponentteja suoraan. Kenttärotaatio (Helsingissä ≈ 6–11°/h luoteessa) vaatii kierron kohdistuksen jo noin minuutin pinoissa. RAW on laadultaan paras (ei kohinanpoistoa), mutta hitaampi ja raskaampi, joten se tehdään vasta, kun hyöty on osoitettu.

### D-23 · Kalibrointinopeus: SynScan-taso 3–4 (25 mm), 2–3 (10 mm) · 2026-09-29 · VOIMASSA (🔬 vahvistetaan vaiheessa 5)
Tavoite on, että 25 %:n kenttäsiirtymä kestää 3–7 s: riittävästi näytteitä suoran sovitukseen, ja ajelehtimisen osuus jää alle 6 %. Oletustaso 5 (64×) on liian nopea.

### D-24 · Kalibroinnin tilakoneen tarkennukset (vaihe 1) · 2026-09-29 · VOIMASSA (🔬 tatin käyttäytyminen vahvistetaan vaiheessa 5)
Vaiheen 1 simulaatioajojen (1000 satunnaistapausta + 576 kulmaruudukon tapausta) perusteella luvun 4.3 tilakoneeseen tehtiin kolme tarkennusta:
1. **Varhainen STOP:** kun tähti on yli 0,75 R:n päässä keskipisteestä ja liikettä on vähintään 60 % tavoitteesta (15 % halkaisijasta), STOP annetaan heti eikä vasta 25 %:ssa. Ilman tätä noin 1 % tapauksista päätyi `nearEdge`-virheeseen, koska reaktioaika, jarrutus ja ajelehtiminen vievät tähden toisen liikkeen jälkeen 0,9–0,95 R:ään. Suunnan tarkkuus ei kärsi (sentroidivirhe on pieni 110 px:n liikkeelläkin).
2. **Ajelehtiminen yhdistetään kaikista paikallaanolojaksoista** (alku, liikkeiden välissä, lopussa; yhteinen kulmakerroin), ja paikallaanoloa jatketaan ≥ 1 s:sta enintään 8 s:iin, kunnes yhdistetyn arvion keskivirhe on ≤ 0,25 px/s. Liikkeiden suunnat lasketaan vasta lopussa lopullisella arviolla. **Miksi:** 3 px:n värinällä yhden sekunnin arvio on ±3 px/s, mikä antaisi hitaalla AZ-liikkeellä (16×, korkeus 60° → 14 px/s) useiden asteiden virheen.
3. **Simuloitu tatti on oletuksena on/off akselia kohden:** alle noin 20°:n vino painallus ei vuoda toiselle akselille. **Havainto:** jos tatti onkin analoginen ja käyttäjä painaa molemmat liikkeet johdonmukaisesti samaan kiertosuuntaan vinossa, kiertokulma vääristyy saman verran eikä kohtisuoruus paljasta sitä (CLI-ajo: 12° vinous → 12° kulmavirhe, kohtisuoruus vain 3,8°). Vaiheessa 5 tarkistetaan, onko SynScanin tatti analoginen (luku 4.6, 🔬).

Lisäksi: `CalibrationSession` on arvotyyppi (`struct`, `Sendable`) eikä luvun 3.3 luonnoksen `final class`. `feed(_:at:)` ottaa ajan erikseen, jotta kadonneen tähden (`nil`) aikakatkaisu voidaan laskea.
**Avoin vaiheelle 5:** kun akselinopeudet eroavat (`|m_R| ≠ |m_U|`, cos ALT), nuoli osoittaa tatin painallussuunnan, joka ruudulla poikkeaa ristikko→tähti-suunnasta (tähti kulkee silti suoraan ristikkoon). Kenttätesti ratkaisee, näytetäänkö nuoli tattiavaruudessa vai ruudun suunnassa.
