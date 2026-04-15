import Network
import Observation

@Observable
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()

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
            let newType = path.availableInterfaces.first?.type
            Task { @MainActor in
                self.isConnected = connected
                self.isExpensive = expensive
                self.isCellular = cellular
                self.interfaceType = newType
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.tromme.networkstatus", qos: .utility))
    }
}
