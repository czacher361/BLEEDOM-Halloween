import SwiftUI
import CoreBluetooth

@main
struct BLEDOMHalloweenApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct RGBColor: Equatable, Identifiable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    var id: String {
        "\(r)-\(g)-\(b)"
    }

    var color: Color {
        Color(
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255
        )
    }

    var hex: String {
        String(format: "#%02X%02X%02X", r, g, b)
    }
}

struct LightPreset: Identifiable {
    let name: String
    let colors: [RGBColor]

    var id: String { name }

    static let all: [LightPreset] = [
        .init(
            name: "🎃 Halloween",
            colors: [
                .init(r: 184, g: 32, b: 0),
                .init(r: 128, g: 0, b: 255)
            ]
        ),
        .init(
            name: "🇺🇸 Patriotic",
            colors: [
                .init(r: 255, g: 0, b: 0),
                .init(r: 255, g: 255, b: 255),
                .init(r: 0, g: 0, b: 255)
            ]
        ),
        .init(
            name: "❤️ Valentine's Day",
            colors: [
                .init(r: 255, g: 0, b: 0),
                .init(r: 255, g: 40, b: 120),
                .init(r: 255, g: 255, b: 255)
            ]
        ),
        .init(
            name: "🐻 Montana Griz",
            colors: [
                .init(r: 117, g: 0, b: 20),
                .init(r: 210, g: 210, b: 210)
            ]
        ),
        .init(
            name: "🎨 Custom",
            colors: []
        )
    ]
}
struct DiscoveredDevice: Identifiable {
    let peripheral: CBPeripheral
    let displayName: String

    var id: UUID { peripheral.identifier }
}

final class BLEController: NSObject, ObservableObject,
    CBCentralManagerDelegate, CBPeripheralDelegate {

    @Published var status = "Bluetooth initializing…"
    @Published var devices: [DiscoveredDevice] = []
    @Published var connectedName: String?
    @Published var isScanning = false
    @Published var ready = false

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
        default:
            status = "Bluetooth unavailable"
        }
    }

    func scan() {
        guard central.state == .poweredOn else {
            status = "Turn on Bluetooth first"
            return
        }

        devices = []
        isScanning = true
        status = "Searching for BLEDOM controllers…"

        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(
            withTimeInterval: 12,
            repeats: false
        ) { [weak self] _ in
            guard let self else { return }
            self.central.stopScan()
            self.isScanning = false
            self.status = self.devices.isEmpty
                ? "No devices found. Move closer and scan again."
                : "Tap your BLEDOM controller to connect"
        }
    }

    func stopScan() {
        scanTimer?.invalidate()
        central.stopScan()
        isScanning = false
    }

    func connect(_ peripheral: CBPeripheral) {
        stopScan()
        status = "Connecting…"
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        if let p = connectedPeripheral {
            central.cancelPeripheralConnection(p)
        }

        connectedPeripheral = nil
        writeCharacteristic = nil
        connectedName = nil
        ready = false
        status = "Disconnected"
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Unknown BLE device"

        if !devices.contains(where: { $0.id == peripheral.identifier }) {
            devices.append(
                DiscoveredDevice(
                    peripheral: peripheral,
                    displayName: name
                )
            )
            devices.sort { $0.displayName < $1.displayName }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        connectedPeripheral = peripheral
        peripheral.delegate = self
        connectedName = peripheral.name ?? "BLEDOM"
        status = "Connected. Discovering controls…"
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        status = "Connection failed: \(error?.localizedDescription ?? "unknown error")"
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        connectedPeripheral = nil
        writeCharacteristic = nil
        connectedName = nil
        ready = false
        status = "Disconnected"
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        if let error {
            status = "Service discovery failed: \(error.localizedDescription)"
            return
        }

        guard let service = peripheral.services?.first(
            where: { $0.uuid == serviceUUID }
        ) else {
            status = "FFF0 service not found"
            return
        }

        peripheral.discoverCharacteristics([writeUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            status = "Characteristic discovery failed: \(error.localizedDescription)"
            return
        }

        guard let characteristic = service.characteristics?.first(
            where: { $0.uuid == writeUUID }
        ) else {
            status = "FFF3 write characteristic not found"
            return
        }

        writeCharacteristic = characteristic
        ready = true
        status = "Ready — connected to \(peripheral.name ?? "BLEDOM")"
        sendPower(true)
    }

    func sendColor(_ color: RGBColor, brightness: Int) {
        guard let p = connectedPeripheral,
              let c = writeCharacteristic else { return }

        let level = max(0, min(100, brightness))
        let rr = UInt8(Int(color.r) * level / 100)
        let gg = UInt8(Int(color.g) * level / 100)
        let bb = UInt8(Int(color.b) * level / 100)

        let frame: [UInt8] = [
            0x7E, 0x07, 0x05, 0x03,
            rr, gg, bb, 0x10, 0xEF
        ]

        p.writeValue(Data(frame), for: c, type: .withoutResponse)
    }

    func sendPower(_ on: Bool) {
        guard let p = connectedPeripheral,
              let c = writeCharacteristic else { return }

        let frame: [UInt8] = on
            ? [0x7E, 0x04, 0x04, 0xF0, 0x00, 0x01, 0xFF, 0x00, 0xEF]
            : [0x7E, 0x04, 0x04, 0x00, 0x00, 0x00, 0xFF, 0x00, 0xEF]

        p.writeValue(Data(frame), for: c, type: .withoutResponse)
    }
}
final class LightingController: ObservableObject {
    @Published var selectedPreset = 0
    @Published var brightness = 100
    @Published var speed = 2.0
    @Published var isPlaying = false
    @Published var isSolid = false
    @Published var solidColorIndex = 0

    @Published var customColors: [RGBColor] = [
        RGBColor(r: 255, g: 0, b: 0),
        RGBColor(r: 0, g: 0, b: 255)
    ]

    @Published var scheduleEnabled = false
    @Published var onTime = Calendar.current.date(
        from: DateComponents(hour: 17, minute: 0)
    ) ?? Date()
    @Published var offTime = Calendar.current.date(
        from: DateComponents(hour: 23, minute: 0)
    ) ?? Date()

    private var effectTimer: Timer?
    private var scheduleTimer: Timer?
    private var colorIndex = 0
    private var lastScheduleEvent = ""

    var activeColors: [RGBColor] {
        if selectedPreset == 4 {
            return customColors
        }
        return LightPreset.all[selectedPreset].colors
    }

    func start(using ble: BLEController) {
        guard ble.ready else { return }

        stop()
        isPlaying = true
        colorIndex = 0
        ble.sendPower(true)

        sendNextColor(using: ble)

        if !isSolid {
            effectTimer = Timer.scheduledTimer(
                withTimeInterval: speed,
                repeats: true
            ) { [weak self, weak ble] _ in
                guard let self, let ble else { return }
                self.sendNextColor(using: ble)
            }
        }
    }

    func stop() {
        effectTimer?.invalidate()
        effectTimer = nil
        isPlaying = false
    }

    func turnOff(using ble: BLEController) {
        stop()
        ble.sendPower(false)
    }

    func restart(using ble: BLEController) {
        if isPlaying {
            start(using: ble)
        }
    }

    func sendNextColor(using ble: BLEController) {
        let colors = activeColors
        guard !colors.isEmpty else { return }

        if isSolid {
            let index = min(solidColorIndex, colors.count - 1)
            ble.sendColor(colors[index], brightness: brightness)
        } else {
            ble.sendColor(
                colors[colorIndex % colors.count],
                brightness: brightness
            )
            colorIndex += 1
        }
    }

    func beginSchedule(using ble: BLEController) {
        scheduleTimer?.invalidate()

        scheduleTimer = Timer.scheduledTimer(
            withTimeInterval: 15,
            repeats: true
        ) { [weak self, weak ble] _ in
            guard let self, let ble else { return }
            self.checkSchedule(using: ble)
        }

        checkSchedule(using: ble)
    }

    private func checkSchedule(using ble: BLEController) {
        guard scheduleEnabled, ble.ready else { return }

        let calendar = Calendar.current
        let now = Date()
        let currentMinutes = calendar.component(.hour, from: now) * 60
            + calendar.component(.minute, from: now)

        let onMinutes = calendar.component(.hour, from: onTime) * 60
            + calendar.component(.minute, from: onTime)

        let offMinutes = calendar.component(.hour, from: offTime) * 60
            + calendar.component(.minute, from: offTime)

        let shouldBeOn: Bool

        if onMinutes < offMinutes {
            shouldBeOn = currentMinutes >= onMinutes
                && currentMinutes < offMinutes
        } else {
            shouldBeOn = currentMinutes >= onMinutes
                || currentMinutes < offMinutes
        }

        let event = "\(calendar.startOfDay(for: now))-\(shouldBeOn)"

        if event != lastScheduleEvent {
            lastScheduleEvent = event

            if shouldBeOn {
                start(using: ble)
            } else {
                turnOff(using: ble)
            }
        }
    }
}
struct ContentView: View {
    @StateObject private var ble = BLEController()
    @StateObject private var lighting = LightingController()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {

                    // Bluetooth connection
                    GroupBox("Bluetooth Connection") {
                        VStack(spacing: 12) {
                            Text(ble.status)
                                .font(.subheadline)

                            if ble.ready {
                                Text("🟢 Connected")
                                    .foregroundColor(.green)

                                Button("Disconnect") {
                                    lighting.stop()
                                    ble.disconnect()
                                }
                            } else {
                                Button("Scan for Lights") {
                                    ble.scan()
                                }

                                ForEach(ble.devices) { device in
                                    Button(device.displayName) {
                                        ble.connect(device.peripheral)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // Holiday presets
                    GroupBox("Holiday & Team Colors") {
                        VStack(spacing: 12) {
                            Picker("Lighting Theme",
                                   selection: $lighting.selectedPreset) {
                                ForEach(0..<LightPreset.all.count,
                                        id: \.self) { index in
                                    Text(LightPreset.all[index].name)
                                        .tag(index)
                                }
                            }
                            .pickerStyle(.menu)

                            HStack {
                                ForEach(lighting.activeColors) { color in
                                    Circle()
                                        .fill(color.color)
                                        .frame(width: 35, height: 35)
                                }
                            }

                            Button("Apply Theme") {
                                lighting.start(using: ble)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    // Lighting effects
                    GroupBox("Lighting Controls") {
                        VStack(spacing: 15) {
                            Toggle("Solid Color", isOn: $lighting.isSolid)

                            if lighting.isSolid {
                                Picker("Color",
                                       selection: $lighting.solidColorIndex) {
                                    ForEach(
                                        0..<lighting.activeColors.count,
                                        id: \.self
                                    ) { index in
                                        Text("Color \(index + 1)")
                                            .tag(index)
                                    }
                                }
                            }

                            VStack {
                                Text("Brightness: \(lighting.brightness)%")
                                Slider(
                                    value: Binding(
                                        get: { Double(lighting.brightness) },
                                        set: {
                                            lighting.brightness = Int($0)
                                        }
                                    ),
                                    in: 0...100
                                )
                            }

                            VStack {
                                Text(
                                    String(
                                        format: "Color Change Speed: %.1f seconds",
                                        lighting.speed
                                    )
                                )

                                Slider(
                                    value: $lighting.speed,
                                    in: 0.5...10,
                                    step: 0.5
                                )
                            }

                            HStack {
                                Button("▶ Start") {
                                    lighting.start(using: ble)
                                }
                                .buttonStyle(.borderedProminent)

                                Button("■ Stop") {
                                    lighting.stop()
                                }

                                Button("Power Off") {
                                    lighting.turnOff(using: ble)
                                }
                                .tint(.red)
                            }

                            Button("Apply Updated Settings") {
                                lighting.start(using: ble)
                            }
                        }
                    }

                    // Custom colors
                    GroupBox("Custom Colors") {
                        VStack(spacing: 12) {
                            ForEach(
                                lighting.customColors.indices,
                                id: \.self
                            ) { index in
                                ColorPicker(
                                    "Custom Color \(index + 1)",
                                    selection: Binding(
                                        get: {
                                            lighting.customColors[index].color
                                        },
                                        set: { newColor in
                                            let uiColor = UIColor(newColor)
                                            var red: CGFloat = 0
                                            var green: CGFloat = 0
                                            var blue: CGFloat = 0
                                            var alpha: CGFloat = 0

                                            uiColor.getRed(
                                                &red,
                                                green: &green,
                                                blue: &blue,
                                                alpha: &alpha
                                            )

                                            lighting.customColors[index] =
                                                RGBColor(
                                                    r: UInt8(red * 255),
                                                    g: UInt8(green * 255),
                                                    b: UInt8(blue * 255)
                                                )
                                        }
                                    )
                                )
                            }

                            Button("Use Custom Colors") {
                                lighting.selectedPreset = 4
                                lighting.start(using: ble)
                            }
                        }
                    }

                    // Daily schedule
                    GroupBox("Daily Schedule") {
                        VStack(spacing: 12) {
                            Toggle(
                                "Enable Daily Schedule",
                                isOn: $lighting.scheduleEnabled
                            )

                            DatePicker(
                                "Lights On",
                                selection: $lighting.onTime,
                                displayedComponents: .hourAndMinute
                            )

                            DatePicker(
                                "Lights Off",
                                selection: $lighting.offTime,
                                displayedComponents: .hourAndMinute
                            )

                            Text(
                                "Schedule requires the app to remain active. "
                                + "Keep your Lotus Lantern timer for "
                                + "reliable automatic operation."
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Holiday Lights")
            .onAppear {
                lighting.beginSchedule(using: ble)
            }
            .onDisappear {
                lighting.stop()
            }
        }
    }
}
