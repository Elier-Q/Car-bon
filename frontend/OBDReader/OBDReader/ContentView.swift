import SwiftUI

struct ContentView: View {
    @StateObject var obdManager = OBDManager()

    var body: some View {
        VStack(spacing: 20) {
            Text("OBD-II Connection: \(obdManager.connectionState.rawValue)")
                .font(.headline)

            VStack(alignment: .leading, spacing: 5) {
                Text("RPM Hex: \(obdManager.lastRPMHex)")
                Text("Engine Load Hex: \(obdManager.lastLoadHex)")
                Text("Intake Manifold Hex: \(obdManager.lastManifoldHex)")
                Text("Speed: \(String(format: "%.1f", obdManager.displayedAverageSpeed)) km/h")
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)

            HStack(spacing: 20) {
                Button("Start Collecting Speed") {
                    obdManager.startCollectingSpeed()
                }
                Button("Stop") {
                    obdManager.stopCollectingSpeed()
                }
            }

            HStack(spacing: 20) {
                Button("Send Data to Backend") {
                    obdManager.sendAllOBDData()
                }
                Button("Reset Speed Data") {
                    obdManager.resetAverageSpeed()
                }
            }

            Toggle("Use Manual Speed", isOn: $obdManager.useManualSpeed)
                .padding()

            if obdManager.useManualSpeed {
                HStack {
                    Text("Manual Speed:")
                    TextField("km/h", value: $obdManager.manualAverageSpeed, format: .number)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }
                .padding()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(obdManager.log.indices, id: \.self) { idx in
                        Text(obdManager.log[idx])
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
            }
            .frame(maxHeight: 250)
            .padding()
            .background(Color.gray.opacity(0.05))
            .cornerRadius(8)

            Spacer()
        }
        .padding()
        .onAppear {
            obdManager.startConnection()
        }
    }
}
