import SwiftUI

struct ContentView: View {
    @StateObject var obdManager = OBDManager()
    @State private var showBluetoothAlert = false

    var body: some View {
        VStack(spacing: 20) {
            // Connection Status
            Text("OBD-II Connection: \(obdManager.connectionState.rawValue)")
                .font(.headline)
                .foregroundColor(statusColor)
            
            // Connection Button
            Button(action: {
                if obdManager.bluetoothEnabled {
                    if obdManager.connectionState == .connected {
                        obdManager.logMessage("⚠️ Disconnect not implemented yet")
                    } else {
                        obdManager.startConnection()
                    }
                } else {
                    showBluetoothAlert = true
                }
            }) {
                Label(
                    obdManager.connectionState == .connected ? "Connected" : "Connect to OBD-II",
                    systemImage: obdManager.connectionState == .connected ? "checkmark.circle.fill" : "bolt.horizontal.circle"
                )
                .font(.headline)
                .padding()
                .frame(maxWidth: .infinity)
                .background(obdManager.connectionState == .connected ? Color.green : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(obdManager.connectionState == .scanning || obdManager.connectionState == .connecting)

            // Data Display
            VStack(alignment: .leading, spacing: 5) {
                Text("RPM Hex: \(obdManager.lastRPMHex)")
                    .font(.caption)
                Text("Engine Load Hex: \(obdManager.lastLoadHex)")
                    .font(.caption)
                Text("Intake Manifold Hex: \(obdManager.lastManifoldHex)")
                    .font(.caption)
                Text("Speed: \(String(format: "%.1f", obdManager.displayedAverageSpeed)) km/h")
                    .font(.body)
                    .bold()
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

            // Speed Collection Controls (only show in auto mode)
            if !obdManager.useManualSpeed {
                HStack(spacing: 20) {
                    Button("Start Collecting Speed") {
                        obdManager.startCollectingSpeed()
                    }
                    .buttonStyle(.bordered)
                    .disabled(obdManager.connectionState != .connected)
                    
                    Button("Stop") {
                        obdManager.stopCollectingSpeed()
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Manual Speed Toggle
            Toggle("Use Manual Speed", isOn: $obdManager.useManualSpeed)
                .padding()
                .onChange(of: obdManager.useManualSpeed) { newValue in
                    obdManager.toggleSpeedMode(manual: newValue)
                }

            // Manual Speed Input (only show when manual mode is enabled)
            if obdManager.useManualSpeed {
                HStack {
                    Text("Manual Speed:")
                    TextField("km/h", value: $obdManager.manualAverageSpeed, format: .number)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 100)
                    
                    if obdManager.manualAverageSpeed > 0 {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
                .padding()
            }

            // Data Management - Different buttons for manual vs auto mode
            if obdManager.useManualSpeed {
                // Manual Mode Buttons
                HStack(spacing: 20) {
                    Button("Send Manual Speed Data") {
                        obdManager.sendManualSpeedData()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    
                    Button("Reset Speed Data") {
                        obdManager.resetAverageSpeed()
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                // Auto Mode Buttons
                HStack(spacing: 20) {
                    Button("Send Data to Backend") {
                        obdManager.sendAllOBDData()
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button("Reset Speed Data") {
                        obdManager.resetAverageSpeed()
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Log Display
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(obdManager.log.indices, id: \.self) { idx in
                        Text(obdManager.log[idx])
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxHeight: 200)
            .padding()
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)

            Spacer()
        }
        .padding()
        .alert("Bluetooth Required", isPresented: $showBluetoothAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please enable Bluetooth in Settings to connect to the OBD device.")
        }
    }
    
    // Helper computed property for status color
    var statusColor: Color {
        switch obdManager.connectionState {
        case .connected:
            return .green
        case .failed:
            return .red
        case .scanning, .connecting:
            return .orange
        default:
            return .gray
        }
    }
}
