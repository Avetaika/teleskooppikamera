# Teleskooppikamera

iPhone-sovellus kaukoputken okulaarikameraksi (Sky-Watcher Heritage 150P + Virtuoso GTi, afokaalinen kuvaus). Tavoite: ruutu kertoo aina, mihin suuntaan putkea liikutetaan.

- Suunnitelma: [plan.md](plan.md)
- Päätökset: [decisions.md](decisions.md)
- Alkuperäinen toimeksianto: [docs/brief.md](docs/brief.md)
- **Käyttäjän ohje (mitä teen seuraavaksi):** [docs/ohje.md](docs/ohje.md)
- Asennus iPhoneen: [docs/install.md](docs/install.md)

Rakenne: `Core/` on alustariippumaton Swift-paketti (testattavissa Windowsilla ja Linuxilla), `App/` on iOS-sovellus (käännetään GitHub Actionsissa).
