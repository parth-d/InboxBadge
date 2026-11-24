import AppKit

@MainActor
final class SoundPlayer: NSObject, @preconcurrency NSSoundDelegate {
    private var playing: [NSSound] = []

    func play(_ name: String) {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        guard FileManager.default.fileExists(atPath: url.path),
              let sound = NSSound(contentsOf: url, byReference: true) else { return }
        sound.delegate = self
        playing.append(sound)
        sound.play()
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        playing.removeAll { $0 === sound }
    }
}
