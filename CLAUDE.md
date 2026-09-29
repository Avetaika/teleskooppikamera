# Teleskooppikamera: ohjeet Claudelle ja aliagenteille

iPhone 17 -sovellus kaukoputken okulaarikameraksi (Heritage 150P + Virtuoso GTi, afokaalinen NexYZ). MVP: kalibroitu liikeohje ”mihin suuntaan tattia painetaan”.

**Lue ensin:** `plan.md` (arkkitehtuuri, matematiikka, vaiheet), `decisions.md` (päätökset D-nn), `docs/brief.md` (alkuperäinen toimeksianto).

## Ehdottomat säännöt
- **Ei Macia.** Kehitys tapahtuu Windows 11:llä. iOS-sovellus käännetään vain GitHub Actionsissa (`macos-26`, Xcode 26.6 kiinnitetty, iOS 26.0 -kohde). Älä oleta, että `xcodebuild`, simulaattori tai Xcode on paikallisesti käytettävissä.
- **`Core/` (TeleskooppiCore) importtaa vain `Foundation`in** (D-03). Ei `simd`-, `Accelerate`-, `AVFoundation`-, `Metal`-, `CoreGraphics`-, `UIKit`/`SwiftUI`-, `os.log`- eikä `Combine`-importteja. Ytimen pitää kääntyä ja testautua Windowsilla (`swift test --package-path Core`) ja Linuxilla.
- Kaikki kalibroinnin, tunnistuksen ja ohjauksen logiikka kuuluu ytimeen ja testataan synteettisellä datalla. Sovelluskerros (`App/`) on ohut: kamera, Metal, UI.
- Kuvakoordinaatit: kameran natiivi puskuriasento, u oikealle, v alas (D-05). Näyttömuunnos on yksi 3×3-matriisi (D-08, D-10).
- Swift 6, tiukka rinnakkaisuustarkistus. Koodi ja kommentit englanniksi, UI-tekstit suomeksi String Catalogissa (D-15).
- `.xcodeproj` generoidaan XcodeGenillä (`App/project.yml`); sitä ei versioida.
- Aurinkoturvallisuus: mikään koodi ei saa liikuttaa jalustaa ilman aurinkokieltoaluetta (D-19).

## Työskentely
- Jokainen vaihe (plan.md luku 10) päättyy testiin. Merkitse hyväksyntäkriteerin tila plan.md:hen, kun vaihe valmistuu.
- Uusi merkittävä valinta kirjataan `decisions.md`:hen (seuraava vapaa D-numero).
- Laitteelta mitatut arvot kirjataan `docs/device-iphone17.md`:hen.
- Nauhoitteet (`*.tcs`) eivät kuulu gittiin (`recordings/` on .gitignoressa). Pienet testikatkelmat → `Core/Tests/Fixtures/` (< 5 Mt).
