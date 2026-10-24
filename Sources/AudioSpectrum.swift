import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// Уровни пяти частотных полос для эквалайзера. Обновляются ~30 раз в секунду.
final class SpectrumModel: ObservableObject {
    static let bandCount = 5

    @Published var levels = [Float](repeating: 0, count: SpectrumModel.bandCount)
    /// true, когда реально приходит звук; иначе эквалайзер рисует запасную анимацию.
    @Published var isLive = false
}

/// Снимает системный звук через Core Audio process tap (macOS 14.2+) и раскладывает его в спектр.
/// Нужно разрешение «Запись системного звука»; без него приходит тишина и включается запасная анимация.
final class AudioSpectrum {
    private let model: SpectrumModel
    private let queue = DispatchQueue(label: "island.spectrum", qos: .userInteractive)
    private let lock = NSLock()
    private var latest = [Float](repeating: 0, count: SpectrumModel.bandCount)
    private var sawSignal = false
    private var startedAt = Date()
    private var timer: Timer?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private let debugLog = ProcessInfo.processInfo.environment["ISLAND_SPECTRUM_LOG"] != nil

    // FFT
    private let size = 1024
    private let hop = 512
    private lazy var log2n = vDSP_Length(log2(Double(size)))
    private lazy var setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    private lazy var window: [Float] = {
        var w = [Float](repeating: 0, count: size)
        vDSP_hann_window(&w, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        return w
    }()
    private var ring: [Float]
    private var writeIndex = 0
    private var sinceLast = 0
    private var sampleRate: Double = 48000
    private var peaks = [Float](repeating: -90, count: SpectrumModel.bandCount)
    private var smoothed = [Float](repeating: 0, count: SpectrumModel.bandCount)
    private let edges: [Double] = [40, 160, 500, 1500, 4000, 12000]

    init(model: SpectrumModel) {
        self.model = model
        ring = [Float](repeating: 0, count: size)
    }

    func start() {
        guard !running else { return }
        guard #available(macOS 14.2, *), startTap() else {
            fputs("SPECTRUM tap unavailable\n", stderr)
            return
        }
        running = true
        startedAt = Date()
        sawSignal = false
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.publish()
        }
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        lock.lock()
        latest = [Float](repeating: 0, count: SpectrumModel.bandCount)
        lock.unlock()
        model.levels = latest
        model.isLive = false
    }

    private func publish() {
        lock.lock()
        let values = latest
        let live = sawSignal
        lock.unlock()
        model.levels = values
        if debugLog { fputs("SPECTRUM live=\(live) " + values.map { String(format: "%.2f", $0) }.joined(separator: " ") + "\n", stderr) }
        let waited = Date().timeIntervalSince(startedAt)
        // Первые секунды ждём первый звук (разрешение, запуск плеера), потом включаем запасной режим.
        let next = live || waited < 2.5
        if model.isLive != next { model.isLive = next }
    }

    @available(macOS 14.2, *)
    private func startTap() -> Bool {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Island spectrum"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return false }
        tapID = tap

        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &format) == noErr, format.mSampleRate > 0 {
            sampleRate = format.mSampleRate
        }

        guard let outputUID = Self.defaultOutputUID() else { return false }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Island spectrum",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID) == noErr else { return false }
        guard AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue, { [weak self] _, input, _, _, _ in
            self?.process(input)
        }) == noErr, let procID else { return false }
        return AudioDeviceStart(aggregateID, procID) == noErr
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private func process(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let buffer = list.first, let raw = buffer.mData else { return }
        let channels = max(1, Int(buffer.mNumberChannels))
        let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        let samples = raw.assumingMemoryBound(to: Float.self)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += samples[frame * channels + channel] }
            ring[writeIndex] = sum / Float(channels)
            writeIndex = (writeIndex + 1) % size
            sinceLast += 1
            if sinceLast >= hop {
                sinceLast = 0
                analyze()
            }
        }
    }

    private func analyze() {
        var ordered = [Float](repeating: 0, count: size)
        for i in 0..<size { ordered[i] = ring[(writeIndex + i) % size] }
        var windowed = [Float](repeating: 0, count: size)
        vDSP_vmul(ordered, 1, window, 1, &windowed, 1, vDSP_Length(size))

        let half = size / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup!, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        let binWidth = sampleRate / Double(size)
        var anySignal = false
        for band in 0..<SpectrumModel.bandCount {
            let low = max(1, Int(edges[band] / binWidth))
            let high = min(half - 1, max(low, Int(edges[band + 1] / binWidth)))
            var energy: Float = 0
            for bin in low...high { energy += magnitudes[bin] }
            energy /= Float(high - low + 1)
            // Амплитуда → дБ; нормировка по недавнему пику полосы, чтобы бары реагировали на ритм.
            let db = 10 * log10(energy / Float(size * size) + 1e-12)
            if db > -75 { anySignal = true }
            peaks[band] = max(db, peaks[band] - 0.08)
            let range: Float = 20
            let raw = peaks[band] < -100 ? 0 : max(0, min(1, (db - (peaks[band] - range)) / range))
            let shaped = pow(raw, 2.4)
            smoothed[band] = shaped > smoothed[band] ? shaped : smoothed[band] * 0.82
        }

        lock.lock()
        latest = smoothed
        if anySignal { sawSignal = true }
        lock.unlock()
    }
}
