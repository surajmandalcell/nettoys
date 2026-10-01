import CoreLocation
import Foundation

@MainActor
public final class NetToysHelperLocationAccess: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let onChange: @Sendable (NetToysSSIDAccessState) -> Void

    public init(onChange: @escaping @Sendable (NetToysSSIDAccessState) -> Void) {
        self.onChange = onChange
        super.init()
        manager.delegate = self
        publish()
    }

    public func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        guard manager.authorizationStatus != .denied, manager.authorizationStatus != .restricted else { return }
        manager.startUpdatingLocation()
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        publish()
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways: manager.startUpdatingLocation()
        case .denied, .restricted: manager.stopUpdatingLocation()
        default: break
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        publish()
        manager.stopUpdatingLocation()
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        publish()
        manager.stopUpdatingLocation()
    }

    private func publish() {
        let state: NetToysSSIDAccessState = switch manager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized, .authorizedAlways: .allowed
        @unknown default: .restricted
        }
        onChange(state)
    }
}
