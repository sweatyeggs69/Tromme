import Foundation
import Network
import Observation

@Observable
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()
    static let didChangeNotification = Notification.Name("NetworkStatus.didChange")

    private(set) var isConnected = true
    private(set) var isExpensive = false
    private(set) var isCellular = false
    private(set) var interfaceType: NWInterface.InterfaceType?

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied
            let expensive = path.isExpensive
            let cellular = path.usesInterfaceType(.cellular)
            let newType: NWInterface.InterfaceType? = if path.usesInterfaceType(.wifi) {
                .wifi
            } else if path.usesInterfaceType(.cellular) {
                .cellular
            } else if path.usesInterfaceType(.wiredEthernet) {
                .wiredEthernet
            } else if path.usesInterfaceType(.loopback) {
                .loopback
            } else if path.usesInterfaceType(.other) {
                .other
            } else {
                nil
            }
            Task { @MainActor in
                self.isConnected = connected
                self.isExpensive = expensive
                self.isCellular = cellular
                self.interfaceType = newType
                NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.tromme.networkstatus", qos: .utility))
    }
}
