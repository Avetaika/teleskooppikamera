# Projektin alkuperäinen toimeksianto (tiivistelmä käyttäjän ohjeesta 2026-09-29)

Tämä on käyttäjän kirjoittama lähtöohje lähes sellaisenaan. Päätökset ja tarkennukset: `../plan.md` ja `../decisions.md`.

## 1. Tavoite
iPhone kaukoputken okulaarikamerana niin, että kohteen löytäminen, teleskoopin liikuttaminen ja keskittäminen on intuitiivista – ruutu kertoo aina, mihin suuntaan putkea liikutetaan. Ei AstroShader-klooni: ratkaistaan ensin tämä yksi ongelma erittäin hyvin; arkkitehtuuri sallii myöhemmin EAA:n, plate solvingin ja jalustan ohjauksen.

## 2. Laitteisto ja käyttöympäristö
- Kaukoputki: Sky-Watcher Heritage 150P, 150/750 mm Newton (f/5)
- Jalusta: Virtuoso GTi (alt-az, GoTo + Freedom Find)
- Adapteri: Celestron NexYZ, afokaalinen kuvaus
- Jalustan ohjaus: SynScan-appi toisella puhelimella + Xbox-ohjain (oletusmappaus, ei käännettyjä suuntia). Kamerapuhelin on vain kamera.
- Puhelin: **iPhone 17, iOS 26**
- Okulaarit: **25 mm, 10 mm, 9 mm, 6 mm + 2× Barlow**
- Kehitys: **Windows 11 -PC, ei Macia** → pilvikäännös (GitHub Actions macOS) + asennus Sideloadlyllä. Kehittäjätili: ei vielä päätetty (ilmainen Apple ID oletuksena).
- Havaintopaikka: kerrostaloparveke Helsingissä, kaupunkitaivas, rajattu näkymä luoteeseen
- Olosuhteet: pimeä, kylmä → hanskat, akun kesto, ei kirkkaita pintoja

## 3. Käyttäjän tekniset lähtöoletukset (arvioitu plan.md:n luvussa 1)
1. Newton ei peilaa kuvaa (kaksi heijastusta → kierto). Takakamera ei peilaa.
2. Kiertokulma on mielivaltainen.
3. Viitekehys on jalustan akselit (ALT/AZ), ei taivas. MVP lupaa ”ALT ylös”, ei ”pohjoinen ylös”.
4. Optinen keskipiste ≠ näytön keskipiste.
5. Kalibrointi kuten PHD2: kaksi liikettä → 2×2-matriisi.
6. Liike tulee moottoreista (SynScan-nopeustasot) → tasainen liike.
7. Ohjaimen suunta ≠ jalustan akseli välttämättä → mitataan.
8. Sovellus ei näe ohjainta eikä jalustaa MVP:ssä → liike päätellään kuvasta.

## 4. Konventiot
- Ohjeet tattisuuntina: `TATTI ←`, `TATTI ↖`.
- Ikkunametafora: tähti ristikon vasemmalla → tatti vasemmalle. Nuoli osoittaa ristikosta kohdetta kohti. Konventio käännettävissä yhdellä asetuksella.

## 5. MVP
Kamera + yökäyttöliittymä + kalibroitu liikeohje. Käsin säädettävä kierto/flip vain varana.
- 5.1 Livekuva: takakamera, pieni viive, `builtInWideAngleCamera`, näytön lukitus pois.
- 5.2 Näytön muunnos: mielivaltainen kierto + flipit, vain näyttöön; kalibrointi asettaa.
- 5.3 Ristikko optiseen keskipisteeseen (automaattinen ympyräntunnistus tai napautus).
- 5.4 Kirkkaimman tähden sentroidi.
- 5.5 Kalibrointi: tatti YLÖS → mittaus, tatti OIKEALLE → mittaus, matriisi, kierto, peilaus, laatumittari (kohtisuoruus), setup-profiili, ajelehtiminen, välys.
- 5.6 Liikeohje: iso himmeä punainen nuoli, himmenee toleranssin sisällä.
- 5.7 Yökäyttöliittymä: musta/punainen, isot kosketusalueet, punasävytys livekuvaan.
- 5.8 Kamerasäädöt: valotus, ISO, tarkennus, lukitukset, zoom, ”ääretön”.

## 6. Selvitettävät iOS-rajoitteet
maxExposureDuration videossa, ISO-alue, pakollinen kuvankäsittely, RAW, preview layer vs. Metal, lämpö/akku/kylmä, 7 päivän allekirjoitus.

## 7. Arkkitehtuuri
Swift, SwiftUI, AVFoundation, Metal. Kameraputki erillään UI:sta; prosessoriketju. Kalibrointi ja liikeohje puhtaina malleina (yksikkötestit synteettisillä tähdillä). Paikka `MountController`-rajapinnalle. **Tallennus ja toisto jo varhain** + synteettinen tähtikenttägeneraattori.

## 8. Myöhemmin
EAA (pinoaminen, derotaatio, venytys), automaattinen keskitys, plate solving (offline), Virtuoso GTi -ohjaus WiFin yli, Xbox-ohjain suoraan tähän sovellukseen (portaaton nopeus), taivaan mukainen näkymä (1: kuten paljain silmin – syntyy MVP:stä; 2: pohjoinen ylös – parallaktinen kulma), kompassi/zeniittinuoli.

## 8b. Ideakori (arvioi, älä toteuta)
Tarkennusapu (HFR/FWHM), äänikeskitys, okulaariprofiilit/renkaat, kuu- ja planeettatila / lucky imaging, kollimointiapu, suoratoisto iPadille, kalibroinnin vanhentumisen tunnistus, havaintopäiväkirja + Parvekekartta, valosaasteen gradientin poisto, dark frame -vähennys, jalustan WiFi katkaisee internetin, iOS Local Network -lupa.

## 9. Vaiheistus
Jokainen vaihe pieni ja päättyy testiin: mitä rakennetaan / testi ilman kaukoputkea / päivätesti (EI koskaan lähellekään aurinkoa) / yötesti / hyväksymiskriteeri.
