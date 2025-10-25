//OBDManager.swift

import SwiftUI
import CoreBluetooth
import Combine


// MARK: - BLE + Networking Bridge
class OBDManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var centralManager: CBCentralManager!
    private var obdPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private let serviceUUID = CBUUID(string: "FFE0")
    private let characteristicUUID = CBUUID(string: "FFE1")

    @Published var log: [String] = []
    @Published var connectionState: ConnectionState = .idle
    @Published var bluetoothEnabled: Bool = false

    //private let backendURL = URL(string: "http://YOUR_BACKEND_IP:8000/obd-data")!
    



    enum ConnectionState: String {
        case idle = "Idle"
        case scanning = "Scanning..."
        case connecting = "Connecting..."
        case connected = "Connected ✅"
        case failed = "Connection Failed ❌"
    }
    
    var backendURL: URL!
    
    override init() {
        super.init()
        
        let env = EnvLoader.loadEnv()
        if let urlString = env["BACKEND_URL"], let url = URL(string: urlString) {
            backendURL = url
            logMessage("🌐 Loaded BACKEND_URL: \(url.absoluteString)")
        } else {
            logMessage("⚠️ BACKEND_URL missing or invalid in .env")
            backendURL = URL(string: "http://127.0.0.1:8000/obd-data")! // fallback
        }
        centralManager = CBCentralManager(delegate: self, queue: nil)
        logMessage("OBDManager initialized")
    }

    // MARK: - Public
    func startConnection() {
        guard bluetoothEnabled else {
            logMessage("⚠️ Bluetooth is off or permission not granted.")
            connectionState = .failed
            return
        }
        connectionState = .scanning
        logMessage("🔍 Scanning for VEEPEAK OBDII...")
        centralManager.scanForPeripherals(withServices: nil, options: nil)
        
        // Timeout after 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if self.connectionState == .scanning {
                self.centralManager.stopScan()
                self.connectionState = .failed
                self.logMessage("❌ Could not find Veepak OBDII. Check power and try again.")
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothEnabled = true
            logMessage("✅ Bluetooth is ON")
        case .unauthorized:
            logMessage("⚠️ Bluetooth permissions not granted. Please enable in Settings.")
        default:
            bluetoothEnabled = false
            logMessage("⚠️ Bluetooth unavailable or OFF")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        if peripheral.name?.uppercased().contains("VEEPEAK") == true {
            logMessage("🔗 Found Veepak: \(peripheral.name ?? "Unknown")")
            obdPeripheral = peripheral
            central.stopScan()
            connectionState = .connecting
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logMessage("✅ Connected to \(peripheral.name ?? "OBD")")
        connectionState = .connected
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = .failed
        logMessage("❌ Failed to connect: \(error?.localizedDescription ?? "unknown error")")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            logMessage("❌ didDiscoverServices error: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            logMessage("⚠️ didDiscoverServices: no services found")
            return
        }
        logMessage("🧭 Services count: \(services.count)")
        for service in services {
            logMessage("🧭 Service: \(service.uuid.uuidString)")
            // Discover ALL characteristics for each service
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    
    private var notifyCharacteristic: CBCharacteristic?
    private var didStartInit = false

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error {
            logMessage("❌ didDiscoverCharacteristicsFor \(service.uuid.uuidString) error: \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics, !chars.isEmpty else {
            logMessage("⚠️ No characteristics for service \(service.uuid.uuidString)")
            return
        }

        for char in chars {
            logMessage("🔎 Char \(char.uuid.uuidString) props: \(char.properties) on service \(service.uuid.uuidString)")

            // Pick write char
            if writeCharacteristic == nil,
               (char.properties.contains(.write) || char.properties.contains(.writeWithoutResponse)) {
                writeCharacteristic = char
                logMessage("✍️ Selected write char: \(char.uuid.uuidString)")
            }

            // Pick notify char
            if notifyCharacteristic == nil,
               (char.properties.contains(.notify) || char.properties.contains(.indicate)) {
                notifyCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
                logMessage("🔔 Enabled notifications on \(char.uuid.uuidString)")
            }
        }

        // Start ELM init only once we have both
        if !didStartInit, writeCharacteristic != nil, notifyCharacteristic != nil {
            didStartInit = true
            logMessage("✅ Ready. Sending ATZ...")
            sendCommand("ATZ")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.sendCommand("ATE0")
                self.sendCommand("ATL0")
                self.sendCommand("ATS0")
                self.sendCommand("ATH0")
                self.logMessage("⛽ Requesting Fuel Level (012F)")
                self.sendCommand("012F")
                self.sendCommand("010C")
                self.sendCommand("010D")
            }
        }
    }

    func sendCommand(_ command: String) {
        guard let peripheral = obdPeripheral, let characteristic = writeCharacteristic else { return }
        guard let data = (command + "\r").data(using: .utf8) else { return }
        let useWWR = characteristic.properties.contains(.writeWithoutResponse) && !characteristic.properties.contains(.write)
        let type: CBCharacteristicWriteType = useWWR ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: characteristic, type: type)
        logMessage("→ \(command) [\(type == .withResponse ? "withResponse" : "withoutResponse")]")
    }


    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        logMessage("🔔 didUpdateValueFor \(characteristic.uuid)")
        guard let value = characteristic.value,
              let response = String(data: value, encoding: .utf8)
        else { return }
        logMessage("← \(response.trimmingCharacters(in: .whitespacesAndNewlines))")
        sendToBackend(response)
    }

    private func sendToBackend(_ response: String) {
        var request = URLRequest(url: backendURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = ["response": response]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: request).resume()
    }

    private func logMessage(_ msg: String) {
        DispatchQueue.main.async {
            self.log.append(msg)
            print(msg)
        }
    }
}
