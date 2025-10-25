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
    private var backendURL: URL!



    enum ConnectionState: String {
        case idle = "Idle"
        case scanning = "Scanning..."
        case connecting = "Connecting..."
        case connected = "Connected ✅"
        case failed = "Connection Failed ❌"
    }

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
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = .failed
        logMessage("❌ Failed to connect: \(error?.localizedDescription ?? "unknown error")")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics([characteristicUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                didDiscoverCharacteristicsFor service: CBService,
                error: Error?) {
    for char in service.characteristics ?? [] where char.uuid == characteristicUUID {
        writeCharacteristic = char
        peripheral.setNotifyValue(true, for: char)

        logMessage("✅ Ready. Sending ATZ...")
        sendCommand("ATZ")

        // After a short delay, send basic AT settings and request PIDs
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            self.sendCommand("ATE0")   // disable echo (recommended)
            self.sendCommand("ATL0")   // optional: no linefeeds
            self.sendCommand("ATS0")   // optional: no spaces
            self.sendCommand("ATH0")   // optional: no headers

            // Request Fuel Level (012F)
            self.logMessage("⛽ Requesting Fuel Level (012F)")
            self.sendCommand("012F")

            // Existing requests (RPM and Speed)
            self.sendCommand("010C")
            self.sendCommand("010D")
        }
    }
}


    func sendCommand(_ command: String) {
        guard let peripheral = obdPeripheral, let characteristic = writeCharacteristic else {
            return
        }
        let data = (command + "\r").data(using: .utf8)!
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        logMessage("→ \(command)")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
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
