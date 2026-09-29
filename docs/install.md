# Asennus iPhoneen Windowsista (ilman Macia)

Sovellus käännetään GitHub Actionsissa (`ios-build`), joka tuottaa **allekirjoittamattoman** `.ipa`-tiedoston. Se allekirjoitetaan omalla ilmaisella Apple ID:llä ja asennetaan **Sideloadlyllä** USB:n kautta (D-02, plan.md luku 6).

> **Tee asennus ja uusinta päivällä, älä havaintoiltana.** Asennus ja kehittäjäprofiilin luottaminen vaativat yhteyden Applen varmennuspalvelimeen. Jos palvelin on alhaalla (kuten 3/2026), asennus ei onnistu, ja vanhentunut sovellus ei aukea ennen kuin uusinta onnistuu.

Ensimmäinen kerta vie noin 30–45 min. Myöhemmät päivitykset noin 5 min.

---

## 1. Kertaluonteinen valmistelu PC:llä

1. **Poista Microsoft Storen Apple-sovellukset**, jos ne on asennettu: *Apple Devices*, *iTunes* (Store-versio) ja *iCloud* (Store-versio). Asetukset → Sovellukset → Asennetut sovellukset. Store-versiot ja Apple Devices ovat ristiriidassa Sideloadlyn kanssa.
2. **Asenna iTunes ja iCloud web-asennusversioina** (ei Storesta):
   - iTunes 64-bit: <https://www.apple.com/itunes/download/win64>
   - iCloud: käytä Sideloadlyn etusivun (<https://sideloadly.io>) linkkiä iCloudin web-asennusversioon.
   - Käynnistä PC uudelleen.
3. **Yhdistä iPhone USB-kaapelilla** ja avaa iTunes. Puhelimessa: *Luota tähän tietokoneeseen* → anna pääsykoodi. iTunesin vasempaan yläkulmaan ilmestyy puhelimen kuvake.
4. **Asenna Sideloadly**: <https://sideloadly.io> → Windows (64-bit).
5. **Käytä toissijaista Apple ID:tä.** Sideloadly kysyy Apple ID:n salasanan, joten älä käytä päätunnusta. Luo tarvittaessa uusi tunnus: <https://account.apple.com>. Kaksivaiheinen tunnistus on sallittu; koodi kysytään asennuksen yhteydessä.

## 2. Lataa IPA

Tarkista ensin, että uusin `ios-build`-ajo on vihreä: <https://github.com/Avetaika/teleskooppikamera/actions/workflows/ios-build.yml>.

**Vaihtoehto A, selain** (vaatii GitHubiin kirjautumisen):
1. Avaa uusin vihreä `ios-build`-ajo `main`-haarasta.
2. Kohdasta *Artifacts* → **ipa** → lataa zip.
3. Pura zip. Sisällä on `Teleskooppikamera-unsigned.ipa`.

**Vaihtoehto B, komentorivi (`gh`)**, PowerShellissä:

```powershell
$repo = "Avetaika/teleskooppikamera"
$id = gh run list --repo $repo --workflow ios-build --branch main --status success --limit 1 --json databaseId --jq '.[0].databaseId'
gh run download $id --repo $repo --name ipa --dir "$HOME\Downloads\teleskooppi-$id"
```

Artefaktit säilyvät 30 päivää. Sovelluksen näytöllä näkyvä *build*-numero on ajon numero (`#N` Actions-sivulla).

## 3. Asenna Sideloadlyllä

1. iPhone USB:llä kiinni ja lukitus auki.
2. Käynnistä Sideloadly.
   - *iDevice*: valitse puhelin.
   - *Apple Account*: toissijainen Apple ID.
   - Vedä `Teleskooppikamera-unsigned.ipa` IPA-kuvakkeen päälle.
3. Paina **Start**. Anna Apple ID:n salasana ja tarvittaessa kaksivaiheisen tunnistuksen koodi. Odota, kunnes loki näyttää *Done*.
4. **Kehittäjätila (vain ensimmäisellä kerralla):** puhelimessa Asetukset → Tietosuoja ja turvallisuus → **Kehittäjätila** → päälle → Käynnistä uudelleen. Käynnistyksen jälkeen vahvista *Ota käyttöön* ja anna pääsykoodi. (Valinta ilmestyy näkyviin vasta, kun ensimmäinen sivuladattu sovellus on asennettu.)
5. **Luota kehittäjään (ensimmäisellä kerralla ja aina Apple ID:n vaihtuessa):** Asetukset → Yleiset → **VPN ja laitehallinta** → *Kehittäjäsovellus*: Apple ID:si → **Luota**. Vaatii verkkoyhteyden.
6. Avaa **Teleskooppi** kotinäytöltä ja salli kameran käyttö.

**Tarkista:** livekuva näkyy, ja ylälaidassa näkyy `app 0.1.0 (N) · core x.y.z`, jossa N on Actions-ajon numero.

### Päivitys uuteen versioon

Toista kohdat 2–3 (kehittäjätila ja luottaminen on jo tehty). Asennus saman sovelluksen päälle säilyttää `Documents`-kansion (raportit ja lokit), **kunhan bundle ID pysyy samana** (`fi.avetaika.teleskooppikamera`). Älä vaihda sitä Sideloadlyn lisäasetuksista ilman syytä.

## 4. Seitsemän päivän uusinta

Ilmaisen Apple ID:n allekirjoitus vanhenee **7 päivässä**. Sen jälkeen sovellus ei aukea.

- **Automaattinen uusinta:** Sideloadlyssä oikea klikkaus sovelluksen riviin → *Automatic refresh* (tai valitse asennuksessa *Advanced options* → *Enable automatic refresh*). Sideloadly Daemon uusii allekirjoituksen WiFin kautta, kun PC on päällä ja samassa verkossa. Ota iTunesista käyttöön: puhelimen kuvake → Yhteenveto → **Synkronoi tämän iPhonen kanssa Wi-Fin kautta**.
- **Käsin:** asenna sama IPA uudelleen (kohta 3) ennen kuin 7 päivää täyttyy.
- Tarkista vanhenemispäivä Sideloadlyn listasta **ennen havaintoiltaa** ja uusi tarvittaessa päivällä.

## 5. Ilmaisen tilin rajat

- Enintään **3 sivuladattua sovellusta** kerrallaan puhelimessa (kaikki työkalut yhteensä).
- Enintään **10 App ID:tä / 7 päivää**. Saman bundle ID:n uudelleenasennus ei kuluta uutta.
- Kamera, paikallisverkko ja Bonjour toimivat. iCloud ja push-ilmoitukset eivät.
- Maksullinen kehittäjätili (99 $/v) poistaisi 7 päivän rajan (TestFlight, 90 päivää, plan.md 6.1).

## 6. Raporttien ja lokien siirto PC:lle

Sovellus tallentaa tiedostot `Documents`-kansioonsa:
- `capability-YYYYMMDD-HHMMSS.txt`: kyvykkyysraportti (näkymä **Raportti** → *Luo raportti*)
- `app-log.txt` (ja `app-log.previous.txt`): sovelluksen loki (näkymä **Loki**)

Siirtotavat:
1. **Sovelluksen Jaa-painike** → esim. *Tallenna Tiedostoihin*, sähköposti tai OneDrive.
2. **Tiedostot-sovellus:** Selaa → *Omalla iPhonella* → **Teleskooppi** → paina tiedostoa pitkään → Jaa.
3. **iTunesin tiedostonjako (USB, ei verkkoa):** iTunes → puhelimen kuvake → **Tiedostonjako** → *Teleskooppi* → valitse tiedostot → *Tallenna…* (tai vedä työpöydälle).

Kopioi raportin arvot `docs/device-iphone17.md`:n *Mitattu*-sarakkeeseen, tai lisää koko raportti repoon `docs/`-kansioon ja pyydä Claudea täyttämään taulukko.

## 7. Vaiheen 0 hyväksyntätesti puhelimessa

1. Livekuva näkyy (4:3), näyttö ei sammu itsestään.
2. **Raportti** → *Luo raportti* (noin 10 s; kuva tummuu hetkeksi 1 s:n valotustestin aikana) → *Jaa* → siirrä PC:lle.
3. **Loki** → tarkista, että *App start* -rivi ja raportin rivit näkyvät → *Jaa*.
4. Pidä sovellus auki 10 minuuttia; se ei saa kaatua.
5. Päivätesti: puhelin NexYZ:ään 25 mm:n okulaarille. Kirjaa, mahtuuko okulaarin ympyrä 4:3-kuvaan.

## 8. Vianmääritys

| Oire | Ratkaisu |
|---|---|
| Sideloadly ei löydä puhelinta | USB-kaapeli ja *Luota tähän tietokoneeseen*. Varmista, että iTunes on **web-versio** ja näkee puhelimen. Poista *Apple Devices* -sovellus. Käynnistä PC ja puhelin uudelleen. |
| Sideloadly valittaa iTunesista tai iCloudista | Poista Store-versiot, asenna web-versiot (kohta 1), käynnistä uudelleen. |
| Kirjautuminen epäonnistuu | Tarkista salasana ja kaksivaiheisen tunnistuksen koodi. Kirjaudu kerran selaimella <https://account.apple.com> ja hyväksy mahdolliset uudet ehdot. |
| *Maximum number of apps for free development profiles* | Poista puhelimesta jokin muu sivuladattu sovellus (enintään 3). |
| *Maximum App ID limit reached* | 10 App ID:tä / 7 pv täynnä. Odota tai käytä samaa bundle ID:tä kuin aiemmin. |
| *An App ID with identifier … is not available* | Bundle ID on varattu toiselle tilille. Sideloadly → *Advanced options* → vaihda bundle ID (esim. lisää pääte). Käytä jatkossa aina samaa. |
| *Epäluotettava kehittäjä* sovellusta avattaessa | Kohta 3.5: VPN ja laitehallinta → Luota. |
| *Kehittäjätila vaaditaan* | Kohta 3.4. |
| Sovellus ei enää aukea (toimi aiemmin) | 7 päivän allekirjoitus vanhentui. Uusi (kohta 4). |
| Luottaminen tai asennus ei onnistu, vaikka kaikki on oikein | Applen varmennuspalvelin voi olla alhaalla: <https://www.apple.com/support/systemstatus/>. Yritä myöhemmin. |
| Musta kuva ja teksti ”Kameran käyttö on estetty” | Asetukset → Teleskooppi → Kamera päälle. |
| Sovellus kaatuu | Asetukset → Tietosuoja ja turvallisuus → Analyysi ja parannukset → Analyysidata → `Teleskooppikamera-…ips` → Jaa. Liitä myös `app-log.txt`. |
| Tarvitaan reaaliaikainen järjestelmäloki | `idevicesyslog` (libimobiledevice Windowsille), suodata alijärjestelmällä `fi.avetaika.teleskooppikamera`. |

## 9. Jos Sideloadly ei toimi: vaihtoehdot

Virhe `Guru Meditation … Login failed: 404` tulee Applen kirjautumispalvelusta. Kokeile ensin: iTunesista ulos ja takaisin sisään, sovelluskohtainen salasana toissijaiselle Apple ID:lle, virustorjunnan tauko, Sideloadlyn päivitys, iTunes ja iCloud Applen sivuilta. Jos mikään ei auta:

| Vaihtoehto | Hinta | Huomio |
|---|---|---|
| **AltStore Classic** (AltServer Windowsille) | ilmainen | Sama ilmainen Apple ID ja 7 päivän uusinta. Vaatii iTunes/iCloud Applen sivuilta. AltStore vie yhden kolmesta sovellusslotista. |
| **SideStore** | ilmainen | Uusii sovelluksen puhelimella ilman PC:tä (kun asennus on kerran tehty). Vaatii kertaluonteisen pariutuksen, ja iOS 27 -tuki kannattaa tarkistaa projektin sivulta. |
| **Maksullinen Apple Developer -tili + TestFlight** | 99 $/vuosi | CI allekirjoittaa ja lähettää käännöksen TestFlightiin. Asennus puhelimeen ilman PC:tä, käännökset kestävät 90 päivää. Pysyvin ratkaisu, mutta vaatii tilin luonnin selaimessa ja CI-työnkulun lisäyksen. |

Jos valitset maksullisen tilin, kerro, niin lisään TestFlight-työnkulun.
