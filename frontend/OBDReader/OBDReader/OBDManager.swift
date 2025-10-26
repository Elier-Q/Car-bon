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

    // MARK: - Recording Session Data
    @Published var isCollectingData = false
    @Published var sampleCount: Int = 0
    
    // ✅ NEW: Arrays to store ALL hex samples during recording
    private var recordedRPMHex: [String] = []
    private var recordedLoadHex: [String] = []
    private var recordedManifoldHex: [String] = []
    private var recordedSpeedHex: [String] = []
    
    // ✅ NEW: Timestamps for each sample
    private var recordedTimestamps: [String] = []
    
    // Current live values (display only, not used for calculations)
    @Published var currentSpeed: Double = 0.0
    @Published var currentRPM: Double = 0.0
    @Published var currentLoad: Double = 0.0
    @Published var currentManifold: Double = 0.0
    
    // Results from backend after STOP
    @Published var averageSpeed: Double = 0.0
    @Published var averageRPM: Double = 0.0
    @Published var averageLoad: Double = 0.0
    @Published var averageManifold: Double = 0.0

    // Manual speed override (for non-recording mode)
    @Published var useManualSpeed = false
    @Published var manualAverageSpeed: Double = 0.0
    @Published var displayedAverageSpeed: Double = 0.0

    // Latest hex per PID (for non-recording mode)
    @Published var lastRPMHex: String = ""
    @Published var lastLoadHex: String = ""
    @Published var lastManifoldHex: String = ""
    
    // Parsed values from backend
    @Published var parsedRPM: Double = 0.0
    @Published var parsedEngineLoad: Double = -1.0
    @Published var parsedManifoldPressure: Double = 0.0
    @Published var emissions: [String: Any]?

    @Published var fuelLph: Double = 0.0
    @Published var co2KgPerHr: Double = 0.0

    private var hasAllPIDs: Bool {
        return !lastRPMHex.isEmpty && !lastLoadHex.isEmpty && !lastManifoldHex.isEmpty
    }
    
    @Published var autoParse: Bool = true
    
    private var manualSpeedTimer: Timer?
    private var autoParseTimer: Timer?

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

            if contains4100(tokens) {
                logMessage("✅ 0100 succeeded - Requesting data PIDs...")
                advanceCommandQueueAfterPrompt()
                enqueueCommands(["0104", "010B", "010C", "010D"])
                continue
            }

            // ✅ RPM 0C - Record hex if collecting
            if let data = extractPID(from: tokens, mode: "41", pid: "0C") {
                let hexString = data.joined(separator: " ")
                
                if isCollectingData {
                    recordedRPMHex.append(hexString)
                    // Quick parse for display only
                    if data.count >= 4,
                       let a = Int(data[2], radix: 16),
                       let b = Int(data[3], radix: 16) {
                        currentRPM = Double((a * 256 + b) / 4)
                    }
                    logMessage("🏎️ Recorded RPM (sample #\(recordedRPMHex.count))")
                } else {
                    lastRPMHex = hexString
                    logMessage("🏎️ Engine RPM hex: \(hexString)")
                }
                
                advanceCommandQueueAfterPrompt()
                if !isCollectingData { checkAndSendForParsing() }
                continue
            }

            // ✅ Engine Load 04 - Record hex if collecting
            if let data = extractPID(from: tokens, mode: "41", pid: "04") {
                let hexString = data.joined(separator: " ")
                
                if isCollectingData {
                    recordedLoadHex.append(hexString)
                    // Quick parse for display only
                    if data.count >= 3, let loadHex = Int(data[2], radix: 16) {
                        currentLoad = Double(loadHex) * 100.0 / 255.0
                    }
                    logMessage("📊 Recorded Load (sample #\(recordedLoadHex.count))")
                } else {
                    lastLoadHex = hexString
                    logMessage("📊 Engine Load hex: \(hexString)")
                }
                
                advanceCommandQueueAfterPrompt()
                if !isCollectingData { checkAndSendForParsing() }
                continue
            }

            // ✅ Intake Manifold 0B - Record hex if collecting
            if let data = extractPID(from: tokens, mode: "41", pid: "0B") {
                let hexString = data.joined(separator: " ")
                
                if isCollectingData {
                    recordedManifoldHex.append(hexString)
                    // Quick parse for display only
                    if data.count >= 3, let manifoldHex = Int(data[2], radix: 16) {
                        currentManifold = Double(manifoldHex)
                    }
                    logMessage("🌪️ Recorded Manifold (sample #\(recordedManifoldHex.count))")
                } else {
                    lastManifoldHex = hexString
                    logMessage("🌪️ Manifold Pressure hex: \(hexString)")
                }
                
                advanceCommandQueueAfterPrompt()
                if !isCollectingData { checkAndSendForParsing() }
                continue
            }

            // ✅ Speed 0D - Record hex if collecting
            if let data = extractPID(from: tokens, mode: "41", pid: "0D") {
                let hexString = data.joined(separator: " ")
                
                if isCollectingData {
                    recordedSpeedHex.append(hexString)
                    recordedTimestamps.append(ISO8601DateFormatter().string(from: Date()))
                    
                    // Quick parse for display only
                    if data.count >= 3, let speedHex = Int(data[2], radix: 16) {
                        currentSpeed = Double(speedHex)
                    }
                    
                    // Update sample count
                    sampleCount = min(recordedRPMHex.count, recordedLoadHex.count,
                                     recordedManifoldHex.count, recordedSpeedHex.count)
                    
                    logMessage("🚗 Recorded Speed (sample #\(recordedSpeedHex.count)) - Total: \(sampleCount) complete samples")
                } else {
                    // ✅ FIXED: Update all speed properties for single readings
                    if data.count >= 3, let speedHex = Int(data[2], radix: 16) {
                        currentSpeed = Double(speedHex)
                        
                        // ✅ NEW: Update averageSpeed and displayedAverageSpeed when not recording and not using manual
                        if !useManualSpeed {
                            averageSpeed = currentSpeed
                            displayedAverageSpeed = currentSpeed
                        }
                        
                        logMessage("🚗 Speed: \(String(format: "%.1f", currentSpeed)) km/h")
                    }
                }
                
                advanceCommandQueueAfterPrompt()
                if !isCollectingData { checkAndSendForParsing() }
                
                // Continue requesting if collecting
                if isCollectingData {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.enqueueCommands(["0104", "010B", "010C", "010D"])
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

    private func contains4100(_ tokens: [String]) -> Bool {
        guard tokens.count >= 2 else { return false }
        for i in 0..<(tokens.count - 1) {
            if tokens[i] == "41" && tokens[i+1] == "00" {
                return true
            }
        }
        return false
    }

    private func checkAndSendForParsing() {
        guard autoParse else { return }
        guard hasAllPIDs else { return }
        guard !isCollectingData else { return }
        
        autoParseTimer?.invalidate()
        autoParseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.hasAllPIDs && !self.isCollectingData {
                self.logMessage("🔄 Auto-parsing updated OBD data...")
                self.sendForLiveParsing()
            }
        }
    }

    // MARK: - Recording Session Management
    
    /// ✅ START - Clear everything and begin recording hex data
    func startCollectingSpeed() {
        // Clear recorded arrays
        recordedRPMHex.removeAll()
        recordedLoadHex.removeAll()
        recordedManifoldHex.removeAll()
        recordedSpeedHex.removeAll()
        recordedTimestamps.removeAll()
        
        // Clear current values
        currentSpeed = 0.0
        currentRPM = 0.0
        currentLoad = 0.0
        currentManifold = 0.0
        
        // Clear averages and emissions
        averageSpeed = 0.0
        averageRPM = 0.0
        averageLoad = 0.0
        averageManifold = 0.0
        fuelLph = 0.0
        co2KgPerHr = 0.0
        emissions = nil
        
        sampleCount = 0
        isCollectingData = true
        useManualSpeed = false
        
        logMessage("▶️ Started recording session")
        logMessage("📊 All hex data will be stored and sent to backend when stopped")
        
        // Start requesting PIDs
        enqueueCommands(["0104", "010B", "010C", "010D"])
    }

    /// ✅ STOP - Send all recorded hex data to backend
    func stopCollectingSpeed() {
        isCollectingData = false
        
        let minCount = min(recordedRPMHex.count, recordedLoadHex.count,
                          recordedManifoldHex.count, recordedSpeedHex.count)
        
        logMessage("⏸️ Stopped recording session")
        logMessage("📊 Collected \(minCount) complete samples")
        
        guard minCount > 0 else {
            logMessage("⚠️ No samples collected!")
            return
        }
        
        // Trim all arrays to same length (in case some PIDs had more samples)
        let rpmData = Array(recordedRPMHex.prefix(minCount))
        let loadData = Array(recordedLoadHex.prefix(minCount))
        let manifoldData = Array(recordedManifoldHex.prefix(minCount))
        let speedData = Array(recordedSpeedHex.prefix(minCount))
        let timestamps = Array(recordedTimestamps.prefix(minCount))
        
        logMessage("📤 Sending \(minCount) samples to backend for processing...")
        sendRecordedDataToBackend(
            rpmHexArray: rpmData,
            loadHexArray: loadData,
            manifoldHexArray: manifoldData,
            speedHexArray: speedData,
            timestamps: timestamps
        )
    }

    /// ✅ Send all recorded hex samples to backend
    private func sendRecordedDataToBackend(
        rpmHexArray: [String],
        loadHexArray: [String],
        manifoldHexArray: [String],
        speedHexArray: [String],
        timestamps: [String]
    ) {
        guard let backendURL = backendURL else {
            logMessage("❌ Backend URL not set")
            return
        }
        
        // Create payload with arrays of hex strings
        let payload: [String: Any] = [
            "session_data": [
                "rpm_hex_array": rpmHexArray,
                "engine_load_hex_array": loadHexArray,
                "intake_manifold_hex_array": manifoldHexArray,
                "speed_hex_array": speedHexArray,
                "timestamps": timestamps,
                "sample_count": rpmHexArray.count
            ],
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        var request = URLRequest(url: backendURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            logMessage("📦 Payload size: \(request.httpBody?.count ?? 0) bytes")
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
            
            if httpResponse.statusCode == 200 {
                self.logMessage("✅ Backend processed session data successfully")
                
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.logMessage("📥 Backend response: \(json)")
                    self.parseSessionResponse(json)
                }
            } else {
                self.logMessage("⚠️ Backend returned status \(httpResponse.statusCode)")
                if let data = data, let errorMsg = String(data: data, encoding: .utf8) {
                    self.logMessage("❌ Error details: \(errorMsg)")
                }
            }
        }.resume()
    }

    /// ✅ Parse session response with averages and emissions
    private func parseSessionResponse(_ json: [String: Any]) {
        // Extract averaged values
        if let averages = json["averages"] as? [String: Any] {
            DispatchQueue.main.async {
                if let avgRPM = averages["rpm"] as? Double {
                    self.averageRPM = avgRPM
                    self.parsedRPM = avgRPM
                    self.logMessage("🏎️ Average RPM: \(String(format: "%.0f", avgRPM)) rpm")
                }
                
                if let avgLoad = averages["engine_load"] as? Double {
                    self.averageLoad = avgLoad
                    self.parsedEngineLoad = avgLoad
                    self.logMessage("📊 Average Load: \(String(format: "%.1f", avgLoad))%")
                }
                
                if let avgManifold = averages["intake_manifold"] as? Double {
                    self.averageManifold = avgManifold
                    self.parsedManifoldPressure = avgManifold
                    self.logMessage("🌪️ Average Manifold: \(String(format: "%.0f", avgManifold)) kPa")
                }
                
                if let avgSpeed = averages["speed"] as? Double {
                    self.averageSpeed = avgSpeed
                    self.displayedAverageSpeed = avgSpeed
                    self.logMessage("🚗 Average Speed: \(String(format: "%.1f", avgSpeed)) km/h")
                }
            }
        }
        
        // Extract emissions
        if let emissions = json["emissions"] as? [String: Any] {
            DispatchQueue.main.async {
                self.emissions = emissions
                
                if let fuelValue = emissions["fuel_lph"] {
                    if let fuelDouble = fuelValue as? Double {
                        self.fuelLph = fuelDouble
                        self.logMessage("⛽ Fuel: \(String(format: "%.2f", fuelDouble)) L/h")
                    } else if let fuelString = fuelValue as? String,
                              let fuelDouble = Double(fuelString) {
                        self.fuelLph = fuelDouble
                        self.logMessage("⛽ Fuel: \(String(format: "%.2f", fuelDouble)) L/h")
                    }
                }
                
                if let co2Value = emissions["co2_kg_per_hr"] {
                    if let co2Double = co2Value as? Double {
                        self.co2KgPerHr = co2Double
                        self.logMessage("🌍 CO₂: \(String(format: "%.2f", co2Double)) kg/hr")
                    } else if let co2String = co2Value as? String,
                              let co2Double = Double(co2String) {
                        self.co2KgPerHr = co2Double
                        self.logMessage("🌍 CO₂: \(String(format: "%.2f", co2Double)) kg/hr")
                    }
                }
            }
        }
    }

    // MARK: - Speed Management (for non-recording mode)
    
    private func updateDisplayedAverage() {
        displayedAverageSpeed = useManualSpeed ? manualAverageSpeed : averageSpeed
    }

    func setManualAverageSpeed(_ speed: Double) {
        guard !isCollectingData else {
            logMessage("⚠️ Cannot use manual speed while recording")
            return
        }
        
        manualAverageSpeed = speed
        useManualSpeed = true
        updateDisplayedAverage()
        logMessage("✏️ Manual average speed set to \(String(format: "%.1f", speed)) km/h")
        
        manualSpeedTimer?.invalidate()
        manualSpeedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.hasAllPIDs {
                self.logMessage("🔄 Calculating emissions with speed: \(String(format: "%.1f", speed)) km/h")
                self.sendForLiveParsing(successMessage: "✅ Updated with manual speed", silent: false)
            }
        }
    }
    
    func triggerManualSpeedUpdate(_ speed: Double) {
        setManualAverageSpeed(speed)
    }

    func toggleSpeedMode(manual: Bool) {
        guard !isCollectingData else {
            logMessage("⚠️ Cannot toggle mode while recording")
            return
        }
        
        useManualSpeed = manual
        updateDisplayedAverage()
        logMessage(manual ? "📝 Using manual speed input" : "📊 Using calculated speed")
        
        if hasAllPIDs {
            logMessage("🔄 Recalculating with \(manual ? "manual" : "calculated") speed...")
            sendForLiveParsing(successMessage: "✅ Updated speed mode", silent: false)
        }
    }

    // ✅ KEEP: Regular reset (unchanged)
    func resetAverageSpeed() {
        recordedRPMHex.removeAll()
        recordedLoadHex.removeAll()
        recordedManifoldHex.removeAll()
        recordedSpeedHex.removeAll()
        recordedTimestamps.removeAll()
        
        averageSpeed = 0.0
        averageRPM = 0.0
        averageLoad = 0.0
        averageManifold = 0.0
        
        currentSpeed = 0.0
        currentRPM = 0.0
        currentLoad = 0.0
        currentManifold = 0.0
        
        manualAverageSpeed = 0.0
        displayedAverageSpeed = 0.0
        useManualSpeed = false
        sampleCount = 0
        
        lastRPMHex = ""
        lastLoadHex = ""
        lastManifoldHex = ""
        
        parsedRPM = 0.0
        parsedEngineLoad = -1.0
        parsedManifoldPressure = 0.0
        
        emissions = nil
        fuelLph = 0.0
        co2KgPerHr = 0.0
        
        manualSpeedTimer?.invalidate()
        autoParseTimer?.invalidate()
        
        logMessage("🔄 All data cleared - requesting fresh OBD data...")
        
        if connectionState == .connected {
            enqueueCommands(["0104", "010B", "010C", "010D"])
            logMessage("📡 Querying OBD sensor for fresh data...")
        }
    }

    // MARK: - API Communication (for non-recording mode)
    
    func sendAllOBDData() {
        guard !isCollectingData else {
            logMessage("⚠️ Cannot send while recording - press STOP first")
            return
        }
        sendForLiveParsing(successMessage: "✅ Sent OBD + speed to backend", silent: false)
    }

    func sendManualSpeedData() {
        guard !isCollectingData else {
            logMessage("⚠️ Cannot send while recording - press STOP first")
            return
        }
        guard useManualSpeed else {
            logMessage("⚠️ Manual speed mode not enabled")
            return
        }
        sendForLiveParsing(
            successMessage: "✅ Sent manual speed (\(String(format: "%.1f", manualAverageSpeed)) km/h)",
            silent: false
        )
    }
    
    private func sendForLiveParsing(successMessage: String = "🔄 Live parsed", silent: Bool = true) {
        guard !isCollectingData else { return }
        guard hasAllPIDs else {
            if !silent { logMessage("⚠️ Cannot send - missing OBD data") }
            return
        }
        
        let payload: [String: Any] = [
            "rpm_hex": lastRPMHex,
            "engine_load_hex": lastLoadHex,
            "intake_manifold_hex": lastManifoldHex,
            "speed_kmh": displayedAverageSpeed,
            "speed_source": useManualSpeed ? "manual" : "calculated",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        if !silent {
            logMessage("📤 Sending: Speed=\(String(format: "%.1f", displayedAverageSpeed)) km/h")
        }
        
        sendDataToBackend(payload: payload, successMessage: successMessage, silent: silent)
    }

    private func sendDataToBackend(payload: [String: Any], successMessage: String, silent: Bool = false) {
        guard let backendURL = backendURL else {
            if !silent { logMessage("❌ Backend URL not set") }
            return
        }

        var request = URLRequest(url: backendURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            if !silent { logMessage("❌ Failed to encode JSON: \(error)") }
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                if !silent { self.logMessage("❌ API Error: \(error.localizedDescription)") }
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                if !silent { self.logMessage("❌ Invalid response") }
                return
            }
            
            if httpResponse.statusCode == 200 {
                if !silent { self.logMessage(successMessage) }
                
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if !silent { self.logMessage("📥 Backend response: \(json)") }
                    self.parseBackendResponse(json)
                }
            } else {
                self.logMessage("⚠️ Backend returned status \(httpResponse.statusCode)")
                if let data = data, let errorMsg = String(data: data, encoding: .utf8) {
                    self.logMessage("❌ Error details: \(errorMsg)")
                }
            }
        }.resume()
    }

    private func parseBackendResponse(_ json: [String: Any]) {
        if let parsed = json["parsed"] as? [String: Any] {
            if let rpm = parsed["rpm"] as? [String: Any],
               let value = rpm["value"] as? Double {
                DispatchQueue.main.async {
                    self.parsedRPM = value
                    self.logMessage("🏎️ Parsed RPM: \(String(format: "%.0f", value)) rpm")
                }
            }
            
            if let load = parsed["engine_load"] as? [String: Any],
               let value = load["value"] as? Double {
                DispatchQueue.main.async {
                    self.parsedEngineLoad = value
                    self.logMessage("📊 Parsed Load: \(String(format: "%.1f", value))%")
                }
            }
            
            if let manifold = parsed["intake_manifold"] as? [String: Any],
               let value = manifold["value"] as? Double {
                DispatchQueue.main.async {
                    self.parsedManifoldPressure = value
                    self.logMessage("🌪️ Parsed Pressure: \(String(format: "%.0f", value)) kPa")
                }
            }
        }
        
        if let emissions = json["emissions"] as? [String: Any] {
            DispatchQueue.main.async {
                self.emissions = emissions
                
                if let fuelValue = emissions["fuel_lph"] {
                    if let fuelDouble = fuelValue as? Double {
                        self.fuelLph = fuelDouble
                        self.logMessage("⛽ Fuel: \(String(format: "%.2f", fuelDouble)) L/h")
                    } else if let fuelString = fuelValue as? String,
                              let fuelDouble = Double(fuelString) {
                        self.fuelLph = fuelDouble
                        self.logMessage("⛽ Fuel: \(String(format: "%.2f", fuelDouble)) L/h")
                    }
                }
                
                if let co2Value = emissions["co2_kg_per_hr"] {
                    if let co2Double = co2Value as? Double {
                        self.co2KgPerHr = co2Double
                        self.logMessage("🌍 CO₂: \(String(format: "%.2f", co2Double)) kg/hr")
                    } else if let co2String = co2Value as? String,
                              let co2Double = Double(co2String) {
                        self.co2KgPerHr = co2Double
                        self.logMessage("🌍 CO₂: \(String(format: "%.2f", co2Double)) kg/hr")
                    }
                }
            }
        }
    }

    func logMessage(_ msg: String) {
        DispatchQueue.main.async { self.log.append(msg); print(msg) }
    }
}
