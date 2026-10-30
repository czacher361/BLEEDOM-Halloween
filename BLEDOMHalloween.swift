import SwiftUI
import CoreBluetooth

@main
struct BLEDOMHalloweenApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct RGBColor: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var color: Color {
        Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)
    }
}

final class BLEController: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Bluetooth initializing…"
    @Published var devices: [DiscoveredDevice] = []
    @Published var connectedName: String?
    @Published var isScanning = false

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var scanTimer: Timer?

    private let serviceUUID = CBUUID(string: "FFF0")
    private let writeUUID = CBUUID(string: "FFF3")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            status = "Bluetooth ready"
        case .poweredOff:
            status = "Turn on Bluetooth"
        case .unauthorized:
            status = "Allow Bluetooth access in Settings"
        case .unsupported:
            status = "Bluetooth LE unsupported"
        case .resetting:
            status = "Bluetooth resetting…"
        case .unknown:
            status = "Bluetooth state unknown"
        @unknown default:
            status = "Bluetooth unavailable"
        }
    }

    func scan() {
        guard central.state == .poweredOn else {
            status = "Turn on Bluetooth first"
            return
        }
        devices.removeAll()
        isScanning = true
        status = "Searching for BLEDOM controllers…"
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.central.stopScan()
            self.isScanning = false
            self.status = self.devices.isEmpty ? "No devices found. Move closer and scan again." : "Tap BLEDOM06 to connect"
        }
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
    }

    func connect(_ peripheral: CBPeripheral) {
        stopScan()
        status = "Connecting…"
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        if let p = connectedPeripheral { central.cancelPeripheralConnection(p) }
        connectedPeripheral = nil
        writeCharacteristic = nil
        connectedName = nil
        status = "Disconnected"
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                       advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Unknown BLE device"
        if !devices.contains(where: { $0.peripheral.identifier == peripheral.identifier }) {
            devices.append(DiscoveredDevice(peripheral: peripheral, displayName: name))
            devices.sort { $0.displayName < $1.displayName }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        peripheral.delegate = self
        connectedName = peripheral.name ?? "BLEDOM"
        status = "Connected. Discovering controls…"
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        status = "Connection failed: \(error?.localizedDescription ?? "unknown error")"
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectedPeripheral = nil
        writeCharacteristic = nil
        connectedName = nil
        status = "Disconnected"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            status = "Service discovery failed: \(error.localizedDescription)"
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            status = "FFF0 service not found"
            return
        }
        peripheral.discoverCharacteristics([writeUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            status = "Characteristic discovery failed: \(error.localizedDescription)"
            return
        }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == writeUUID }) else {
            status = "FFF3 write characteristic not found"
            return
        }
        writeCharacteristic = characteristic
        status = "Ready — connected to \(peripheral.name ?? "BLEDOM")"
        sendPower(true)
    }

    func sendColor(r: UInt8, g: UInt8, b: UInt8, brightness: Int) {
        guard let p = connectedPeripheral, let c = writeCharacteristic else {
            status = "Connect to BLEDOM06 first"
            return
        }
        // Scale RGB by brightness; color frame for Lotus Lantern / ELK-BLEDOM.
        let level = max(0, min(100, brightness))
        let rr = UInt8(Int(r) * level / 100)
        let gg = UInt8(Int(g) * level / 100)
        let bb = UInt8(Int(b) * level / 100)
        let frame: [UInt8] = [0x7E, 0x07, 0x05, 0x03, rr, gg, bb, 0x10, 0xEF]
        p.writeValue(Data(frame), for: c, type: .withoutResponse)
    }

    func sendPower(_ on: Bool) {
        guard let p = connectedPeripheral, let c = writeCharacteristic else { return }
        let frame: [UInt8] = on
            ? [0x7E, 0x04, 0x04, 0xF0, 0x00, 0x01, 0xFF, 0x00, 0xEF]
            : [0x7E, 0x04, 0x04, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xEF]
        p.writeValue(Data(frame), for: c, type: .withoutResponse)
    }
}

struct ContentView: View {
    @StateObject private var ble = BLEController()
    @State private var orange = RGBColor(r: 255, g: 69, b: 0)
    @State private var purple = RGBColor(r: 128, g: 0, b: 255)
    @State private var brightness = 80.0
    @State private var interval = 1.0
    @State private var isAlternating = false
    @State private var showingOrange = true
    @State private var cycleTimer: Timer?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(ble.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    colorCard(title: "Orange", color: orange.color, hex: "#FF4500")
                    colorCard(title: "Purple", color: purple.color, hex: "#8000FF")
                }

                HStack(spacing: 12) {
                    Button(isAlternating ? "Stop cycle" : "Start orange ↔ purple") {
                        toggleCycle()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(ble.connectedName == nil)

                    Button("Send orange") {
                        stopCycle()
                        showingOrange = true
                        sendCurrent()
                    }
                    .buttonStyle(.bordered)
                    .disabled(ble.connectedName == nil)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Brightness")
                        Spacer()
                        Text("\(Int(brightness))%")
                            .monospacedDigit()
                    }
                    Slider(value: $brightness, in: 5...100, step: 1)
                        .onChange(of: brightness) { _, _ in
                            if ble.connectedName != nil && !isAlternating { sendCurrent() }
                        }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Color change")
                        Spacer()
                        Text(interval == 0.5 ? "Fast" : interval == 1 ? "1 sec" : "2 sec")
                    }
                    Slider(value: $interval, in: 0.5...2, step: 0.5)
                }

                Group {
                    if ble.connectedName == nil {
                        Button(ble.isScanning ? "Scanning…" : "Scan for BLEDOM06") {
                            ble.scan()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(ble.isScanning)
                        if !ble.devices.isEmpty {
                            
    List(ble.devices, id: \.identifier) { device in
                                    Button {
    ble.connect(device)
                                } label: {
                                    HStack {
                                        Text(device.name ?? "BLE device")
                                        Spacer()
                                        if device.name?.localizedCaseInsensitiveContains("bledom") == true {
                                            Text("Likely controller")
                                                .font(.caption)
                                                .foregroundStyle(.green)
                                        }
                                    }
                                }
                            }
                            .frame(minHeight: 120, maxHeight: 180)
                        }
                    } else {
                        Button("Disconnect \(ble.connectedName ?? "device")") {
                            stopCycle()
                            ble.disconnect()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Spacer(minLength: 0)
                Text("Designed for BLEDOM06 • Bluetooth only")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Halloween Lights")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Power") { ble.sendPower(true) }
                        .disabled(ble.connectedName == nil)
                }
            }
        
        .onDisappear { stopCycle() }
    }

    private func colorCard(title: String, color: Color, hex: String) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 12)
                .fill(color)
                .frame(height: 56)
            Text(title).font(.headline)
            Text(hex).font(.caption.monospaced())
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func toggleCycle() {
        if isAlternating {
            stopCycle()
            return
        }
        isAlternating = true
        showingOrange = true
        sendCurrent()
        cycleTimer?.invalidate()
        cycleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            showingOrange.toggle()
            sendCurrent()
        }
    }

    private func stopCycle() {
        isAlternating = false
        cycleTimer?.invalidate()
        cycleTimer = nil
    }

    private func sendCurrent() {
        let c = showingOrange ? orange : purple
        ble.sendColor(r: c.r, g: c.g, b: c.b, brightness: Int(brightness))
    }
}
struct DiscoveredDevice: Identifiable {
    let peripheral: CBPeripheral
    let displayName: String

    var id: UUID {
        peripheral.identifier
    }
}
