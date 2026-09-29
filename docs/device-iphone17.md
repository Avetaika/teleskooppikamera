# iPhone 17: kamerakyvykkyydet (mitattava laitteella)

Vaihe 0:n `CapabilityReport` tulostaa nämä ja tallentaa ne tiedostoon `Documents/capability-<päivä>.txt`. Tulokset kopioidaan tähän taulukkoon.

## Odotetut arvot vs. mitatut

| Ominaisuus | Odotettu | Luotettavuus | Mitattu |
|---|---|---|---|
| `builtInWideAngleCamera` | 48 MP, 26 mm ekv., ƒ/1,6, 1/1,56″ | V ([Apple](https://www.apple.com/iphone-17/specs/), [GSMArena](https://www.gsmarena.com/apple_iphone_17-review-2886p6.php)) | |
| `activeFormat.maxExposureDuration` | 1,0 s | T (iPhone XS/12/14 Pro, [forum 736453](https://developer.apple.com/forums/thread/736453), [751112](https://developer.apple.com/forums/thread/751112)) | |
| `videoSupportedFrameRateRanges` min | 1 fps | T | |
| `minISO` / `maxISO` | ~55 / ~12320 | T (iPhone 15 Pro) | |
| 4:3-videoformaatit (1920×1440, 4032×3024) | olemassa | 🔬 | |
| `isGlobalToneMappingSupported` | true | 🔬 | |
| `x420` (10-bit) -formaatit | olemassa | T | |
| `isAppleProRAWSupported` | false | T | |
| Bayer-RAW | 12 MP binnattu | T ([DPReview/Halide](https://www.dpreview.com/news/5101705770/halide-process-zero-ai-computational-photograpy-phones-raw/)) | |
| `maxBracketedCapturePhotoCount` | ? | 🔬 | |
| `lensPosition` äärettömässä | ~0,75–0,85, ryömii lämpötilan mukaan | T ([forum 706755](https://developer.apple.com/forums/thread/706755)) | 20 °C: ___ / ulkona ___ °C: ___ |
| `secondaryNativeResolutionZoomFactors` | [2.0] | T | |
| `session.supportsControls` / `maxControlsCount` | true / ? | T | |
| Lasista lasiin -viive (preview layer / Metal) | 50–100 ms @30 fps | T | |
| Akunkulutus (näyttö minimissä, 30 fps + Metal) | 15–25 %/h | T | |

## Mittauskoodi (luonnos vaiheeseen 0)

```swift
for f in dev.formats { log(f.description) }  // fps, ISO, SS, binned, x420
log(dev.activeFormat.minExposureDuration.seconds, dev.activeFormat.maxExposureDuration.seconds)
log(dev.activeFormat.minISO, dev.activeFormat.maxISO)
log(dev.activeFormat.videoSupportedFrameRateRanges.map { ($0.minFrameRate, $0.maxFrameRate) })
log(CMFormatDescriptionGetMediaSubType(dev.activeFormat.formatDescription))   // '420f' / 'x420'
log(dev.activeFormat.isGlobalToneMappingSupported, dev.activeFormat.isVideoHDRSupported)
log(dev.activeFormat.supportedColorSpaces.map(\.rawValue))
log(dev.activeFormat.secondaryNativeResolutionZoomFactors, dev.activeFormat.videoMaxZoomFactor)
log(dev.activeFormat.supportedMaxPhotoDimensions)
log(dev.activeVideoMinFrameDuration.seconds, dev.activeVideoMaxFrameDuration.seconds) // 1 s valotuksen asettamisen jälkeen
log(dev.isLockingFocusWithCustomLensPositionSupported, dev.lensPosition, dev.minimumFocusDistance)
log(photoOutput.availableRawPhotoPixelFormatTypes, photoOutput.isAppleProRAWSupported)
log(photoOutput.maxBracketedCapturePhotoCount, photoOutput.maxPhotoQualityPrioritization.rawValue)
log(session.supportsControls, session.maxControlsCount)
log(dev.systemPressureState.level.rawValue, ProcessInfo.processInfo.thermalState.rawValue)
log(UIDevice.current.batteryLevel)            // 60 s välein, isBatteryMonitoringEnabled = true
// kehyskohtaisesti: PTS, pudotuksen syy, EXIF (ExposureTime, ISO, FocalLength)
```

## Fyysiset testit
- **Viive:** kuvaa puhelimen näyttöä toisella laitteella millisekuntikellon vieressä. Mittaa sekä preview layer että Metal-putki.
- **Äärettömän `lensPosition`:** automaattitarkennus kaukaiseen kohteeseen. Kirjaa arvo sisällä (20 °C) ja ulkona kylmässä.
