# Ohje Henrille: mitä sinä teet ja milloin

Tämä on sinun tehtävälistasi. Tekninen asennus vaihe vaiheelta on erikseen: [install.md](install.md). Kokonaisuus on kuvattu [plan.md](../plan.md):ssä.

**Työnjako lyhyesti:** Claude ja apuagentit kirjoittavat koodin, ja GitHub kääntää sovelluksen pilvessä. Sinä asennat sovelluksen puhelimeen, testaat sitä kaukoputkella ja lähetät tulokset (raportit, lokit, nauhoitteet) takaisin.

---

## 1. Kertaluonteiset valmistelut (noin 1 h, päivällä)

- [ ] **Luo toissijainen Apple ID** (esim. uusi sähköpostiosoite). Sideloadly kysyy tunnuksen salasanaa, joten älä käytä päätunnustasi.
- [ ] **Asenna PC:lle iTunes, iCloud ja Sideloadly** ohjeen [install.md](install.md) kohdan 1 mukaan. Poista ensin Microsoft Storesta asennetut Apple Devices, iTunes ja iCloud.
- [ ] **Visual Studio Build Tools** (vapaaehtoinen, mahdollistaa testit omalla koneella). Aja PowerShellissä ja hyväksy Windowsin ylläpitäjäkysymys:
  ```
  winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override "--passive --wait --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.VC.Tools.ARM64"
  ```
- [ ] **Tarkista SynScanista** (Asetukset): nopeustasot ja se, että suuntien kääntöasetukset ovat oletuksissa. Kirjaa ylös, miltä tasolta putki liikkuu tatilla.

## 2. Sovelluksen asennus ja ensimmäinen testi (vaihe 0, päivällä)

1. Lataa uusin `ipa`: https://github.com/Avetaika/teleskooppikamera/actions → uusin vihreä **ios-build** → Artifacts → `ipa`.
2. Asenna Sideloadlyllä, ota **kehittäjätila** käyttöön ja luota profiiliin ([install.md](install.md) kohdat 3–4). Puhelimen pitää olla verkossa, kun avaat sovelluksen ensimmäistä kertaa.
3. Avaa **Teleskooppi** ja salli kamera. Livekuvan pitää näkyä, ja alareunassa lukee versio.
4. Paina **Raportti → Luo raportti** (noin 10 s).
5. Siirrä PC:lle tiedostot `capability-*.txt` ja `app-log.txt` (Tiedostot-sovellus → Omassa iPhonessa → Teleskooppi, tai iTunesin tiedostonjako). **Anna ne Claudelle**, esim. kopioimalla projektikansioon `recordings/`.
6. Pidä sovellus auki 10 minuuttia. Kaatuiko?

## 3. Päivätesti kaukoputkella

> ☀️ **Aurinkosäännöt, aina:**
> - Päivätestit **aamupäivällä**, kun aurinko on talon takana.
> - Osoita vain luoteeseen ja pohjoiseen, **ei länteen**. Syys-lokakuun iltapäivinä aurinko on lännessä, aivan näkymän reunassa.
> - Peitä putken suu aina, kun käännät putkea muualle kuin tiedossa olevaan kohteeseen. Älä käytä GoTo:ta päivällä ilman peitettä.
> - Aurinko rikkoo silmän ja puhelimen kennon sekunneissa.

Kohteeksi käy kaukainen masto, piippu tai rakennuksen kulma. Hämärässä mastojen **punaiset lentoestevalot** ovat erinomaisia ”keinotähtiä”.

Kiinnitä puhelin NexYZ:llä **25 mm okulaariin** ja kiristä fokusserin lukitusruuvi, jotta okulaari ei pääse kiertymään. Kirjaa:
- [ ] Mahtuuko okulaarin kirkas ympyrä kokonaan kuvaan? Leikkautuuko se ylhäältä tai alhaalta?
- [ ] **SynScanin tatti:** onko se analoginen (nopeus riippuu kallistuksesta) vai on/off? Liikkuuko putki vinottain, jos tattia painaa vinoon?
- [ ] Millä nopeustasolla kuva liikkuu 25 mm okulaarilla mukavasti noin neljänneksen kentästä 3–7 sekunnissa? Oletus on taso 3–4.

## 4. Yötestit

Kun sovellukseen tulee uusi vaihe (Claude kertoo), ota joka kirkkaana iltana:
- 25 mm okulaari ensin, 10 mm toisena.
- SynScanissa **seuranta päälle**.
- **Nauhoitus päälle** (vaiheesta 3 alkaen): 60 s kirkkaasta tähdestä niin, että ajat tatilla ylös, oikealle ja takaisin. Kirjaa muistiin käytetty nopeustaso. Näillä nauhoitteilla Claude kehittää sovellusta pilvisinä iltoina.
- **Kylmä:** varavirtalähde, puhelimelle eristys tai käsilämmitin. Älä lataa kylmää akkua.

Kunkin vaiheen tarkka testi ja hyväksymiskriteeri löytyvät [plan.md](../plan.md):n luvusta 10.

## 5. Ylläpito

- **Joka 7. päivä** allekirjoitus vanhenee. Sideloadlyn automaattinen uusinta hoitaa sen, kun PC on päällä samassa WiFissä. Muuten asenna uudelleen.
- **Uusi versio:** asenna uusin `ipa` samalla tavalla. Asetukset säilyvät.
- **Asennuksia ei kannata tehdä havaintoiltana**, koska Applen varmennuspalvelin voi olla tavoittamattomissa.

## 6. Mitä kannattaa kertoa Claudelle

- Raportit ja lokit (kohta 2).
- Päivätestin havainnot (kohta 3): varsinkin tatin tyyppi ja vinoliike, koska ne vaikuttavat liikeohjeen suunnitteluun.
- Nauhoitteet yötesteistä (sijainti ja nopeustaso).
- Kaikki, mikä tuntui kentällä kömpelöltä: hanskat, kirkkaus, nuolen suunta. Konvention voi kääntää, jos ”tatti kohti tähteä” tuntuu väärältä.

## 7. Tila nyt (2026-09-29)

| Vaihe | Tila |
|---|---|
| 0 Työkaluketju + kamerasovellus | ✅ pilvessä · ⏳ **odottaa asennustasi puhelimeen** |
| 1 Kalibroinnin matematiikka + simulaatio | ✅ valmis (59 testiä) |
| 2 Metal-livekuva, yötila, kamerasäädöt | ✅ pilvessä (CI vihreä) · ⏳ **odottaa puhelintestiäsi** (lista alla) |
| 3–4 Nauhoitus, tähden tunnistus (ydin) | 🔨 työn alla |
| 5 Kalibrointi ja liikeohje sovelluksessa | seuraavaksi |
| 6 Profiilit, viimeistely → MVP | sen jälkeen |

## 8. Vaihe 2 -testi puhelimella

Asenna uusin build (kohta 2). Puhelin voi ilmoittaa iOS 27.0, vaikka sovelluksen kohde on 26.0: se on ylöspäin yhteensopiva ja sen pitäisi toimia. Tee testi ensin päivällä huoneessa tai ikkunasta kaukaiseen kohteeseen, sitten pimeässä. Kirjaa havainnot (luvut ja ”tuntuu kömpelöltä”) ja lähetä ne.

- [ ] **Kamerakysely:** ensimmäisellä käynnistyksellä sovellus pyytää kameran lupaa. Salli. (Jos kielsit: sovelluksen pitää näyttää ohje ja nappi ”Avaa Asetukset”, ei kaatua.)
- [ ] **Livekuva ja viive:** kuva on sulava. Kehitysvalikko (⋯) → Suorituskyky → ”Näytä pääruudulla”: kamera ~30 fps, piirto ~30 fps, viive alle 100 ms (kirjaa luku). Heilauta kättä kameran edessä: tuntuuko viive?
- [ ] **Kierto-liukusäädin:** ”Kuva” → Kierto. Kuva pyörii sulavasti ilman sätkimistä; −1° / +1° / 0° / +90° toimivat; ”Peilaa vaaka/pysty” peilaa. Ruudun vasemmassa ylälaidassa lukee ”KÄSI x°”.
- [ ] **Ristikko ja keskipiste:** paina kuvaa sormella noin sekunnin: ristikko siirtyy kohtaan ja kuva keskittyy siihen. ”Keskitä kuva” palauttaa. Sulje ja avaa sovellus: asetus säilyy.
- [ ] **Punatila:** ”Kuva” → Punatila. Kaikki punaista ja mustaa, ei valkoista pilkkua (esim. lataus- tai tilarivi). Mustapiste, valkopiste ja gamma muuttavat kuvaa; ”Nollaa venytys” palauttaa.
- [ ] **Kirkkaus:** liu’uta näytön kirkkaus minimiin (pimeässä pitää olla miellyttävän himmeä). Paina kotinäppäintä / pyyhkäise sovellus taustalle: **järjestelmän kirkkauden pitää palautua**. Palaa sovellukseen: himmennys palaa. Ruutu ei sammu 3 minuutin jälkeen.
- [ ] **Vaakalukitus:** käännä puhelinta: käyttöliittymän ei pidä kääntyä.
- [ ] **Valotus 1 s:** ”Kamera” → Valotus → Käsi, valotusaika 1 s (tai esiasetus *Katselu*). Kuva päivittyy noin kerran sekunnissa, ei jäädy eikä sovellus kaadu; Nyt-rivillä lukee noin 1 s. Palaa lyhyeen valotukseen: fps palaa 30:een. Ne, jotka ovat epävarmoja rajoista: rajat näkyvät ”Rajat”-rivillä (kirjaa ne).
- [ ] **Valotuksen lukitus:** valitse Lukitse, sytytä ja sammuta lamppu: kirkkaus ei saa hakea.
- [ ] **Tarkennus ääretön:** ”Kamera” → Tarkennus. Osoita kaukaiseen kohteeseen (ikkunasta masto/horisontti) ja paina ”Kalibroi ääretön”; sen jälkeen ”Ääretön” palauttaa saman tarkkuuden. Kirjaa tallennettu linssin arvo (esim. 0.8xx).
- [ ] **Aurinkovaroitus:** päivällä statusrivillä pitäisi näkyä Auringon suunta ja korkeus; jos aurinko on horisontin yläpuolella lännessä tai pohjoisessa (az 200–360°), näkyy punainen varoitus ”AURINKO YLHÄÄLLÄ …”. Onko suunta oikein (vertaa kompassiin)?
- [ ] **Synteettinen tila:** Kehitysvalikko → Kuvalähde → Synteettinen. Tähtitaivas ilmestyy ja teksti ”SYNTEETTINEN” näkyy. Virtuaalitatti liikuttaa taivasta. Vaihda takaisin Kameraan: livekuva palaa.
- [ ] **Lämpö ja akku:** jätä livekuva päälle 30 min (mieluiten laturissa ja ilman): kehitysvalikon lämpötila pysyy ”nominal”/”fair”, ei kaatumisia. Kirjaa akun kulutus.
- [ ] **Napit:** onnistuuko niiden painaminen hanskat kädessä (napit ovat vähintään 64 pt)?

Mitatut arvot kirjataan tiedostoon `docs/device-iphone17.md`.
