import SwiftUI
import CoreBluetooth
import UIKit

// Holiday Lights — reviewed candidate for BLEDOM06; hardware testing still required.
// Custom color animations are phone-driven and stop when iOS suspends the app.

struct RGBColor: Codable, Equatable, Identifiable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var id: String { "\(r)-\(g)-\(b)" }
    var color: Color { Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255) }
}

struct LightPreset: Identifiable {
    let name: String
    let colors: [RGBColor]
    var id: String { name }
    static let all: [LightPreset] = [
        .init(name: "🎃 Halloween", colors: [.init(r:184,g:32,b:0),.init(r:128,g:0,b:255)]),
        .init(name: "🐻 Montana Griz", colors: [.init(r:117,g:0,b:20),.init(r:210,g:210,b:210)]),
        .init(name: "🇺🇸 Patriotic", colors: [.init(r:255,g:0,b:0),.init(r:255,g:255,b:255),.init(r:0,g:0,b:255)]),
        .init(name: "❤️ Valentine's", colors: [.init(r:255,g:0,b:0),.init(r:255,g:40,b:120),.init(r:255,g:255,b:255)]),
        .init(name: "🎄 Christmas", colors: [.init(r:255,g:0,b:0),.init(r:0,g:180,b:0),.init(r:255,g:255,b:255)]),
        .init(name: "☘️ St. Patrick's", colors: [.init(r:0,g:180,b:50),.init(r:255,g:180,b:0)]),
        .init(name: "🎆 New Year's", colors: [.init(r:255,g:190,b:0),.init(r:255,g:255,b:255),.init(r:128,g:0,b:255)]),
        .init(name: "🎨 Custom", colors: [])
    ]
}

struct DiscoveredDevice: Identifiable {
    let peripheral: CBPeripheral
    let displayName: String
    var id: UUID { peripheral.identifier }
}

final class BLEController: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published private(set) var status = "Initializing Bluetooth…"
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var connectedName: String?
    @Published private(set) var ready = false
    @Published private(set) var scanning = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var scanTimer: Timer?
    private var reconnectID: UUID?
    private var manualDisconnect = false
    private var pendingWrites: [[UInt8]] = []
    private var reconnectAttempts = 0
    private var waitingForAcknowledgement = false
    private var connectionInProgress = false
    private var reconnectGeneration = 0
    private let serviceUUID = CBUUID(string: "FFF0")
    private let writeUUID = CBUUID(string: "FFF3")

    override init() {
        super.init()
        if let saved = UserDefaults.standard.string(forKey: "lastPeripheralID") { reconnectID = UUID(uuidString: saved) }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            status = "Bluetooth ready"
            if let id = reconnectID { reconnect(to: id) }
        case .poweredOff: status = "Turn on Bluetooth"
        case .unauthorized: status = "Bluetooth permission required"
        case .unsupported: status = "Bluetooth LE unavailable"
        default: status = "Bluetooth unavailable"
        }
    }

    func scan() {
        guard central.state == .poweredOn else { status = "Turn on Bluetooth first"; return }
        stopScan()
        devices = []
        scanning = true
        status = "Searching for lights…"
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            self?.stopScan()
            if self?.ready == false { self?.status = "Choose a controller, or scan again" }
        }
    }

    func stopScan() {
        scanTimer?.invalidate()
        scanTimer = nil
        if central.state == .poweredOn { central.stopScan() }
        scanning = false
    }

    func connect(_ p: CBPeripheral) {
        stopScan()
        manualDisconnect = false
        reconnectGeneration += 1
        connectionInProgress = true
        peripheral = p
        reconnectID = p.identifier
        UserDefaults.standard.set(p.identifier.uuidString, forKey: "lastPeripheralID")
        status = "Connecting…"
        central.connect(p, options: nil)
    }

    func disconnect() {
        manualDisconnect = true
        reconnectGeneration += 1
        connectionInProgress = false
        waitingForAcknowledgement = false
        reconnectID = nil
        UserDefaults.standard.removeObject(forKey: "lastPeripheralID")
        pendingWrites.removeAll()
        ready = false
        writeCharacteristic = nil
        connectedName = nil
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        status = "Disconnected"
    }

    private func reconnect(to id: UUID) {
        guard central.state == .poweredOn, !manualDisconnect, !connectionInProgress, peripheral == nil else { return }
        if let p = central.retrievePeripherals(withIdentifiers: [id]).first { connect(p) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Unknown device"
        if !devices.contains(where: { $0.id == p.identifier }) {
            devices.append(.init(peripheral: p, displayName: name))
            devices.sort { $0.displayName < $1.displayName }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        peripheral = p
        connectionInProgress = false
        p.delegate = self
        connectedName = p.name ?? "BLEDOM"
        reconnectAttempts = 0
        status = "Discovering controls…"
        p.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        status = "Connection failed: \(error?.localizedDescription ?? "unknown")"
        peripheral = nil
        connectionInProgress = false
        waitingForAcknowledgement = false
        ready = false
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        peripheral = nil
        connectionInProgress = false
        waitingForAcknowledgement = false
        writeCharacteristic = nil
        connectedName = nil
        ready = false
        pendingWrites.removeAll()
        status = "Disconnected"
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !manualDisconnect, reconnectID != nil else { return }
        reconnectAttempts = min(reconnectAttempts + 1, 6)
        let delay = min(Double(1 << reconnectAttempts), 30.0)
        let generation = reconnectGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.reconnectGeneration, let id = self.reconnectID else { return }
            self.reconnect(to: id)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { status = "Service error: \(error.localizedDescription)"; return }
        guard let service = p.services?.first(where: { $0.uuid == serviceUUID }) else {
            status = "FFF0 service unavailable"; return
        }
        p.discoverCharacteristics([writeUUID], for: service)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error { status = "Characteristic error: \(error.localizedDescription)"; return }
        guard let c = service.characteristics?.first(where: { $0.uuid == writeUUID }) else {
            status = "FFF3 characteristic unavailable"; return
        }
        guard c.properties.contains(.writeWithoutResponse) || c.properties.contains(.write) else {
            status = "Controller does not support writes"; return
        }
        writeCharacteristic = c
        waitingForAcknowledgement = false
        ready = true
        status = "Ready — \(p.name ?? "BLEDOM")"
        flushWrites()
    }

    private func write(_ bytes: [UInt8]) {
        guard ready else { return }
        pendingWrites.append(bytes)
        // Prevent an unbounded queue if Bluetooth temporarily stops accepting writes.
        if pendingWrites.count > 20 { pendingWrites.removeFirst(pendingWrites.count - 20) }
        flushWrites()
    }

    private func flushWrites() {
        guard ready, let p = peripheral, let c = writeCharacteristic, !waitingForAcknowledgement else { return }
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        while !pendingWrites.isEmpty {
            if type == .withoutResponse && !p.canSendWriteWithoutResponse { break }
            let bytes = pendingWrites.removeFirst()
            if type == .withResponse { waitingForAcknowledgement = true }
            p.writeValue(Data(bytes), for: c, type: type)
            if type == .withResponse { break }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        flushWrites()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        waitingForAcknowledgement = false
        if let error { status = "Bluetooth write error: \(error.localizedDescription)" }
        flushWrites()
    }

    func sendColor(_ color: RGBColor, brightness: Int) {
        let level = max(0, min(100, brightness))
        let r = UInt8(Int(color.r) * level / 100)
        let g = UInt8(Int(color.g) * level / 100)
        let b = UInt8(Int(color.b) * level / 100)
        write([0x7E,0x07,0x05,0x03,r,g,b,0x10,0xEF])
    }

    func sendPower(_ on: Bool) {
        write(on ? [0x7E,0x04,0x04,0xF0,0x00,0x01,0xFF,0x00,0xEF]
                 : [0x7E,0x04,0x04,0x00,0x00,0x00,0xFF,0x00,0xEF])
    }
}

final class LightingController: ObservableObject {
    @Published var selectedPreset: Int { didSet { persist() } }
    @Published var brightness: Int { didSet { persist() } }
    @Published var speed: Double { didSet { persist() } }
    @Published var solid: Bool { didSet { persist() } }
    @Published var solidIndex: Int { didSet { persist() } }
    @Published private(set) var playing = false
    @Published var customColors: [RGBColor] { didSet { persist() } }
    @Published var scheduleEnabled: Bool { didSet { persist() } }
    @Published var onTime: Date { didSet { persist() } }
    @Published var offTime: Date { didSet { persist() } }
    @Published var favoritePreset: Int { didSet { persist() } }

    private var effectTimer: Timer?
    private var scheduleTimer: Timer?
    private var index = 0
    private var lastScheduleState: Bool?
    private let defaults = UserDefaults.standard

    init() {
        selectedPreset = min(max(UserDefaults.standard.integer(forKey: "preset"), 0), LightPreset.all.count-1)
        brightness = UserDefaults.standard.object(forKey: "brightness") == nil ? 100 : min(max(UserDefaults.standard.integer(forKey: "brightness"),0),100)
        speed = UserDefaults.standard.object(forKey: "speed") == nil ? 2 : min(max(UserDefaults.standard.double(forKey: "speed"),0.5),10)
        favoritePreset = min(max(UserDefaults.standard.integer(forKey: "favorite"),0),LightPreset.all.count-1)
        solid = UserDefaults.standard.bool(forKey: "solid")
        solidIndex = max(0, UserDefaults.standard.integer(forKey: "solidIndex"))
        scheduleEnabled = UserDefaults.standard.bool(forKey: "schedule")
        onTime = UserDefaults.standard.object(forKey: "onTime") as? Date ?? Calendar.current.date(from: DateComponents(hour:17,minute:0)) ?? Date()
        offTime = UserDefaults.standard.object(forKey: "offTime") as? Date ?? Calendar.current.date(from: DateComponents(hour:23,minute:0)) ?? Date()
        if let data = UserDefaults.standard.data(forKey: "custom"), let saved = try? JSONDecoder().decode([RGBColor].self, from: data), !saved.isEmpty {
            customColors = Array(saved.prefix(8))
        } else { customColors = [.init(r:255,g:0,b:0),.init(r:0,g:0,b:255)] }
    }

    private func persist() {
        defaults.set(selectedPreset, forKey: "preset")
        defaults.set(brightness, forKey: "brightness")
        defaults.set(speed, forKey: "speed")
        defaults.set(solid, forKey: "solid")
        defaults.set(solidIndex, forKey: "solidIndex")
        defaults.set(favoritePreset, forKey: "favorite")
        defaults.set(scheduleEnabled, forKey: "schedule")
        defaults.set(onTime, forKey: "onTime")
        defaults.set(offTime, forKey: "offTime")
        defaults.set(try? JSONEncoder().encode(customColors), forKey: "custom")
    }

    var colors: [RGBColor] { selectedPreset == LightPreset.all.count-1 ? customColors : LightPreset.all[selectedPreset].colors }

    func start(_ ble: BLEController) {
        guard ble.ready, !colors.isEmpty else { return }
        stop()
        playing = true
        index = 0
        ble.sendPower(true)
        next(ble)
        if !solid {
            effectTimer = Timer.scheduledTimer(withTimeInterval: speed, repeats: true) { [weak self, weak ble] _ in
                guard let self = self, let ble = ble, ble.ready else { return }
                self.next(ble)
            }
        }
    }

    private func next(_ ble: BLEController) {
        guard !colors.isEmpty else { return }
        let position = solid ? min(max(solidIndex,0),colors.count-1) : index % colors.count
        ble.sendColor(colors[position], brightness: brightness)
        if !solid { index += 1 }
    }

    func stop() { effectTimer?.invalidate(); effectTimer = nil; playing = false }
    func powerOff(_ ble: BLEController) { stop(); ble.sendPower(false) }
    func apply(_ ble: BLEController) { if playing { start(ble) } }

    func beginSchedule(_ ble: BLEController) {
        scheduleTimer?.invalidate()
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self, weak ble] _ in
            guard let self = self, let ble = ble else { return }
            self.checkSchedule(ble)
        }
        checkSchedule(ble)
    }

    func checkSchedule(_ ble: BLEController) {
        guard scheduleEnabled, ble.ready else { lastScheduleState = nil; return }
        let cal = Calendar.current
        let minutes = { (date: Date) -> Int in cal.component(.hour,from:date)*60 + cal.component(.minute,from:date) }
        let now = minutes(Date()), on = minutes(onTime), off = minutes(offTime)
        guard on != off else { return }
        let active = on < off ? (now >= on && now < off) : (now >= on || now < off)
        if lastScheduleState != active {
            lastScheduleState = active
            if active { start(ble) } else { powerOff(ble) }
        }
    }
    func scheduleChanged(_ ble: BLEController) { lastScheduleState = nil; checkSchedule(ble) }
    func suspendAnimation() { effectTimer?.invalidate(); effectTimer = nil; playing = false }
}

@main
struct BLEDOMHalloweenApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @StateObject private var ble = BLEController()
    @StateObject private var lights = LightingController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    GroupBox("Connection") {
                        VStack(spacing: 10) {
                            Text(ble.status).font(.subheadline)
                            if ble.ready {
                                Label("Connected", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                                Button("Disconnect") { lights.stop(); ble.disconnect() }
                            } else {
                                Button(ble.scanning ? "Scanning…" : "Scan for Lights") { ble.scan() }
                                    .buttonStyle(.borderedProminent)
                                ForEach(ble.devices) { device in
                                    Button(device.displayName) { ble.connect(device.peripheral) }
                                }
                            }
                        }.frame(maxWidth: .infinity)
                    }
                    GroupBox("Themes") {
                        VStack(spacing: 12) {
                            Picker("Theme", selection: $lights.selectedPreset) {
                                ForEach(LightPreset.all.indices, id: \.self) { i in
                                    Text(LightPreset.all[i].name).tag(i)
                                }
                            }.pickerStyle(.menu)
                            HStack(spacing: 10) {
                                ForEach(lights.colors) { color in
                                    Circle().fill(color.color).frame(width: 34,height: 34)
                                }
                            }
                            Button("Apply Theme") { lights.start(ble) }.buttonStyle(.borderedProminent)
                            HStack {
                                Button("★ Save Favorite") { lights.favoritePreset = lights.selectedPreset }
                                Button("★ Load Favorite") { lights.selectedPreset = lights.favoritePreset; lights.start(ble) }
                            }.font(.subheadline)
                        }.frame(maxWidth: .infinity)
                    }
                    GroupBox("Effects") {
                        VStack(spacing: 12) {
                            Toggle("Solid Color", isOn: $lights.solid)
                            if lights.solid {
                                Picker("Color", selection: $lights.solidIndex) {
                                    ForEach(lights.colors.indices, id: \.self) { i in Text("Color \(i+1)").tag(i) }
                                }
                            }
                            Text("Brightness: \(lights.brightness)%")
                            Slider(value: Binding(get: { Double(lights.brightness) }, set: { lights.brightness = Int($0) }), in: 0...100)
                            Text(String(format: "Change every %.1f seconds", lights.speed))
                            Slider(value: $lights.speed, in: 0.5...10, step: 0.5)
                            HStack {
                                Button("Start") { lights.start(ble) }.buttonStyle(.borderedProminent)
                                Button("Stop") { lights.stop() }
                                Button("Power Off") { lights.powerOff(ble) }.tint(.red)
                            }
                            Button("Apply Updated Settings") { lights.start(ble) }
                        }
                    }
                    GroupBox("Custom Colors") {
                        VStack(spacing: 12) {
                            ForEach(lights.customColors.indices, id: \.self) { i in
                                ColorPicker("Color \(i+1)", selection: Binding(
                                    get: { lights.customColors[i].color },
                                    set: { newColor in
                                        let ui = UIColor(newColor)
                                        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                                        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
                                        lights.customColors[i] = RGBColor(r: UInt8(min(255,max(0,Int((r*255).rounded())))),g: UInt8(min(255,max(0,Int((g*255).rounded())))),b: UInt8(min(255,max(0,Int((b*255).rounded())))))
                                    }
                                ))
                            }
                            HStack {
                                Button("Add Color") { if lights.customColors.count < 8 { lights.customColors.append(.init(r:255,g:255,b:255)) } }
                                Button("Remove Last") { if lights.customColors.count > 1 { lights.customColors.removeLast() } }
                            }
                            Button("Play Custom") { lights.selectedPreset = LightPreset.all.count-1; lights.start(ble) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    GroupBox("Daily Schedule (Phone-dependent)") {
                        VStack(spacing: 10) {
                            Toggle("Enable Schedule", isOn: $lights.scheduleEnabled)
                            DatePicker("On", selection: $lights.onTime, displayedComponents: .hourAndMinute)
                            DatePicker("Off", selection: $lights.offTime, displayedComponents: .hourAndMinute)
                            Text("This schedule only works while iOS lets the app run and Bluetooth is connected. For dependable unattended on/off times, keep using Lotus Lantern's controller timer.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Text("Custom color changes are sent by your phone. iOS may pause them when the app is backgrounded. Built-in controller Jump/Fade effects are different and have not yet been verified for custom colors.")
                        .font(.caption).foregroundColor(.secondary)
                }.padding()
            }
            .navigationTitle("Holiday Lights")
            .onAppear { lights.beginSchedule(ble) }
            .onChange(of: lights.selectedPreset) { _ in lights.apply(ble) }
            .onChange(of: lights.solid) { _ in lights.apply(ble) }
            .onChange(of: lights.solidIndex) { _ in lights.apply(ble) }
            .onChange(of: lights.brightness) { _ in lights.apply(ble) }
            .onChange(of: lights.speed) { _ in lights.apply(ble) }
            .onChange(of: lights.scheduleEnabled) { _ in lights.scheduleChanged(ble) }
            .onChange(of: lights.onTime) { _ in lights.scheduleChanged(ble) }
            .onChange(of: lights.offTime) { _ in lights.scheduleChanged(ble) }
            .onChange(of: ble.ready) { ready in if ready { lights.scheduleChanged(ble) } else { lights.stop() } }
            .onChange(of: scenePhase) { phase in
                if phase == .background { lights.suspendAnimation() }
                if phase == .active { lights.scheduleChanged(ble) }
            }
        }
    }
}
