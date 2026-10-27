import SwiftUI
import MapKit

/// Geographic overlays render below annotations, keeping the native red pin above
/// the signal. The parent owns the event coordinate and finite animation clock.
struct LocationPulse: MapContent {
    let coordinate: CLLocationCoordinate2D
    let maximumRadius: CLLocationDistance
    let elapsed: TimeInterval
    let reduceMotion: Bool

    private let duration: TimeInterval = 2.8
    private let ringCount = 4

    @MapContentBuilder
    var body: some MapContent {
        if CLLocationCoordinate2DIsValid(coordinate), maximumRadius.isFinite, maximumRadius > 0,
           elapsed.isFinite, elapsed >= 0, elapsed < duration {
            if reduceMotion {
                if elapsed < 0.65 {
                    MapCircle(center: coordinate, radius: maximumRadius * 0.25)
                        .foregroundStyle(.clear)
                        .stroke(.green.opacity(0.6), lineWidth: 2)
                        .mapOverlayLevel(level: .aboveLabels)
                }
            } else {
                ForEach(0..<ringCount, id: \.self) { index in
                    let progress = (elapsed - Double(index) * duration * 0.10) / (duration * 0.66)
                    if (0..<1).contains(progress) {
                        let eased = 1 - pow(1 - progress, 2)
                        let radius = maximumRadius * (0.125 + eased * 0.875)
                        let opacity = pow(1 - progress, 1.5) * 0.8
                        MapCircle(center: coordinate, radius: radius)
                            .foregroundStyle(.clear)
                            .stroke(.green.opacity(opacity * 0.12), lineWidth: 7)
                            .mapOverlayLevel(level: .aboveLabels)
                        MapCircle(center: coordinate, radius: radius)
                            .foregroundStyle(.clear)
                            .stroke(.green.opacity(opacity), lineWidth: 2)
                            .mapOverlayLevel(level: .aboveLabels)
                    }
                }
            }
        }
    }
}
