import SwiftUI
import CoreBluetooth
import Combine

class OBDManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var centralManager: CBCentralManager!
    private var obdPeripheral: CBPeripheral?

    // FFF0 UART-style service used by many ELM327 clones
    private let fff0ServiceUUID = CBUUID(string: "FFF0")
    private let fff1NotifyUUID  = CBUUID(string: "FFF1")  // TX (notify)
    private let fff2WriteUUID   = CBUUID(string: "FFF2")  // RX (write)

    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    @Published var log: [String] = []
    @Published var connectionState: ConnectionState = .idle
    @Published var bluetoothEnabled: Bool = false

    enum ConnectionState: String {
        case idle = "Idle"
        case scanning = "Scanning..."
        case connecting = "Connecting..."
        case connected = "Connected ✅"
        case failed = "Connection Failed ❌"
    }

    private var didStartInit = false
    private var rxBuffer = ""
    private var cmdQueue: [String] = []
    private var isSending = false
    private var currentTimeoutTask: DispatchWorkItem?
    private var backendURL: URL!

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
        logMessage("OBDManager initialized")
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startConnection() {
        guard bluetoothEnabled else {
            logMessage("⚠️ Bluetooth is off or permission not granted.")
            connectionState = .failed
            return
        }
        connectionState = .scanning
        logMessage("🔍 Scanning for VEEPEAK OBDII...")
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

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
            bluetoothEnabled = false
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
        peripheral.discoverServices([fff0ServiceUUID])
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
        for service in services {
            logMessage("🧭 Service: \(service.uuid.uuidString)")
            if service.uuid == fff0ServiceUUID {
                peripheral.discoverCharacteristics([fff1NotifyUUID, fff2WriteUUID], for: service)
            }
        }
    }

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
            if char.uuid == fff2WriteUUID {
                writeCharacteristic = char
                logMessage("✍️ Using FFF2 as write")
            }
            if char.uuid == fff1NotifyUUID {
                notifyCharacteristic = char
                if !char.isNotifying {
                    peripheral.setNotifyValue(true, for: char)
                    logMessage("🔔 Using FFF1 as notify (enabled)")
                } else {
                    logMessage("🔔 Using FFF1 as notify (already enabled)")
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            logMessage("❌ didUpdateNotificationStateFor \(characteristic.uuid.uuidString): \(error.localizedDescription)")
            return
        }
        logMessage("🔔 Notification state updated for \(characteristic.uuid.uuidString): \(characteristic.isNotifying)")

        if characteristic.uuid == fff1NotifyUUID,
           characteristic.isNotifying,
           writeCharacteristic != nil,
           !didStartInit {
            didStartInit = true
            rxBuffer.removeAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.startInitATSP7()
            }
        }
    }

    // MARK: - Init sequence (force ISO15765-4 CAN)
    private func startInitATSP7() {
        cmdQueue.removeAll()
        enqueueCommands([
            "ATI",
            "ATZ",
            "ATE0",
            "ATL0",
            "ATS0",
            "ATH1",   // headers ON
            "ATSP7",  // ISO 15765-4 CAN (29bit, 500kbps)
            "0100"    // confirm supported PIDs
        ])
    }

    private func enqueueCommands(_ cmds: [String]) {
        cmdQueue.append(contentsOf: cmds)
        advanceCommandQueue()
    }

    private func advanceCommandQueue() {
        guard !isSending, !cmdQueue.isEmpty else { return }
        isSending = true
        let next = cmdQueue.removeFirst()
        sendCommand(next)
    }

    private func advanceCommandQueueAfterPrompt() {
        currentTimeoutTask?.cancel()
        isSending = false
        advanceCommandQueue()
    }

    private func sendCommand(_ command: String) {
        guard let peripheral = obdPeripheral, let ch = writeCharacteristic else { return }
        guard let data = (command + "\r").data(using: .utf8) else { return }

        peripheral.writeValue(data, for: ch, type: .withoutResponse)
        logMessage("→ \(command) [FFF0 path]")
        
        currentTimeoutTask?.cancel()
        let task = DispatchWorkItem {
            if self.isSending {
                self.logMessage("⏱️ Timeout after 5s - no prompt received")
                self.isSending = false
                self.advanceCommandQueue()
            }
        }
        currentTimeoutTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: task)
    }

    // MARK: - Receive and parse ECU responses
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logMessage("❌ didUpdateValueFor \(characteristic.uuid) error: \(error.localizedDescription)")
        }
        guard let value = characteristic.value else { return }

        let s = String(data: value, encoding: .utf8)
        if let s = s, !s.isEmpty {
            logMessage("← ascii [\(characteristic.uuid.uuidString)]: \(s.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n"))")
            rxBuffer += s
        } else {
            let hex = value.map { String(format: "%02X", $0) }.joined(separator: " ")
            logMessage("← hex   [\(characteristic.uuid.uuidString)]: \(hex)")
        }

        while rxBuffer.contains(">") {
            let components = rxBuffer.components(separatedBy: ">")
            guard components.count >= 2 else {
                rxBuffer = ""
                break
            }
            let frameAscii = components[0]
            rxBuffer = components.dropFirst().joined(separator: ">")
            let tokens = hexTokens(from: frameAscii)
            if tokens.isEmpty {
                advanceCommandQueueAfterPrompt()
                continue
            }

            // handle ECU not ready
            let joined = tokens.joined(separator: " ")
            if joined.localizedCaseInsensitiveContains("SEARCHING")
                || joined.localizedCaseInsensitiveContains("NO DATA")
                || joined.localizedCaseInsensitiveContains("STOPPED") {
                logMessage("⚠️ ECU not responding yet: \(joined) — retrying 0100")
                advanceCommandQueueAfterPrompt()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    self.enqueueCommands(["0100"])
                }
                continue
            }

            // handle 0100 success
            if contains4100(tokens) {
                logMessage("✅ 0100 succeeded")
                advanceCommandQueueAfterPrompt()
                enqueueCommands(["ATDP", "ATH0", "0110"]) // request MAF
                continue
            }

            // handle 0110 (MAF)
            if let mafQuad = extract0110Quad(from: tokens) {
                let raw = mafQuad.joined(separator: " ")
                logMessage("🌬️ RAW 0110 (MAF): \(raw)")
                sendOBDDataToAPI(hexData: raw)
                advanceCommandQueueAfterPrompt()
                continue
            }

            logMessage("← tokens: \(tokens.joined(separator: " "))")
            advanceCommandQueueAfterPrompt()
        }
    }

    private func contains4100(_ tokens: [String]) -> Bool {
        if tokens.count >= 2, tokens[0] == "41", tokens[1] == "00" { return true }
        return tokens.contains { $0.contains("4100") }
    }

    private func extract0110Quad(from tokens: [String]) -> [String]? {
        if tokens.count >= 4 {
            for i in 0...(tokens.count - 4) {
                if tokens[i] == "41" && tokens[i + 1] == "10" {
                    return [tokens[i], tokens[i + 1], tokens[i + 2], tokens[i + 3]]
                }
            }
        }
        for t in tokens {
            if let range = t.range(of: "4110") {
                let after = String(t[range.upperBound...])
                let A = String(after.prefix(2))
                let B = String(after.dropFirst(2).prefix(2))
                if A.count == 2, B.count == 2 {
                    return ["41", "10", A, B]
                }
            }
        }
        return nil
    }

    private func hexTokens(from string: String) -> [String] {
        let cleaned = string
            .replacingOccurrences(of: ">", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        if cleaned.isEmpty { return [] }

        if cleaned.contains(" ") {
            return cleaned.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        } else {
            var tokens: [String] = []
            var remaining = cleaned
            while !remaining.isEmpty {
                let chunk = String(remaining.prefix(2))
                tokens.append(chunk)
                remaining = String(remaining.dropFirst(min(2, remaining.count)))
            }
            return tokens
        }
    }

    // MARK: - Send to backend
    private func sendOBDDataToAPI(hexData: String) {
        var request = URLRequest(url: backendURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "hex_data": hexData,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            logMessage("❌ Failed to encode JSON: \(error)")
            return
        }

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                self.logMessage("❌ API Error: \(error.localizedDescription)")
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                self.logMessage("❌ Invalid response")
                return
            }

            if httpResponse.statusCode == 200 {
                self.logMessage("✅ Data sent to API successfully")
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.logMessage("📥 API Response: \(json)")
                }
            } else {
                self.logMessage("⚠️ API returned status \(httpResponse.statusCode)")
            }
        }

        task.resume()
    }

    private func logMessage(_ msg: String) {
        DispatchQueue.main.async {
            self.log.append(msg)
            print(msg)
        }
    }
}
