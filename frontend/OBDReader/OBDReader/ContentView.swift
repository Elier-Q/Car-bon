import SwiftUI

struct ContentView: View {
    @StateObject var obdManager = OBDManager()
    @State private var showBluetoothAlert = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: "car.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.blue)
                    
                    Text("OBD-II Monitor")
                        .font(.title)
                        .bold()
                    
                    Text(obdManager.connectionState.rawValue)
                        .font(.subheadline)
                        .foregroundColor(statusColor)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(statusColor.opacity(0.2))
                        .cornerRadius(20)
                }
                .padding(.top)
                
                // Connection Button
                Button(action: {
                    if obdManager.bluetoothEnabled {
                        if obdManager.connectionState != .connected {
                            obdManager.startConnection()
                        }
                    } else {
                        showBluetoothAlert = true
                    }
                }) {
                    Label(
                        obdManager.connectionState == .connected ? "Connected" : "Connect to Vehicle",
                        systemImage: obdManager.connectionState == .connected ? "checkmark.circle.fill" : "bolt.horizontal.circle"
                    )
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: obdManager.connectionState == .connected ? [.green, .green.opacity(0.8)] : [.blue, .blue.opacity(0.7)]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(12)
                    .shadow(radius: 4)
                }
                .disabled(obdManager.connectionState == .scanning || obdManager.connectionState == .connecting || obdManager.connectionState == .connected)
                .padding(.horizontal)

                // Engine Data Section
                VStack(spacing: 16) {
                    Text("Engine Data")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    
                    HStack(spacing: 16) {
                        DataCard(
                            icon: "speedometer",
                            title: "Engine RPM",
                            value: obdManager.parsedRPM > 0 ? String(format: "%.0f", obdManager.parsedRPM) : "--",
                            unit: "RPM",
                            color: .orange
                        )
                        
                        DataCard(
                            icon: "gauge.medium",
                            title: "Engine Load",
                            value: obdManager.parsedEngineLoad >= 0 ? String(format: "%.1f", obdManager.parsedEngineLoad) : "--",
                            unit: "%",
                            color: .purple
                        )
                    }
                    
                    HStack(spacing: 16) {
                        DataCard(
                            icon: "wind",
                            title: "Manifold Pressure",
                            value: obdManager.parsedManifoldPressure > 0 ? String(format: "%.0f", obdManager.parsedManifoldPressure) : "--",
                            unit: "kPa",
                            color: .cyan
                        )
                        
                        DataCard(
                            icon: "arrow.right",
                            title: "Speed",
                            value: String(format: "%.1f", obdManager.displayedAverageSpeed),
                            unit: "km/h",
                            color: .green
                        )
                    }
                }
                .padding(.horizontal)

                // ✅ FIXED: Emissions & Fuel Section with correct property names
                VStack(spacing: 16) {
                    Text("Emissions & Fuel")
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    
                    // Titles row with emissions rating next to each title
                    HStack(spacing: 16) {
                        VStack(alignment: .leading) {
                            HStack(spacing: 8) {
                                Text("CO₂ Rate")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                HStack(spacing: 6) {
                                    Text(emissionsRating)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Image(systemName: emissionsIcon)
                                        .foregroundColor(emissionsColor)
                                }
                            }
                        }

                        VStack(alignment: .leading) {
                            HStack(spacing: 8) {
                                Text("Fuel Rate")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                HStack(spacing: 6) {
                                    Text(emissionsRating)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Image(systemName: emissionsIcon)
                                        .foregroundColor(emissionsColor)
                                }
                            }
                        }
                    }

                    HStack(spacing: 16) {
                        DataCard(
                            icon: "cloud.fill",
                            title: "CO₂ Rate",
                            value: obdManager.co2KgPerHr > 0 ? String(format: "%.2f", obdManager.co2KgPerHr) : "--",
                            unit: "kg/hr",
                            color: .red
                        )

                        DataCard(
                            icon: "fuelpump.fill",
                            title: "Fuel Rate",
                            value: obdManager.fuelLph > 0 ? String(format: "%.2f", obdManager.fuelLph) : "--",
                            unit: "L/h",
                            color: .yellow
                        )
                    }
                }
                .padding(.horizontal)

                // Speed Mode Section
                VStack(spacing: 16) {
                    HStack {
                        Text("Speed Mode")
                            .font(.headline)
                        Spacer()
                        Toggle("", isOn: $obdManager.useManualSpeed)
                            .labelsHidden()
                            .onChange(of: obdManager.useManualSpeed) { newValue in
                                obdManager.toggleSpeedMode(manual: newValue)
                            }
                        Text(obdManager.useManualSpeed ? "Manual" : "Auto")
                            .font(.caption)
                            .foregroundColor(obdManager.useManualSpeed ? .orange : .blue)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(12)
                    
                    if !obdManager.useManualSpeed {
                        Button(action: {
                            if obdManager.isCollectingData {
                                obdManager.stopCollectingSpeed()
                            } else {
                                obdManager.startCollectingSpeed()
                            }
                        }) {
                            Label(obdManager.isCollectingData ? "Stop" : "Start", systemImage: obdManager.isCollectingData ? "stop.fill" : "play.fill")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(obdManager.isCollectingData ? Color.red : Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        }
                        .disabled(obdManager.connectionState != .connected)
                    }
                    
                    if obdManager.useManualSpeed {
                        HStack {
                            Image(systemName: "hand.point.right.fill")
                                .foregroundColor(.orange)
                            Text("Manual Speed:")
                                .font(.subheadline)
                            Spacer()
                            TextField("0", value: $obdManager.manualAverageSpeed, format: .number)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .frame(width: 80)
                                .onChange(of: obdManager.manualAverageSpeed) { newValue in
                                    // ✅ Trigger auto-parse when value changes
                                    obdManager.triggerManualSpeedUpdate(newValue)
                                }
                            Text("km/h")
                                .font(.caption)
                            
                            if obdManager.manualAverageSpeed > 0 {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(10)
                    }

                }
                .padding(.horizontal)

                // Action Buttons
                VStack(spacing: 12) {
                    Button(action: {
                        obdManager.resetAverageSpeed()
                    }) {
                        Label("Reset Speed Data", systemImage: "arrow.counterclockwise")
                            .font(.subheadline)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(10)
                    }
                }
                .padding(.horizontal)
                
                Spacer()
            }
        }
        .alert("Bluetooth Required", isPresented: $showBluetoothAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please enable Bluetooth in Settings to connect to the OBD device.")
        }
    }
    
    // ✅ FIXED: Emissions rating based on kg/hr
    var emissionsRating: String {
        let rate = obdManager.co2KgPerHr
        if rate == 0 { return "N/A" }
        else if rate < 10 { return "Excellent" }
        else if rate < 15 { return "Good" }
        else if rate < 20 { return "Moderate" }
        else if rate < 30 { return "High" }
        else { return "Very High" }
    }
    
    var emissionsIcon: String {
        let rate = obdManager.co2KgPerHr
        if rate == 0 { return "questionmark.circle" }
        else if rate < 10 { return "star.fill" }
        else if rate < 15 { return "checkmark.circle.fill" }
        else if rate < 20 { return "exclamationmark.circle" }
        else { return "xmark.circle.fill" }
    }
    
    var emissionsColor: Color {
        let rate = obdManager.co2KgPerHr
        if rate == 0 { return .gray }
        else if rate < 10 { return .green }
        else if rate < 15 { return .blue }
        else if rate < 20 { return .orange }
        else { return .red }
    }
    
    var statusColor: Color {
        switch obdManager.connectionState {
        case .connected: return .green
        case .failed: return .red
        case .scanning, .connecting: return .orange
        default: return .gray
        }
    }
}

// Custom Data Card Component
struct DataCard: View {
    let icon: String
    let title: String
    let value: String
    let unit: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.title3)
                Spacer()
            }
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title2)
                    .bold()
                Text(unit)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(color.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}
