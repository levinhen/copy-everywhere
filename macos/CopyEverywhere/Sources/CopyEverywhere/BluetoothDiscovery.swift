import Foundation
import IOBluetooth

// MARK: - Discovered Bluetooth device model

struct DiscoveredBluetoothDevice: Identifiable, Equatable {
    let id: String // Bluetooth address string
    let name: String
    let address: String
    let device: IOBluetoothDevice

    static func == (lhs: DiscoveredBluetoothDevice, rhs: DiscoveredBluetoothDevice) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Paired device info (persisted)

struct PairedBluetoothDevice: Codable, Identifiable, Equatable {
    let id: String // Bluetooth address string
    let name: String
    let address: String
}

// MARK: - BluetoothDiscovery

/// Wraps IOBluetoothDeviceInquiry for scanning nearby Bluetooth devices
/// and filtering for those publishing the CopyEverywhere RFCOMM service.
@MainActor
final class BluetoothDiscovery: NSObject, ObservableObject {

    @Published var isScanning = false
    @Published var discoveredDevices: [DiscoveredBluetoothDevice] = []
    @Published var scanError: String?

    private var inquiry: IOBluetoothDeviceInquiry?
    private var sdpQueryHelpers: [SDPFilterHelper] = []

    /// Start scanning for nearby Bluetooth devices.
    func startScan() {
        guard !isScanning else { return }

        discoveredDevices.removeAll()
        scanError = nil

        guard let inq = IOBluetoothDeviceInquiry(delegate: self) else {
            scanError = "Failed to create Bluetooth device inquiry"
            return
        }
        inq.updateNewDeviceNames = true
        inq.inquiryLength = 15 // seconds

        let status = inq.start()
        guard status == kIOReturnSuccess else {
            scanError = "Failed to start Bluetooth scan (code: \(status))"
            return
        }

        inquiry = inq
        isScanning = true
    }

    /// Stop the current scan.
    func stopScan() {
        inquiry?.stop()
        inquiry = nil
        isScanning = false
        sdpQueryHelpers.removeAll()
    }

    /// Filter a discovered device by performing an SDP query for the CopyEverywhere UUID.
    private func filterDevice(_ device: IOBluetoothDevice) {
        let helper = SDPFilterHelper(discovery: self, device: device)
        sdpQueryHelpers.append(helper)
        helper.performQuery()
    }

    /// Called by SDPFilterHelper when the query completes.
    fileprivate func sdpQueryCompleted(helper: SDPFilterHelper, device: IOBluetoothDevice, hasCopyEverywhereService: Bool) {
        sdpQueryHelpers.removeAll { $0 === helper }

        if hasCopyEverywhereService {
            let address = device.addressString ?? "unknown"
            let name = device.name ?? address
            let discovered = DiscoveredBluetoothDevice(
                id: address,
                name: name,
                address: address,
                device: device
            )
            if !discoveredDevices.contains(where: { $0.id == discovered.id }) {
                discoveredDevices.append(discovered)
            }
        }
    }

    deinit {
        inquiry?.stop()
    }
}

// MARK: - IOBluetoothDeviceInquiryDelegate

extension BluetoothDiscovery: IOBluetoothDeviceInquiryDelegate {

    nonisolated func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        guard let device = device else { return }
        Task { @MainActor in
            self.filterDevice(device)
        }
    }

    nonisolated func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        Task { @MainActor in
            self.isScanning = false
            self.inquiry = nil
            if error != kIOReturnSuccess && !aborted {
                self.scanError = "Bluetooth scan ended with error (code: \(error))"
            }
        }
    }

    nonisolated func deviceInquiryStarted(_ sender: IOBluetoothDeviceInquiry!) {
        Task { @MainActor in
            self.isScanning = true
        }
    }

    nonisolated func deviceInquiryUpdatingDeviceNamesStarted(_ sender: IOBluetoothDeviceInquiry!, devicesRemaining: UInt32) {
        // No action needed
    }

    nonisolated func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!, devicesRemaining: UInt32) {
        // Name updates are handled by the initial deviceFound + SDP filter
    }
}

// MARK: - SDP Filter Helper

/// Performs an SDP query on a discovered device to check for the CopyEverywhere RFCOMM service.
private class SDPFilterHelper: NSObject {

    private let discovery: BluetoothDiscovery
    private let device: IOBluetoothDevice

    init(discovery: BluetoothDiscovery, device: IOBluetoothDevice) {
        self.discovery = discovery
        self.device = device
    }

    func performQuery() {
        let status = device.performSDPQuery(self, uuids: [kCopyEverywhereServiceUUID])
        if status != kIOReturnSuccess {
            // SDP query failed to start — device doesn't have our service
            Task { @MainActor in
                self.discovery.sdpQueryCompleted(helper: self, device: self.device, hasCopyEverywhereService: false)
            }
        }
    }

    @objc func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        var found = false

        if status == kIOReturnSuccess,
           let records = device.services as? [IOBluetoothSDPServiceRecord] {
            for record in records {
                if record.hasService(from: [kCopyEverywhereServiceUUID]) {
                    found = true
                    break
                }
            }
        }

        Task { @MainActor in
            self.discovery.sdpQueryCompleted(helper: self, device: self.device, hasCopyEverywhereService: found)
        }
    }
}
