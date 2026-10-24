import Foundation

/// На macOS 15.4+ MediaRemote отдаёт данные только процессам Apple. Поэтому вызовы идут
/// через системный `/usr/bin/perl`, который грузит `adapter.dylib` из Resources.
final class MediaRemoteBridge {
    struct Snapshot {
        var info: [String: Any]
        var isPlaying: Bool
        var bundleID: String?
    }

    struct Client {
        var bundleID: String
        var info: [String: Any]
    }

    struct Overview {
        var clients: [Client]
        var activeBundleID: String?
        var activeIsPlaying: Bool
    }

    private let dylib: String
    private let script: String
    private let queue = DispatchQueue(label: "island.mediaremote", qos: .userInitiated)

    init?() {
        guard
            let resources = Bundle.main.resourceURL,
            FileManager.default.fileExists(atPath: resources.appendingPathComponent("adapter.dylib").path),
            FileManager.default.fileExists(atPath: resources.appendingPathComponent("run.pl").path)
        else { return nil }
        dylib = resources.appendingPathComponent("adapter.dylib").path
        script = resources.appendingPathComponent("run.pl").path
        // Библиотека исполняется внутри системного perl: не запускаем её, если подменить файл может кто-то кроме владельца.
        guard Self.isTamperProof(dylib), Self.isTamperProof(script) else { return nil }
    }

    private static func isTamperProof(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              let owner = attributes[.ownerAccountID] as? NSNumber else { return false }
        let writableByOthers = permissions.intValue & 0o022 != 0
        return !writableByOthers && owner.uint32Value == getuid()
    }

    func fetch(completion: @escaping (Snapshot?) -> Void) {
        queue.async { [self] in
            guard let data = run("adapter_get", env: [:]),
                  var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                completion(nil)
                return
            }
            let playing = (json.removeValue(forKey: "_playing") as? NSNumber)?.boolValue ?? false
            let bundle = json.removeValue(forKey: "_bundle") as? String
            if let encoded = json["kMRMediaRemoteNowPlayingInfoArtworkData"] as? String {
                json["kMRMediaRemoteNowPlayingInfoArtworkData"] = Data(base64Encoded: encoded)
            }
            if let stamp = (json["kMRMediaRemoteNowPlayingInfoTimestamp"] as? NSNumber)?.doubleValue {
                json["kMRMediaRemoteNowPlayingInfoTimestamp"] = Date(timeIntervalSince1970: stamp)
            }
            completion(Snapshot(info: json, isPlaying: playing, bundleID: bundle))
        }
    }

    /// Все приложения с Now Playing: например, Яндекс Музыка и YouTube в Chrome одновременно.
    func fetchAll(completion: @escaping (Overview?) -> Void) {
        queue.async { [self] in
            guard let data = run("adapter_all", env: [:]),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                completion(nil)
                return
            }
            let rows = json["clients"] as? [[String: Any]] ?? []
            var clients: [Client] = []
            for row in rows {
                guard let bundle = row["bundle"] as? String, var info = row["info"] as? [String: Any] else { continue }
                if let encoded = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? String {
                    info["kMRMediaRemoteNowPlayingInfoArtworkData"] = Data(base64Encoded: encoded)
                }
                if let stamp = (info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? NSNumber)?.doubleValue {
                    info["kMRMediaRemoteNowPlayingInfoTimestamp"] = Date(timeIntervalSince1970: stamp)
                }
                clients.append(Client(bundleID: bundle, info: info))
            }
            completion(Overview(
                clients: clients,
                activeBundleID: json["active"] as? String,
                activeIsPlaying: (json["activePlaying"] as? NSNumber)?.boolValue ?? false
            ))
        }
    }

    func send(command: UInt32, completion: (() -> Void)? = nil) {
        queue.async { [self] in
            _ = run("adapter_send", env: ["ISLAND_CMD": String(command)])
            completion?()
        }
    }

    func seek(to seconds: TimeInterval, completion: (() -> Void)? = nil) {
        queue.async { [self] in
            _ = run("adapter_seek", env: ["ISLAND_SEEK": String(seconds)])
            completion?()
        }
    }

    private func run(_ function: String, env: [String: String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script, dylib, function]
        // Окружение не наследуем: PERL5OPT, DYLD_* и подобные переменные позволили бы подмешать чужой код.
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return process.terminationStatus == 0 ? data : nil
    }
}
