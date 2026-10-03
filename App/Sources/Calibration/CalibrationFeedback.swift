import AVFoundation
import UIKit

/// Beep and haptic feedback for the calibration screens.
@MainActor
protocol CalibrationFeedbackProviding: AnyObject {
    func stopSignal()
    func success()
    func failure()
}

/// STOP: a short 880 Hz sine tone from `AVAudioEngine` plus a warning haptic.
@MainActor
final class DeviceCalibrationFeedback: CalibrationFeedbackProviding {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let haptics = UINotificationFeedbackGenerator()
    private var buffer: AVAudioPCMBuffer?
    private var isConfigured = false

    func stopSignal() {
        haptics.notificationOccurred(.warning)
        playTone()
    }

    func success() { haptics.notificationOccurred(.success) }

    func failure() { haptics.notificationOccurred(.error) }

    private func playTone() {
        configureIfNeeded()
        guard let buffer, isConfigured else { return }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        player.play()
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        let frames = AVAudioFrameCount(sampleRate * 0.35)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = pcm.floatChannelData?[0] else { return }
        pcm.frameLength = frames
        let total = Double(frames)
        for i in 0..<Int(frames) {
            let t = Double(i) / sampleRate
            // 15 ms attack and release avoid clicks.
            let edge = min(1, min(Double(i), total - Double(i)) / (sampleRate * 0.015))
            samples[i] = Float(0.6 * edge * sin(2 * Double.pi * 880 * t))
        }
        buffer = pcm
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        isConfigured = true
    }
}

/// Counting stand-in for tests.
@MainActor
final class SilentCalibrationFeedback: CalibrationFeedbackProviding {
    private(set) var stopCount = 0
    private(set) var successCount = 0
    private(set) var failureCount = 0
    func stopSignal() { stopCount += 1 }
    func success() { successCount += 1 }
    func failure() { failureCount += 1 }
}
