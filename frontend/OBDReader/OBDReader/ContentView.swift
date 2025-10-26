//ContentView.swift
import SwiftUI

struct ContentView: View {
    @StateObject private var manager = OBDManager()
    @State private var showBluetoothAlert = false
    @State private var speedInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("VEEPEAK BLE Bridge")
                .font(.title2)
                .padding(.bottom)

            // Connection Button
            HStack {
                Button(action: {
                    if manager.bluetoothEnabled {
                        manager.startConnection()
                    } else {
                        showBluetoothAlert = true
                    }
                }) {
                    Label("Connect", systemImage: "bolt.horizontal.circle")
                        .font(.headline)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.blue.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
            }

            Text("Status: \(manager.connectionState.rawValue)")
                .font(.subheadline)
                .foregroundColor(manager.connectionState == .connected ? .green : .orange)
            
            Divider()
            
            // Speed Input Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Average Speed")
                    .font(.headline)
                
                Picker("Speed Source", selection: $manager.useManualSpeed) {
                    Text("Auto Calculate").tag(false)
                    Text("Manual Input").tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: manager.useManualSpeed) { newValue in
                    manager.toggleSpeedMode(manual: newValue)
                }
                
                if manager.useManualSpeed {
                    // Manual Input Mode
                    HStack {
                        TextField("Enter speed", text: $speedInput)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.decimalPad)
                            .frame(width: 100)
                        
                        Text("km/h")
                        
                        Button("Set") {
                            if let speed = Double(speedInput) {
                                manager.setManualAverageSpeed(speed)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    
                    if manager.manualAverageSpeed > 0 {
                        Text("✓ Set to: \(String(format: "%.1f", manager.manualAverageSpeed)) km/h")
                            .foregroundColor(.green)
                            .font(.subheadline)
                    }
                } else {
                    // Auto Calculate Mode
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Current:")
                            Spacer()
                            Text("\(String(format: "%.1f", manager.currentSpeed)) km/h")
                                .bold()
                        }
                        
                        HStack {
                            Text("Average:")
                            Spacer()
                            Text("\(String(format: "%.1f", manager.averageSpeed)) km/h")
                                .bold()
                                .foregroundColor(.blue)
                        }
                        
                        Text("\(manager.speedSamples.count) samples")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack {
                            Button(manager.isCollectingData ? "Stop" : "Start") {
                                if manager.isCollectingData {
                                    manager.stopCollectingSpeed()
                                } else {
                                    manager.startCollectingSpeed()
                                }
                            }
                            .buttonStyle(.bordered)
                            
                            Button("Reset") {
                                manager.resetAverageSpeed()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                
                // Display used value
                HStack {
                    Image(systemName: "gauge.medium")
                        .foregroundColor(.blue)
                    Text("Used for calculations:")
                        .font(.caption)
                    Spacer()
                    Text("\(String(format: "%.1f", manager.displayedAverageSpeed)) km/h")
                        .bold()
                        .foregroundColor(.blue)
                }
                .padding(8)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
            
            Divider()

            // Log ScrollView
            Text("Log")
                .font(.headline)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(manager.log.enumerated()), id: \.offset) { index, logLine in
                        Text(logLine)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding()
        .alert("Bluetooth Required", isPresented: $showBluetoothAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please enable Bluetooth in Settings to connect to the OBD device.")
        }
    }
}
