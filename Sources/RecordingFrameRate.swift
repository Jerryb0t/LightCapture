import Foundation
import CoreMedia
import ScreenCaptureKit

enum RecordingFrameRate:Int,CaseIterable {
    case fps24=24,fps30=30,fps60=60
    static let preferenceKey="recordingFrameRate"
    static func load(from defaults:UserDefaults = .standard)->Self {
        Self(rawValue:defaults.integer(forKey:preferenceKey)) ?? .fps30
    }
    func save(to defaults:UserDefaults = .standard){defaults.set(rawValue,forKey:Self.preferenceKey)}
    var interval:CMTime{CMTime(value:1,timescale:Int32(rawValue))}
    func configure(_ configuration:SCStreamConfiguration){configuration.minimumFrameInterval=interval}
}
