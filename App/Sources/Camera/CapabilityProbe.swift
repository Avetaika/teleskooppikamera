import AVFoundation
import CoreMedia
import UIKit

/// Device state that must be read on the main actor (UIKit).
struct DeviceContext: Sendable {
    var appSummary: String
    var hardwareModel: String
    var systemVersion: String
    var batteryLevel: Float
    var batteryState: String
    var lowPowerMode: Bool

    @MainActor
    static func current() -> DeviceContext {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let state: String = switch device.batteryState {
        case .unplugged: "unplugged"
        case .charging: "charging"
        case .full: "full"
        case .unknown: "unknown"
        @unknown default: "other(\(device.batteryState.rawValue))"
        }
        return DeviceContext(
            appSummary: AppInfo.summary,
            hardwareModel: AppInfo.hardwareModel,
            systemVersion: "\(device.systemName) \(device.systemVersion)",
            batteryLevel: device.batteryLevel,
            batteryState: state,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }
}

/// Gathers the measurements listed in docs/device-iphone17.md ("Mittauskoodi").
enum CapabilityProbe {
    typealias Section = CapabilityReport.Section

    static func run(camera: CameraService, context: DeviceContext) async -> CapabilityReport {
        let log = AppLog.report
        var report = CapabilityReport(createdAt: .now)
        report.sections.append(contextSection(context))
        do {
            let sections = try await camera.withConfiguredDevice { session, device, photo in
                [
                    Self.deviceSection(device),
                    Self.formatSection("Active format", device.activeFormat),
                    Self.sessionSection(session),
                    Self.photoSection("Photo output (preview format)", photo),
                    Self.discoverySection(),
                    Self.allFormatsSection(device),
                ]
            }
            report.sections += sections
            report.sections += await longExposureTest(camera: camera)
        } catch {
            log.error("Capability probe failed: \(error.localizedDescription)")
            report.sections.append(Section("Camera error", lines: [error.localizedDescription]))
        }
        report.sections.append(stateSection("State at end"))
        return report
    }

    // MARK: - Sections

    static func contextSection(_ context: DeviceContext) -> Section {
        var s = Section("App and device")
        s.add("app", context.appSummary)
        s.add("hardware", context.hardwareModel)
        s.add("system", context.systemVersion)
        s.add("batteryLevel", context.batteryLevel)
        s.add("batteryState", context.batteryState)
        s.add("lowPowerMode", context.lowPowerMode)
        s.add("thermalState", CaptureFormatting.thermalState(ProcessInfo.processInfo.thermalState))
        return s
    }

    static func stateSection(_ title: String) -> Section {
        var s = Section(title)
        s.add("thermalState", CaptureFormatting.thermalState(ProcessInfo.processInfo.thermalState))
        return s
    }

    static func deviceSection(_ device: AVCaptureDevice) -> Section {
        var s = Section("Device")
        s.add("localizedName", device.localizedName)
        s.add("deviceType", device.deviceType.rawValue)
        s.add("modelID", device.modelID)
        s.add("uniqueID", device.uniqueID)
        s.add("lensAperture", device.lensAperture)
        s.add("formats.count", device.formats.count)
        s.add("isLockingFocusWithCustomLensPositionSupported", device.isLockingFocusWithCustomLensPositionSupported)
        s.add("lensPosition", device.lensPosition)
        s.add("minimumFocusDistance (mm)", device.minimumFocusDistance)
        s.add("focusMode supported locked/auto/continuous",
              "\(device.isFocusModeSupported(.locked))/\(device.isFocusModeSupported(.autoFocus))/\(device.isFocusModeSupported(.continuousAutoFocus))")
        s.add("exposureMode supported custom/locked/continuous",
              "\(device.isExposureModeSupported(.custom))/\(device.isExposureModeSupported(.locked))/\(device.isExposureModeSupported(.continuousAutoExposure))")
        s.add("exposureDuration (now)", CaptureFormatting.seconds(device.exposureDuration.seconds))
        s.add("iso (now)", device.iso)
        s.add("activeVideoMinFrameDuration", CaptureFormatting.seconds(device.activeVideoMinFrameDuration.seconds))
        s.add("activeVideoMaxFrameDuration", CaptureFormatting.seconds(device.activeVideoMaxFrameDuration.seconds))
        s.add("isGlobalToneMappingEnabled", device.isGlobalToneMappingEnabled)
        s.add("activeColorSpace", CaptureFormatting.colorSpaceName(device.activeColorSpace.rawValue))
        s.add("isVideoHDREnabled", device.isVideoHDREnabled)
        s.add("videoZoomFactor", device.videoZoomFactor)
        s.add("min/maxAvailableVideoZoomFactor", "\(device.minAvailableVideoZoomFactor)/\(device.maxAvailableVideoZoomFactor)")
        s.add("isLowLightBoostSupported", device.isLowLightBoostSupported)
        s.add("systemPressureState.level", device.systemPressureState.level.rawValue)
        s.add("systemPressureState.factors", device.systemPressureState.factors.rawValue)
        return s
    }

    static func formatSection(_ title: String, _ format: AVCaptureDevice.Format) -> Section {
        var s = Section(title)
        s.note(format.description)
        s.lines += formatDetails(format)
        return s
    }

    static func formatDetails(_ f: AVCaptureDevice.Format) -> [String] {
        let d = CameraService.dimensions(of: f)
        var s = Section("")
        s.add("dimensions", CaptureFormatting.dimensions(width: d.width, height: d.height))
        s.add("pixelFormat", CaptureFormatting.fourCC(CameraService.subtype(of: f)))
        s.add("frameRateRanges", f.videoSupportedFrameRateRanges
            .map { CaptureFormatting.fpsRange(min: $0.minFrameRate, max: $0.maxFrameRate) }
            .joined(separator: ", "))
        s.add("exposure min/max", "\(CaptureFormatting.seconds(f.minExposureDuration.seconds)) / \(CaptureFormatting.seconds(f.maxExposureDuration.seconds))")
        s.add("ISO min/max", "\(f.minISO) / \(f.maxISO)")
        s.add("isGlobalToneMappingSupported", f.isGlobalToneMappingSupported)
        s.add("isVideoHDRSupported", f.isVideoHDRSupported)
        s.add("supportedColorSpaces", f.supportedColorSpaces.map { CaptureFormatting.colorSpaceName($0.rawValue) }.joined(separator: ", "))
        s.add("videoMaxZoomFactor", f.videoMaxZoomFactor)
        s.add("secondaryNativeResolutionZoomFactors", f.secondaryNativeResolutionZoomFactors.map { "\($0)" }.joined(separator: ", "))
        s.add("supportedMaxPhotoDimensions", f.supportedMaxPhotoDimensions
            .map { CaptureFormatting.dimensions(width: $0.width, height: $0.height) }
            .joined(separator: ", "))
        s.add("videoFieldOfView", f.videoFieldOfView)
        s.add("isVideoBinned", f.isVideoBinned)
        s.add("isHighPhotoQualitySupported", f.isHighPhotoQualitySupported)
        s.add("autoFocusSystem", f.autoFocusSystem.rawValue)
        return s.lines
    }

    static func sessionSection(_ session: AVCaptureSession) -> Section {
        var s = Section("Session")
        s.add("sessionPreset", session.sessionPreset.rawValue)
        s.add("isRunning", session.isRunning)
        s.add("supportsControls", session.supportsControls)
        s.add("maxControlsCount", session.maxControlsCount)
        s.add("inputs/outputs", "\(session.inputs.count)/\(session.outputs.count)")
        return s
    }

    static func photoSection(_ title: String, _ photo: AVCapturePhotoOutput) -> Section {
        var s = Section(title)
        let raw = photo.availableRawPhotoPixelFormatTypes.map { code -> String in
            var kind: [String] = []
            if AVCapturePhotoOutput.isBayerRAWPixelFormat(code) { kind.append("Bayer") }
            if AVCapturePhotoOutput.isAppleProRAWPixelFormat(code) { kind.append("ProRAW") }
            return "\(CaptureFormatting.fourCC(code)) (\(kind.joined(separator: "+")))"
        }
        s.add("availableRawPhotoPixelFormatTypes", raw.isEmpty ? "none" : raw.joined(separator: ", "))
        s.add("availableRawPhotoFileTypes", photo.availableRawPhotoFileTypes.map(\.rawValue).joined(separator: ", "))
        s.add("isAppleProRAWSupported", photo.isAppleProRAWSupported)
        s.add("availablePhotoPixelFormatTypes", photo.availablePhotoPixelFormatTypes.map { CaptureFormatting.fourCC($0) }.joined(separator: ", "))
        s.add("availablePhotoCodecTypes", photo.availablePhotoCodecTypes.map(\.rawValue).joined(separator: ", "))
        s.add("maxBracketedCapturePhotoCount", photo.maxBracketedCapturePhotoCount)
        s.add("isLensStabilizationDuringBracketedCaptureSupported", photo.isLensStabilizationDuringBracketedCaptureSupported)
        s.add("maxPhotoQualityPrioritization", photo.maxPhotoQualityPrioritization.rawValue)
        s.add("maxPhotoDimensions", CaptureFormatting.dimensions(width: photo.maxPhotoDimensions.width, height: photo.maxPhotoDimensions.height))
        s.add("isZeroShutterLagSupported", photo.isZeroShutterLagSupported)
        s.add("isResponsiveCaptureSupported", photo.isResponsiveCaptureSupported)
        return s
    }

    static func discoverySection() -> Section {
        var s = Section("All cameras (DiscoverySession)")
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera,
                .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera,
                .builtInTrueDepthCamera, .builtInLiDARDepthCamera,
            ],
            mediaType: .video,
            position: .unspecified
        )
        for device in discovery.devices {
            s.note("\(device.deviceType.rawValue) position=\(device.position.rawValue) \(device.localizedName)")
        }
        return s
    }

    static func allFormatsSection(_ device: AVCaptureDevice) -> Section {
        var s = Section("All formats (\(device.formats.count))")
        for (index, format) in device.formats.enumerated() {
            s.note("[\(index)] \(CameraService.summary(of: format))")
            s.note("    \(format.description)")
            for line in formatDetails(format) {
                s.note("    " + line)
            }
        }
        return s
    }

    // MARK: - Long exposure test

    private struct LongExposureSetup: Sendable {
        var section: Section
        var applied: Bool
        var originalFormatIndex: Int?
    }

    /// Selects a 4:3 format with min frame rate ≤ 1 fps, sets a 1 s max frame duration and a
    /// 1 s custom exposure, waits, and records what the device actually reports.
    static func longExposureTest(camera: CameraService) async -> [Section] {
        let log = AppLog.report
        let setup: LongExposureSetup
        do {
            setup = try await camera.withConfiguredDevice { _, device, _ in Self.beginLongExposure(device) }
        } catch {
            return [Section("Long exposure test", lines: ["failed: \(error.localizedDescription)"])]
        }
        guard setup.applied else { return [setup.section] }

        // Frames at 1 s exposure: allow a few frames for the change to take effect.
        try? await Task.sleep(for: .seconds(4))

        let result = try? await camera.withConfiguredDevice { session, device, photo in
            var s = Section("Long exposure test: result after 4 s")
            s.add("activeFormat", CameraService.summary(of: device.activeFormat))
            s.add("sessionPreset", session.sessionPreset.rawValue)
            s.add("activeVideoMinFrameDuration", CaptureFormatting.seconds(device.activeVideoMinFrameDuration.seconds))
            s.add("activeVideoMaxFrameDuration", CaptureFormatting.seconds(device.activeVideoMaxFrameDuration.seconds))
            s.add("exposureMode", device.exposureMode.rawValue)
            s.add("exposureDuration", CaptureFormatting.seconds(device.exposureDuration.seconds))
            s.add("iso", device.iso)
            s.add("isAdjustingExposure", device.isAdjustingExposure)
            s.add("lensPosition", device.lensPosition)
            let rawSection = Self.photoSection("Photo output (long-exposure format)", photo)
            s.lines += Self.restore(device, originalFormatIndex: setup.originalFormatIndex)
            return [s, rawSection]
        }
        let sections = [setup.section] + (result ?? [])
        if let summary = result?.first {
            log.notice("Long exposure test: " + summary.lines.prefix(6).joined(separator: "; "))
        }
        return sections
    }

    private static func beginLongExposure(_ device: AVCaptureDevice) -> LongExposureSetup {
        var s = Section("Long exposure test: setup (4:3, min ≤ 1 fps, 1 s exposure)")
        let originalIndex = device.formats.firstIndex(of: device.activeFormat)
        guard let format = CameraService.longExposureFormat(device.formats) else {
            s.note("No 4:3 420f format with min frame rate ≤ 1 fps found")
            return LongExposureSetup(section: s, applied: false, originalFormatIndex: originalIndex)
        }
        s.add("chosen format", CameraService.summary(of: format))
        guard device.isExposureModeSupported(.custom) else {
            s.note("Custom exposure mode not supported")
            return LongExposureSetup(section: s, applied: false, originalFormatIndex: originalIndex)
        }

        let oneSecond = CMTime(value: 1, timescale: 1)
        // A frame duration of exactly 1 s must lie inside one of the supported ranges,
        // otherwise AVFoundation raises an exception.
        let frameRangeOK = format.videoSupportedFrameRateRanges.contains {
            $0.minFrameDuration.seconds <= 1.0 && $0.maxFrameDuration.seconds >= 1.0
        }
        let maxExposure = format.maxExposureDuration
        let exposure = maxExposure.seconds < 1.0 ? maxExposure : oneSecond

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = format
            if frameRangeOK {
                device.activeVideoMaxFrameDuration = oneSecond
            } else {
                s.note("No frame rate range contains 1 s; activeVideoMaxFrameDuration left at default")
            }
            device.setExposureModeCustom(duration: exposure, iso: AVCaptureDevice.currentISO, completionHandler: nil)
        } catch {
            s.note("lockForConfiguration failed: \(error.localizedDescription)")
            return LongExposureSetup(section: s, applied: false, originalFormatIndex: originalIndex)
        }
        s.add("requested activeVideoMaxFrameDuration", frameRangeOK ? "1 s" : "unchanged")
        s.add("requested exposureDuration", CaptureFormatting.seconds(exposure.seconds))
        s.add("format exposure min/max", "\(CaptureFormatting.seconds(format.minExposureDuration.seconds)) / \(CaptureFormatting.seconds(maxExposure.seconds))")
        s.add("immediately: activeVideoMin/MaxFrameDuration",
              "\(CaptureFormatting.seconds(device.activeVideoMinFrameDuration.seconds)) / \(CaptureFormatting.seconds(device.activeVideoMaxFrameDuration.seconds))")
        return LongExposureSetup(section: s, applied: true, originalFormatIndex: originalIndex)
    }

    /// Returns the camera to auto exposure and the original (preview) format.
    private static func restore(_ device: AVCaptureDevice, originalFormatIndex: Int?) -> [String] {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if let index = originalFormatIndex, device.formats.indices.contains(index) {
                device.activeFormat = device.formats[index]
            }
            device.activeVideoMinFrameDuration = .invalid
            device.activeVideoMaxFrameDuration = .invalid
            return ["restored: \(CameraService.summary(of: device.activeFormat)), auto exposure"]
        } catch {
            return ["restore failed: \(error.localizedDescription)"]
        }
    }
}
