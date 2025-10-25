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
    private let backendURL = URL(string: "http://YOUR_BACKEND_IP:8000/obd-data")!  // change this!

    override init() {
        super.init()
        print("init OBDManager")
        centralManager = CBCentralManager(delegate: self, queue: nil)
        print("CBCentralManager created, delegate set")
        centralManager = CBCentralManager(delegate: self, queue: nil)
        logMessage("OBDManager initialized")
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logMessage("central state = \(central.state.rawValue)")
        if central.state == .poweredOn {
            logMessage("Scanning for VEEPEAK OBDII...")
            central.scanForPeripherals(withServices: nil, options: nil)
        } else {
            logMessage("Bluetooth not available.")
        }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        if peripheral.name?.uppercased().contains("VEEPEAK") == true {
            logMessage("Found Veepak: \(peripheral.name ?? "Unknown")")
            obdPeripheral = peripheral
            central.stopScan()
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logMessage("Connected to \(peripheral.name ?? "OBD")")
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics([characteristicUUID], for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        for char in service.characteristics ?? [] where char.uuid == characteristicUUID {
            writeCharacteristic = char
            peripheral.setNotifyValue(true, for: char)
            logMessage("Ready. Sending ATZ...")
            sendCommand("ATZ")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.sendCommand("ATE0")  // disable echo
                self.sendCommand("010C")  // request RPM
                self.sendCommand("010D")  // request speed
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

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
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

// MARK: - Minimal UI
struct ContentView: View {
    @StateObject private var manager = OBDManager()

    var body: some View {
        VStack(alignment: .leading) {
            Text("Veepak BLE Bridge")
                .font(.title2)
                .padding(.bottom)
            ScrollView {
                ForEach(manager.log, id: \.self) { line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding()
    }
}


