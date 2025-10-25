import Foundation
import CoreBluetooth
import Combine

class OBDManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var centralManager: CBCentralManager!
    private var obdPeripheral: CBPeripheral?

    // Common UART-style service (used by many ELM327 clones)
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
        if let url = URL(string: "http://127.0.0.1:8000/obd-data") {
            backendURL = url
            logMessage("🌐 Using backend URL: \(url.absoluteString)")
        }
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

    // MARK: - Bluetooth Delegates
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothEnabled = true
            logMessage("✅ Bluetooth is ON")
        default:
            bluetoothEnabled = false
            logMessage("⚠️ Bluetooth unavailable or OFF")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
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

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            logMessage("❌ Service discovery error: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        for service in services {
            if service.uuid == fff0ServiceUUID {
                peripheral.discoverCharacteristics([fff1NotifyUUID, fff2WriteUUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error {
            logMessage("❌ Characteristic discovery error: \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else { return }
        for char in chars {
            if char.uuid == fff2WriteUUID { writeCharacteristic = char }
            if char.uuid == fff1NotifyUUID {
                notifyCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            logMessage("❌ Notification state error: \(error.localizedDescription)")
            return
        }

        if characteristic.uuid == fff1NotifyUUID, characteristic.isNotifying, !didStartInit {
            didStartInit = true
            rxBuffer.removeAll()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.startInitSequence()
            }
        }
    }

    // MARK: - Init sequence
    private func startInitSequence() {
        cmdQueue.removeAll()
        enqueueCommands([
            "ATZ", "ATE0", "ATL0", "ATS1", "ATH1",
            "ATSP7",
            "0100"   // Check supported PIDs first
        ])
    }

    private func enqueueCommands(_ cmds: [String]) {
        cmdQueue.append(contentsOf: cmds)
        advanceCommandQueue()
    }

    private func advanceCommandQueue() {
        guard !isSending, !cmdQueue.isEmpty else { return }
        isSending = true
        sendCommand(cmdQueue.removeFirst())
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
        logMessage("→ \(command)")

        currentTimeoutTask?.cancel()
        let task = DispatchWorkItem {
            if self.isSending {
                self.logMessage("⏱️ Timeout: No response")
                self.isSending = false
                self.advanceCommandQueue()
            }
        }
        currentTimeoutTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }

    // MARK: - Receive & Parse
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logMessage("❌ Update error: \(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value else { return }
        
        let s = String(data: value, encoding: .utf8) ?? ""
        logMessage("📥 RAW RX: \(s.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n"))")

        rxBuffer += s

        while let promptIndex = rxBuffer.firstIndex(of: ">") {
            let frameAscii = String(rxBuffer[..<promptIndex])
            rxBuffer.removeSubrange(...promptIndex)
            
            let tokens = hexTokens(from: frameAscii)
            if tokens.isEmpty {
                advanceCommandQueueAfterPrompt()
                continue
            }

            let joined = tokens.joined(separator: " ")
            if joined.localizedCaseInsensitiveContains("NO DATA") {
                logMessage("⚠️ NO DATA response")
                advanceCommandQueueAfterPrompt()
                continue
            }

            // Check for 0100 response
            if contains4100(tokens) {
                logMessage("✅ 0100 succeeded - Requesting data PIDs...")
                advanceCommandQueueAfterPrompt()
                // Request multiple PIDs
                enqueueCommands(["0104", "010B", "010C", "010D"])
                continue
            }

            // Check for Engine Load (0104)
            if let data = extractPID(from: tokens, mode: "41", pid: "04") {
                let raw = data.joined(separator: " ")
                logMessage("📊 Engine Load: \(raw)")
                advanceCommandQueueAfterPrompt()
                continue
            }

            // Check for Intake Manifold Pressure (010B)
            if let data = extractPID(from: tokens, mode: "41", pid: "0B") {
                let raw = data.joined(separator: " ")
                logMessage("🌪️ Manifold Pressure: \(raw)")
                advanceCommandQueueAfterPrompt()
                continue
            }

            // Check for Engine RPM (010C)
            if let data = extractPID(from: tokens, mode: "41", pid: "0C") {
                let raw = data.joined(separator: " ")
                logMessage("🏎️ Engine RPM: \(raw)")
                advanceCommandQueueAfterPrompt()
                continue
            }

            // Check for Vehicle Speed (010D)
            // Check for Vehicle Speed (010D)
            if let data = extractPID(from: tokens, mode: "41", pid: "0D") {
                let raw = data.joined(separator: " ")
                logMessage("🚗 Vehicle Speed: \(raw)")
                advanceCommandQueueAfterPrompt()
                // ❌ Removed the auto-loop for now
                continue
            }


            advanceCommandQueueAfterPrompt()
        }
    }

    private func contains4100(_ tokens: [String]) -> Bool {
        guard tokens.count >= 2 else { return false }
        
        for i in 0..<(tokens.count - 1) {
            if tokens[i] == "41" && tokens[i+1] == "00" {
                return true
            }
        }
        return false
    }

    private func extractPID(from tokens: [String], mode: String, pid: String) -> [String]? {
        let pidUpper = pid.uppercased()
        let modeUpper = mode.uppercased()
        
        // Different PIDs return different byte lengths
        let byteLengths: [String: Int] = [
            "04": 3,  // Engine Load: 41 04 XX (1 data byte)
            "0B": 3,  // MAP: 41 0B XX (1 data byte)
            "0C": 4,  // RPM: 41 0C XX XX (2 data bytes)
            "0D": 3   // Speed: 41 0D XX (1 data byte)
        ]
        
        guard let length = byteLengths[pidUpper], tokens.count >= length else {
            return nil
        }
        
        for i in 0...(tokens.count - length) {
            if tokens[i] == modeUpper && tokens[i+1] == pidUpper {
                return Array(tokens[i..<(i+length)])
            }
        }
        return nil
    }

    private func hexTokens(from string: String) -> [String] {
        return string
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).uppercased() }
    }

    // MARK: - API Communication (not used yet)
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
                self.logMessage("✅ Sent to backend OK")
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.logMessage("📥 API Response: \(json)")
                }
            } else {
                self.logMessage("⚠️ Backend returned status \(httpResponse.statusCode)")
            }
        }

        task.resume()
    }

    // MARK: - Logging
    private func logMessage(_ msg: String) {
        DispatchQueue.main.async {
            self.log.append(msg)
            print(msg)
        }
    }
}
