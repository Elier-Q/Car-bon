import SwiftUI

struct ContentView: View {
    @StateObject private var manager = OBDManager()
    @State private var showBluetoothAlert = false

    var body: some View {
        VStack(alignment: .leading) {
            Text("VEEPEAK BLE Bridge")
                .font(.title2)
                .padding(.bottom)

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
            .padding(.bottom)

            Text("Status: \(manager.connectionState.rawValue)")
                .font(.subheadline)
                .foregroundColor(manager.connectionState == .connected ? .green : .orange)
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
        .alert(isPresented: $showBluetoothAlert) {
            Alert(
                title: Text("Bluetooth Required"),
                message: Text("Please enable Bluetooth and grant permissions in Settings."),
                dismissButton: .default(Text("OK"))
            )
        }
        .onAppear {
            if !manager.bluetoothEnabled {
                showBluetoothAlert = true
            }
        }
    }
}
