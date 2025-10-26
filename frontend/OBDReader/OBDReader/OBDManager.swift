import Foundation
import CoreBluetooth
import Combine

class OBDManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    // MARK: - Bluetooth
    private var centralManager: CBCentralManager!
    private var obdPeripheral: CBPeripheral?

    private let fff0ServiceUUID = CBUUID(string: "FFF0")
    private let fff1NotifyUUID  = CBUUID(string: "FFF1")
    private let fff2WriteUUID   = CBUUID(string: "FFF2")

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

    // MARK: - Speed & PID tracking
    @Published var speedSamples: [Double] = []
    private var maxSpeedSamples = 60
    @Published var averageSpeed: Double = 0.0
    @Published var currentSpeed: Double = 0.0
    @Published var isCollectingData = false

    @Published var useManualSpeed = false
    @Published var manualAverageSpeed: Double = 0.0
    @Published var displayedAverageSpeed: Double = 0.0

    // Latest hex per PID
    @Published var lastRPMHex: String = ""
    @Published var lastLoadHex: String = ""
    @Published var lastManifoldHex: String = ""

    // MARK: - Internal
    private var didStartInit = false
    private var rxBuffer = ""
    private var cmdQueue: [String] = []
    private var isSending = false
    private var currentTimeoutTask: DispatchWorkItem?
    private var backendURL: URL?

    override init() {
        super.init()
        if let url = URL(string: "http://172.20.10.2:8000/obd-data") {
            backendURL = url
            logMessage("🌐 Using backend URL: \(url.absoluteString)")
        }
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Connection
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
        bluetoothEnabled = (central.state == .poweredOn)
        logMessage(bluetoothEnabled ? "✅ Bluetooth is ON" : "⚠️ Bluetooth unavailable or OFF")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
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
        for service in services where service.uuid == fff0ServiceUUID {
            peripheral.discoverCharacteristics([fff1NotifyUUID, fff2WriteUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
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

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
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

    // MARK: - Command Queue
    private func startInitSequence() {
        cmdQueue.removeAll()
        enqueueCommands(["ATZ", "ATE0", "ATL0", "ATS1", "ATH1", "ATSP7", "0100"])
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
        if let error = error { logMessage("❌ Update error: \(error.localizedDescription)"); return }
        guard let value = characteristic.value else { return }

        let s = String(data: value, encoding: .utf8) ?? ""
        logMessage("📥 RAW RX: \(s.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n"))")

        rxBuffer += s
        while let promptIndex = rxBuffer.firstIndex(of: ">") {
            let frameAscii = String(rxBuffer[..<promptIndex])
            rxBuffer.removeSubrange(...promptIndex)

            let tokens = hexTokens(from: frameAscii)
            if tokens.isEmpty { advanceCommandQueueAfterPrompt(); continue }
            let joined = tokens.joined(separator: " ")
            if joined.localizedCaseInsensitiveContains("NO DATA") {
                logMessage("⚠️ NO DATA")
                advanceCommandQueueAfterPrompt()
                continue
            }

            // ✅ CHECK FOR 0100 RESPONSE FIRST
            if contains4100(tokens) {
                logMessage("✅ 0100 succeeded - Requesting data PIDs...")
                advanceCommandQueueAfterPrompt()
                enqueueCommands(["0104", "010B", "010C", "010D"])
                continue
            }

            // RPM 0C
            if let data = extractPID(from: tokens, mode: "41", pid: "0C") {
                lastRPMHex = data.joined(separator: " ")
                logMessage("🏎️ Engine RPM: \(lastRPMHex)")
                advanceCommandQueueAfterPrompt()
                continue
            }

            // Engine Load 04
            if let data = extractPID(from: tokens, mode: "41", pid: "04") {
                lastLoadHex = data.joined(separator: " ")
                logMessage("📊 Engine Load: \(lastLoadHex)")
                advanceCommandQueueAfterPrompt()
                continue
            }

            // Intake Manifold 0B
            if let data = extractPID(from: tokens, mode: "41", pid: "0B") {
                lastManifoldHex = data.joined(separator: " ")
                logMessage("🌪️ Manifold Pressure: \(lastManifoldHex)")
                advanceCommandQueueAfterPrompt()
                continue
            }

            // Speed 0D
            if let data = extractPID(from: tokens, mode: "41", pid: "0D") {
                if data.count >= 3, let speedHex = Int(data[2], radix: 16) {
                    let speed = Double(speedHex)
                    currentSpeed = speed
                    speedSamples.append(speed)
                    if speedSamples.count > maxSpeedSamples { speedSamples.removeFirst() }
                    if !speedSamples.isEmpty {
                        averageSpeed = speedSamples.reduce(0, +) / Double(speedSamples.count)
                    }
                    updateDisplayedAverage()
                    logMessage("🚗 Speed: \(String(format: "%.1f", speed)) km/h | Avg: \(String(format: "%.1f", displayedAverageSpeed)) km/h (\(speedSamples.count) samples)")
                }
                advanceCommandQueueAfterPrompt()
                if isCollectingData {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.enqueueCommands(["010D"])
                    }
                }
                continue
            }

            advanceCommandQueueAfterPrompt()
        }
    }

    private func hexTokens(from string: String) -> [String] {
        return string
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).uppercased() }
    }

    private func extractPID(from tokens: [String], mode: String, pid: String) -> [String]? {
        let byteLengths: [String: Int] = ["04":3,"0B":3,"0C":4,"0D":3]
        guard let length = byteLengths[pid.uppercased()], tokens.count >= length else { return nil }
        for i in 0...(tokens.count - length) {
            if tokens[i].uppercased() == mode.uppercased() && tokens[i+1].uppercased() == pid.uppercased() {
                return Array(tokens[i..<(i+length)])
            }
        }
        return nil
    }

    // ✅ HELPER FUNCTION FOR 0100 CHECK
    private func contains4100(_ tokens: [String]) -> Bool {
        guard tokens.count >= 2 else { return false }
        
        for i in 0..<(tokens.count - 1) {
            if tokens[i] == "41" && tokens[i+1] == "00" {
                return true
            }
        }
        return false
    }

    // MARK: - Speed Management
    private func updateDisplayedAverage() {
        displayedAverageSpeed = useManualSpeed ? manualAverageSpeed : averageSpeed
    }

    func setManualAverageSpeed(_ speed: Double) {
        manualAverageSpeed = speed
        useManualSpeed = true
        updateDisplayedAverage()
        logMessage("✏️ Manual average speed set to \(String(format: "%.1f", speed)) km/h")
    }

    func toggleSpeedMode(manual: Bool) {
        useManualSpeed = manual
        updateDisplayedAverage()
        logMessage(manual ? "📝 Using manual speed input" : "📊 Using calculated speed")
    }

    func startCollectingSpeed() {
        isCollectingData = true
        speedSamples.removeAll()
        averageSpeed = 0.0
        logMessage("▶️ Started collecting speed samples")
        enqueueCommands(["010D"])
    }

    func stopCollectingSpeed() {
        isCollectingData = false
        logMessage("⏸️ Stopped collecting (collected \(speedSamples.count) samples)")
    }

    func resetAverageSpeed() {
        speedSamples.removeAll()
        averageSpeed = 0.0
        currentSpeed = 0.0
        logMessage("🔄 Speed data cleared")
    }

    // MARK: - API Communication
    func sendAllOBDData() {
        let payload: [String: Any] = [
            "rpm_hex": lastRPMHex,
            "engine_load_hex": lastLoadHex,
            "intake_manifold_hex": lastManifoldHex,
            "speed_kmh": displayedAverageSpeed,
            "speed_source": useManualSpeed ? "manual" : "calculated",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        sendDataToBackend(payload: payload, successMessage: "✅ Sent OBD + speed to backend OK")
    }

    // ✅ NEW FUNCTION FOR MANUAL SPEED
    func sendManualSpeedData() {
        guard useManualSpeed else {
            logMessage("⚠️ Manual speed mode not enabled")
            return
        }
        
        let payload: [String: Any] = [
            "rpm_hex": lastRPMHex,
            "engine_load_hex": lastLoadHex,
            "intake_manifold_hex": lastManifoldHex,
            "speed_kmh": manualAverageSpeed,
            "speed_source": "manual",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        sendDataToBackend(
            payload: payload,
            successMessage: "✅ Sent manual speed (\(String(format: "%.1f", manualAverageSpeed)) km/h) to backend"
        )
    }

    // Shared function to send data to backend
    private func sendDataToBackend(payload: [String: Any], successMessage: String) {
        guard let backendURL = backendURL else {
            logMessage("❌ Backend URL not set")
            return
        }

        var request = URLRequest(url: backendURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            logMessage("❌ Failed to encode JSON: \(error)")
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                self.logMessage("❌ API Error: \(error.localizedDescription)")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                self.logMessage("❌ Invalid response")
                return
            }
            
            self.logMessage(httpResponse.statusCode == 200 ?
                successMessage :
                "⚠️ Backend returned status \(httpResponse.statusCode)")
            
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.logMessage("📥 API Response: \(json)")
            }
        }.resume()
    }

    // MARK: - Logging
    func logMessage(_ msg: String) {
        DispatchQueue.main.async { self.log.append(msg); print(msg) }
    }
}
