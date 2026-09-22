// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin
import RemoteCore

/// Bonjour results are untrusted hints; the existing TLS pin remains authoritative.
@MainActor final class DeviceDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var timer: Timer?
    private var searching = false
    var found: (String, String) -> Void = { _, _ in }
    func start() {
        guard timer == nil else { return }
        browser.delegate = self
        search()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.searching { self.search() }
                for service in self.services { service.stop(); service.resolve(withTimeout: 5) }
            }
        }
    }
    private func search() {
        searching = true
        browser.searchForServices(ofType: "_wri-input._tcp.", inDomain: "local.")
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) { searching = false }
    func stop() {
        timer?.invalidate(); timer = nil; browser.stop()
        services.forEach { $0.stop() }; services.removeAll()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard services.count < 64, !services.contains(service) else { return }
        services.append(service); service.delegate = self; service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.filter { $0 == service }.forEach { $0.stop() }; services.removeAll { $0 == service }
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let txt = sender.txtRecordData() else { return }
        let values = NetService.dictionary(fromTXTRecord: txt)
        guard values["v"] == Data("1".utf8), let raw = values["id"],
              let id = String(data: raw, encoding: .utf8), let pin = try? Transport.normalizedFingerprint(id) else { return }
        for data in sender.addresses ?? [] {
            guard data.count >= MemoryLayout<sockaddr_in>.size else { continue }
            let ip: String? = data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return nil }
                let address = base.assumingMemoryBound(to: sockaddr.self)
                guard address.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(data.count), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: host)
            }
            if let ip {
                let address = "\(ip):\(sender.port)"
                guard (try? Transport.endpoint(address: address)) != nil else { continue }
                found(pin, address)
            }
        }
    }
}
