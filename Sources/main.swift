import Cocoa
import Foundation

// MARK: - Constants & Binaries
let ADB_PATH: String = {
    let standardPaths = [
        "/opt/homebrew/bin/adb",
        "/usr/local/bin/adb",
        "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
        "/usr/bin/adb"
    ]
    for p in standardPaths {
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    return "adb"
}()

let SCRCPY_PATH: String = {
    let standardPaths = [
        "/opt/homebrew/bin/scrcpy",
        "/usr/local/bin/scrcpy",
        "/usr/bin/scrcpy"
    ]
    for p in standardPaths {
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    return "scrcpy"
}()

let PREFS_DIR = "\(NSHomeDirectory())/Library/Application Support/PhoneMirroring"
let PREFS_FILE = "\(PREFS_DIR)/last_device.txt"
let SETTINGS_FILE = "\(PREFS_DIR)/settings.json"

// MARK: - User Settings Model
struct AppSettings: Codable {
    var bitrate: String = "16M"
    var maxFps: String = "60"
    var videoCodec: String = "h264"
    var videoBuffer: String = "20"
    var audioBuffer: String = "50"
    var stayAwake: Bool = true
    var turnScreenOff: Bool = false
    
    static func load() -> AppSettings {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: SETTINGS_FILE)),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return s
        }
        return AppSettings()
    }
    
    func save() {
        try? FileManager.default.createDirectory(atPath: PREFS_DIR, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: URL(fileURLWithPath: SETTINGS_FILE))
        }
    }
}

// MARK: - Process Execution Helpers
func runCommand(_ launchPath: String, args: [String], timeout: TimeInterval = 10.0) -> (output: String, exitCode: Int32) {
    let p = Process()
    let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    p.standardOutput = pipe
    p.standardError = pipe
    
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(NSHomeDirectory())/Library/Android/sdk/platform-tools"
    p.environment = env
    
    do {
        try p.run()
    } catch {
        return (error.localizedDescription, 1)
    }
    
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler {
        if p.isRunning {
            p.terminate()
        }
    }
    timer.resume()
    
    p.waitUntilExit()
    timer.cancel()
    
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return (output, p.terminationStatus)
}

struct DeviceInfo {
    let serial: String
    let state: String
    let model: String
    let isWifi: Bool
    
    var name: String {
        return model.isEmpty ? serial : "\(model) (\(serial))"
    }
}

func getConnectedDevices() -> [DeviceInfo] {
    let result = runCommand(ADB_PATH, args: ["devices", "-l"], timeout: 3.0)
    var list: [DeviceInfo] = []
    
    let lines = result.output.components(separatedBy: .newlines)
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("List of devices") { continue }
        let parts = trimmed.split(separator: " ").map { String($0) }
        guard parts.count >= 2 else { continue }
        
        let serial = parts[0]
        let state = parts[1]
        
        var model = ""
        for p in parts {
            if p.hasPrefix("model:") {
                model = p.replacingOccurrences(of: "model:", with: "")
            }
        }
        
        let isWifi = serial.contains(":") || serial.contains(".")
        list.append(DeviceInfo(serial: serial, state: state, model: model, isWifi: isWifi))
    }
    return list
}

// MARK: - Application Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var deviceManagerWindow: NSWindow?
    
    var scrcpyProcess: Process?
    var activeDeviceSerial: String = ""
    var activeDeviceName: String = ""
    
    // UI Elements
    var deviceTableView: NSTableView?
    var deviceList: [DeviceInfo] = []
    var deviceStatusText: NSTextField?
    
    var qrImageView: NSImageView?
    var qrPairStatusLabel: NSTextField?
    
    var bitratePopup: NSPopUpButton?
    var fpsPopup: NSPopUpButton?
    var stayAwakeCheckbox: NSButton?
    var turnOffScreenCheckbox: NSButton?
    
    var serviceName: String = ""
    var pairingPassword: String = ""
    var mdnsPairProcess: Process?
    var settings = AppSettings.load()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // Runs primarily in Menu Bar
        setupStatusItem()
        
        // Initial auto-connect check in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.attemptInitialConnection()
        }
    }
    
    // MARK: - Menu Bar Setup
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "📱"
            button.toolTip = "Phone Mirroring"
        }
        rebuildMenu()
    }
    
    func rebuildMenu() {
        let updateUI = { [weak self] in
            guard let self = self else { return }
            let menu = NSMenu()
            
            let isMirroring = (self.scrcpyProcess?.isRunning == true)
            
            // Status header
            let statusTitle = isMirroring ? "Status: Mirroring (\(self.activeDeviceName))" : "Status: Disconnected"
            let statusMenuItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
            statusMenuItem.isEnabled = false
            menu.addItem(statusMenuItem)
            
            menu.addItem(NSMenuItem.separator())
            
            // Device Manager shortcut
            let mgrItem = NSMenuItem(title: "Open Device Manager & Settings...", action: #selector(self.openDeviceManager), keyEquivalent: "m")
            mgrItem.target = self
            menu.addItem(mgrItem)
            
            menu.addItem(NSMenuItem.separator())
            
            // Runtime Device Controls (Enabled only when mirroring)
            let controlsHeader = NSMenuItem(title: "Device Quick Controls:", action: nil, keyEquivalent: "")
            controlsHeader.isEnabled = false
            menu.addItem(controlsHeader)
            
            let screenOffItem = NSMenuItem(title: "Turn Phone Screen Off", action: #selector(self.actionScreenOff), keyEquivalent: "o")
            screenOffItem.target = self
            screenOffItem.isEnabled = isMirroring
            menu.addItem(screenOffItem)
            
            let screenOnItem = NSMenuItem(title: "Turn Phone Screen On", action: #selector(self.actionScreenOn), keyEquivalent: "O")
            screenOnItem.target = self
            screenOnItem.isEnabled = isMirroring
            menu.addItem(screenOnItem)
            
            let powerItem = NSMenuItem(title: "Power / Lock Button", action: #selector(self.actionPowerKey), keyEquivalent: "p")
            powerItem.target = self
            powerItem.isEnabled = isMirroring
            menu.addItem(powerItem)
            
            let volUpItem = NSMenuItem(title: "Volume Up", action: #selector(self.actionVolumeUp), keyEquivalent: "+")
            volUpItem.target = self
            volUpItem.isEnabled = isMirroring
            menu.addItem(volUpItem)
            
            let volDownItem = NSMenuItem(title: "Volume Down", action: #selector(self.actionVolumeDown), keyEquivalent: "-")
            volDownItem.target = self
            volDownItem.isEnabled = isMirroring
            menu.addItem(volDownItem)
            
            menu.addItem(NSMenuItem.separator())
            
            if isMirroring {
                let stopItem = NSMenuItem(title: "Disconnect & Stop Mirroring", action: #selector(self.stopScrcpy), keyEquivalent: "d")
                stopItem.target = self
                menu.addItem(stopItem)
            } else {
                let startItem = NSMenuItem(title: "Start Mirroring", action: #selector(self.startDefaultMirroring), keyEquivalent: "s")
                startItem.target = self
                menu.addItem(startItem)
            }
            
            menu.addItem(NSMenuItem.separator())
            let quitItem = NSMenuItem(title: "Quit Phone Mirroring", action: #selector(self.quitApp), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)
            
            self.statusItem.menu = menu
        }
        
        if Thread.isMainThread {
            updateUI()
        } else {
            DispatchQueue.main.async(execute: updateUI)
        }
    }
    
    // MARK: - Initial Connection Logic
    func attemptInitialConnection() {
        // 1. Direct USB or already active Wi-Fi device
        let devices = getConnectedDevices()
        if let first = devices.first {
            launchMirroring(serial: first.serial, name: first.name)
            return
        }
        
        // 2. Discover paired mDNS device
        if let mdnsTarget = discoverMdnsWirelessTarget() {
            let connectRes = runCommand(ADB_PATH, args: ["connect", mdnsTarget], timeout: 4.0)
            if connectRes.exitCode == 0 || connectRes.output.contains("connected") {
                let postDevices = getConnectedDevices()
                if let first = postDevices.first {
                    launchMirroring(serial: first.serial, name: first.name)
                    return
                }
            }
        }
        
        // 3. Fallback to cached IP with quick timeout
        if let cachedIP = try? String(contentsOfFile: PREFS_FILE, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !cachedIP.isEmpty {
            let connRes = runCommand(ADB_PATH, args: ["connect", cachedIP], timeout: 2.5)
            if connRes.exitCode == 0 && connRes.output.contains("connected to") {
                let postDevices = getConnectedDevices()
                if let first = postDevices.first {
                    launchMirroring(serial: first.serial, name: first.name)
                    return
                }
            }
        }
        
        // 4. No device reachable: Surface Device Manager cleanly
        DispatchQueue.main.async { [weak self] in
            self?.openDeviceManager()
            self?.deviceStatusText?.stringValue = "No active phone found. Connect via USB, or pair wirelessly below."
        }
    }
    
    // MARK: - mDNS Wireless Connection Helper
    func discoverMdnsWirelessTarget() -> String? {
        let browseRes = runCommand("/usr/bin/dns-sd", args: ["-B", "_adb-tls-connect._tcp", "local."], timeout: 2.5)
        let lines = browseRes.output.components(separatedBy: .newlines)
        var instanceName: String?
        for line in lines {
            if line.contains("Add") && line.contains("_adb-tls-connect._tcp") {
                let parts = line.components(separatedBy: "_adb-tls-connect._tcp.")
                if parts.count > 1 {
                    let instance = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !instance.isEmpty {
                        instanceName = instance
                        break
                    }
                }
            }
        }
        
        guard let name = instanceName else { return nil }
        let lookupRes = runCommand("/usr/bin/dns-sd", args: ["-L", name, "_adb-tls-connect._tcp", "local."], timeout: 2.5)
        for line in lookupRes.output.components(separatedBy: .newlines) {
            if line.contains("can be reached at") {
                let after = line.components(separatedBy: "can be reached at")[1]
                let tokens = after.components(separatedBy: .whitespacesAndNewlines)
                if let hostPort = tokens.first, hostPort.contains(":") {
                    return hostPort.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                }
            }
        }
        return nil
    }
    
    // MARK: - Scrcpy Process Management
    func launchMirroring(serial: String, name: String) {
        stopScrcpy()
        
        activeDeviceSerial = serial
        activeDeviceName = name
        
        var args = [
            "-s", serial,
            "--video-codec=\(settings.videoCodec)",
            "--video-bit-rate=\(settings.bitrate)",
            "--max-fps=\(settings.maxFps)",
            "--video-buffer=\(settings.videoBuffer)",
            "--audio-buffer=\(settings.audioBuffer)"
        ]
        if settings.stayAwake {
            args.append("--stay-awake")
        }
        if settings.turnScreenOff {
            args.append("--turn-screen-off")
        }
        
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SCRCPY_PATH)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(NSHomeDirectory())/Library/Android/sdk/platform-tools"
        p.environment = env
        
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.scrcpyProcess = nil
                self?.rebuildMenu()
                if let btn = self?.statusItem?.button {
                    btn.title = "📱"
                }
            }
        }
        
        do {
            try p.run()
            self.scrcpyProcess = p
            
            DispatchQueue.main.async { [weak self] in
                self?.rebuildMenu()
                if let btn = self?.statusItem?.button {
                    btn.title = "📱🟢"
                }
                self?.deviceManagerWindow?.close()
            }
        } catch {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Failed to launch scrcpy"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }
    
    @objc func stopScrcpy() {
        if let p = scrcpyProcess, p.isRunning {
            p.terminate()
        }
        scrcpyProcess = nil
        rebuildMenu()
        DispatchQueue.main.async { [weak self] in
            if let btn = self?.statusItem?.button {
                btn.title = "📱"
            }
        }
    }
    
    @objc func startDefaultMirroring() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let devices = getConnectedDevices()
            if let first = devices.first {
                self?.launchMirroring(serial: first.serial, name: first.name)
            } else {
                DispatchQueue.main.async {
                    self?.openDeviceManager()
                }
            }
        }
    }
    
    // MARK: - Device Controls via ADB Keyevents
    @objc func actionScreenOff() {
        guard !activeDeviceSerial.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            _ = runCommand(ADB_PATH, args: ["-s", self.activeDeviceSerial, "shell", "input", "keyevent", "26"])
        }
    }
    
    @objc func actionScreenOn() {
        guard !activeDeviceSerial.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            _ = runCommand(ADB_PATH, args: ["-s", self.activeDeviceSerial, "shell", "input", "keyevent", "224"])
        }
    }
    
    @objc func actionPowerKey() {
        guard !activeDeviceSerial.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            _ = runCommand(ADB_PATH, args: ["-s", self.activeDeviceSerial, "shell", "input", "keyevent", "26"])
        }
    }
    
    @objc func actionVolumeUp() {
        guard !activeDeviceSerial.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            _ = runCommand(ADB_PATH, args: ["-s", self.activeDeviceSerial, "shell", "input", "keyevent", "24"])
        }
    }
    
    @objc func actionVolumeDown() {
        guard !activeDeviceSerial.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            _ = runCommand(ADB_PATH, args: ["-s", self.activeDeviceSerial, "shell", "input", "keyevent", "25"])
        }
    }
    
    // MARK: - Device Manager & Settings Window
    @objc func openDeviceManager() {
        if let win = deviceManagerWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            refreshDeviceList()
            return
        }
        
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Phone Mirroring - Device Manager"
        win.center()
        win.isReleasedWhenClosed = false
        
        let tabView = NSTabView(frame: NSRect(x: 10, y: 10, width: 540, height: 420))
        
        // Tab 1: Devices
        let tabDevices = NSTabViewItem(identifier: "devices")
        tabDevices.label = "Devices"
        tabDevices.view = buildDevicesTabView()
        tabView.addTabViewItem(tabDevices)
        
        // Tab 2: Wireless QR Pairing
        let tabPair = NSTabViewItem(identifier: "pair")
        tabPair.label = "Wireless QR Pairing"
        tabPair.view = buildPairTabView()
        tabView.addTabViewItem(tabPair)
        
        // Tab 3: Settings
        let tabSettings = NSTabViewItem(identifier: "settings")
        tabSettings.label = "Settings"
        tabSettings.view = buildSettingsTabView()
        tabView.addTabViewItem(tabSettings)
        
        win.contentView = tabView
        deviceManagerWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        refreshDeviceList()
        generateAndDisplayQR()
    }
    
    // MARK: - Tab Views
    func buildDevicesTabView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 380))
        
        let titleLabel = NSTextField(labelWithString: "Discovered Android Devices")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        titleLabel.frame = NSRect(x: 20, y: 345, width: 300, height: 22)
        view.addSubview(titleLabel)
        
        let refreshBtn = NSButton(title: "↻ Refresh", target: self, action: #selector(refreshDeviceList))
        refreshBtn.frame = NSRect(x: 420, y: 340, width: 100, height: 28)
        view.addSubview(refreshBtn)
        
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 100, width: 500, height: 235))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        
        let table = NSTableView(frame: scroll.bounds)
        let col1 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Name"))
        col1.title = "Device"
        col1.width = 240
        table.addTableColumn(col1)
        
        let col2 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Type"))
        col2.title = "Connection"
        col2.width = 120
        table.addTableColumn(col2)
        
        let col3 = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("State"))
        col3.title = "State"
        col3.width = 100
        table.addTableColumn(col3)
        
        table.delegate = self
        table.dataSource = self
        scroll.documentView = table
        self.deviceTableView = table
        view.addSubview(scroll)
        
        let status = NSTextField(labelWithString: "Ready.")
        status.frame = NSRect(x: 20, y: 65, width: 500, height: 24)
        status.textColor = .secondaryLabelColor
        self.deviceStatusText = status
        view.addSubview(status)
        
        let mirrorBtn = NSButton(title: "▶ Connect & Mirror Selected", target: self, action: #selector(mirrorSelectedDevice))
        mirrorBtn.frame = NSRect(x: 20, y: 20, width: 230, height: 36)
        mirrorBtn.bezelColor = .systemBlue
        mirrorBtn.keyEquivalent = "\r"
        view.addSubview(mirrorBtn)
        
        let manualBtn = NSButton(title: "Manual IP Pair...", target: self, action: #selector(openManualPairDialog))
        manualBtn.frame = NSRect(x: 360, y: 20, width: 160, height: 36)
        view.addSubview(manualBtn)
        
        return view
    }
    
    @objc func refreshDeviceList() {
        deviceStatusText?.stringValue = "Scanning for ADB devices..."
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let devices = getConnectedDevices()
            DispatchQueue.main.async {
                self?.deviceList = devices
                self?.deviceTableView?.reloadData()
                if devices.isEmpty {
                    self?.deviceStatusText?.stringValue = "No devices detected. Plug via USB or pair on 'Wireless QR Pairing' tab."
                } else {
                    self?.deviceStatusText?.stringValue = "Found \(devices.count) device(s). Select a device and click Connect."
                }
            }
        }
    }
    
    @objc func mirrorSelectedDevice() {
        guard let table = deviceTableView else { return }
        let row = table.selectedRow
        if row >= 0 && row < deviceList.count {
            let dev = deviceList[row]
            deviceStatusText?.stringValue = "Connecting to \(dev.name)..."
            launchMirroring(serial: dev.serial, name: dev.name)
        } else if let first = deviceList.first {
            deviceStatusText?.stringValue = "Connecting to \(first.name)..."
            launchMirroring(serial: first.serial, name: first.name)
        } else {
            deviceStatusText?.stringValue = "No device selected."
        }
    }
    
    // MARK: - Tab 2: Wireless QR Pairing
    func buildPairTabView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 380))
        
        let titleLabel = NSTextField(labelWithString: "Pair Android Device Wirelessly")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        titleLabel.frame = NSRect(x: 20, y: 345, width: 350, height: 22)
        view.addSubview(titleLabel)
        
        let stepText = NSTextField(wrappingLabelWithString: "1. On your phone: Settings → Developer Options → Wireless Debugging.\n2. Tap 'Pair device with QR code'.\n3. Scan the code below with your phone.")
        stepText.frame = NSRect(x: 20, y: 265, width: 500, height: 65)
        stepText.textColor = .secondaryLabelColor
        view.addSubview(stepText)
        
        let imgView = NSImageView(frame: NSRect(x: 180, y: 80, width: 180, height: 180))
        imgView.imageScaling = .scaleProportionallyUpOrDown
        self.qrImageView = imgView
        view.addSubview(imgView)
        
        let status = NSTextField(labelWithString: "Broadcasting pairing service...")
        status.alignment = .center
        status.frame = NSRect(x: 20, y: 40, width: 500, height: 25)
        self.qrPairStatusLabel = status
        view.addSubview(status)
        
        let regenBtn = NSButton(title: "↻ New QR Code", target: self, action: #selector(generateAndDisplayQR))
        regenBtn.frame = NSRect(x: 200, y: 10, width: 140, height: 26)
        view.addSubview(regenBtn)
        
        return view
    }
    
    @objc func generateAndDisplayQR() {
        mdnsPairProcess?.terminate()
        mdnsPairProcess = nil
        
        serviceName = "ADB_MAC_\(Int.random(in: 1000...9999))"
        pairingPassword = String(format: "%06d", Int.random(in: 100000...999999))
        
        let payload = "WIFI:T:ADB;S:\(serviceName);P:\(pairingPassword);;"
        if let qrImage = generateQRCode(from: payload) {
            qrImageView?.image = qrImage
        }
        
        qrPairStatusLabel?.stringValue = "Waiting for phone to scan QR code..."
        startMdnsPairingListener()
    }
    
    func generateQRCode(from string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(string.data(using: .utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaled = output.transformed(by: transform)
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
    
    func startMdnsPairingListener() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        proc.arguments = ["-R", serviceName, "_adb-tls-pairing._tcp", "local", "39999"]
        
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        
        do {
            try proc.run()
            self.mdnsPairProcess = proc
        } catch {
            qrPairStatusLabel?.stringValue = "Failed to broadcast mDNS pairing: \(error.localizedDescription)"
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let listenRes = runCommand("/usr/bin/nc", args: ["-l", "39999"], timeout: 120.0)
            if !listenRes.output.isEmpty || listenRes.exitCode == 0 {
                DispatchQueue.main.async {
                    self.qrPairStatusLabel?.stringValue = "Phone paired! Connecting to active stream..."
                }
                self.completeConnectionAfterPair()
            }
        }
    }
    
    func completeConnectionAfterPair() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for _ in 0..<12 {
                if let target = self?.discoverMdnsWirelessTarget() {
                    _ = runCommand(ADB_PATH, args: ["connect", target])
                    let devices = getConnectedDevices()
                    if let first = devices.first {
                        self?.launchMirroring(serial: first.serial, name: first.name)
                        return
                    }
                }
                Thread.sleep(forTimeInterval: 0.8)
            }
            
            let post = getConnectedDevices()
            if let first = post.first {
                self?.launchMirroring(serial: first.serial, name: first.name)
            }
        }
    }
    
    // MARK: - Manual Pairing Dialog
    @objc func openManualPairDialog() {
        let alert = NSAlert()
        alert.messageText = "Manual Wi-Fi Pairing"
        alert.informativeText = "On your phone:\nSettings → Developer Options → Wireless Debugging → 'Pair device with pairing code'.\n\nEnter the Wi-Fi pairing details shown on your phone:"
        alert.alertStyle = .informational
        
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        
        let ipLabel = NSTextField(labelWithString: "IP address & Port (e.g. 192.168.1.104:37123):")
        ipLabel.frame = NSRect(x: 0, y: 55, width: 320, height: 20)
        container.addSubview(ipLabel)
        
        let ipField = NSTextField(frame: NSRect(x: 0, y: 32, width: 320, height: 22))
        ipField.placeholderString = "192.168.1.104:37123"
        container.addSubview(ipField)
        
        let codeLabel = NSTextField(labelWithString: "6-Digit Pairing Code:")
        codeLabel.frame = NSRect(x: 0, y: 15, width: 140, height: 18)
        container.addSubview(codeLabel)
        
        let codeField = NSTextField(frame: NSRect(x: 150, y: 10, width: 170, height: 22))
        codeField.placeholderString = "123456"
        container.addSubview(codeField)
        
        alert.accessoryView = container
        alert.addButton(withTitle: "Pair & Connect")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            let hostPort = ipField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hostPort.isEmpty && !code.isEmpty {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let result = runCommand(ADB_PATH, args: ["pair", hostPort, code])
                    if result.exitCode == 0 || result.output.contains("Successfully paired") {
                        if let target = self?.discoverMdnsWirelessTarget() {
                            _ = runCommand(ADB_PATH, args: ["connect", target])
                        }
                        let devices = getConnectedDevices()
                        if let first = devices.first {
                            self?.launchMirroring(serial: first.serial, name: first.name)
                        } else {
                            DispatchQueue.main.async {
                                self?.promptForConnectPort(baseIP: hostPort.components(separatedBy: ":")[0])
                            }
                        }
                    } else {
                        DispatchQueue.main.async {
                            let errAlert = NSAlert()
                            errAlert.messageText = "Pairing Failed"
                            errAlert.informativeText = result.output
                            errAlert.runModal()
                        }
                    }
                }
            }
        }
    }
    
    func promptForConnectPort(baseIP: String) {
        let alert = NSAlert()
        alert.messageText = "Pairing Succeeded!"
        alert.informativeText = "Check the main 'Wireless debugging' screen on your phone for 'IP address & Port'.\nEnter the port (or full IP:Port):"
        alert.alertStyle = .informational
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "e.g. 46145 or \(baseIP):46145"
        alert.accessoryView = input
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            var target = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !target.contains(":") && !target.isEmpty {
                target = "\(baseIP):\(target)"
            }
            if !target.isEmpty {
                _ = runCommand(ADB_PATH, args: ["connect", target])
                try? FileManager.default.createDirectory(atPath: PREFS_DIR, withIntermediateDirectories: true)
                try? target.write(toFile: PREFS_FILE, atomically: true, encoding: .utf8)
                
                Thread.sleep(forTimeInterval: 1.0)
                let connected = getConnectedDevices()
                if let dev = connected.first {
                    launchMirroring(serial: dev.serial, name: dev.name)
                }
            }
        }
    }
    
    // MARK: - Tab 3: Settings Tab
    func buildSettingsTabView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 380))
        
        let titleLabel = NSTextField(labelWithString: "Scrcpy Performance & Display Settings")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        titleLabel.frame = NSRect(x: 20, y: 345, width: 400, height: 22)
        view.addSubview(titleLabel)
        
        let bitLabel = NSTextField(labelWithString: "Video Bitrate:")
        bitLabel.frame = NSRect(x: 20, y: 290, width: 140, height: 20)
        view.addSubview(bitLabel)
        
        let bitPopup = NSPopUpButton(frame: NSRect(x: 160, y: 285, width: 160, height: 26), pullsDown: false)
        bitPopup.addItems(withTitles: ["8M", "16M (Recommended)", "24M", "32M"])
        switch settings.bitrate {
        case "8M": bitPopup.selectItem(at: 0)
        case "24M": bitPopup.selectItem(at: 2)
        case "32M": bitPopup.selectItem(at: 3)
        default: bitPopup.selectItem(at: 1)
        }
        self.bitratePopup = bitPopup
        view.addSubview(bitPopup)
        
        let fpsLabel = NSTextField(labelWithString: "Max FPS:")
        fpsLabel.frame = NSRect(x: 20, y: 250, width: 140, height: 20)
        view.addSubview(fpsLabel)
        
        let fpsPopup = NSPopUpButton(frame: NSRect(x: 160, y: 245, width: 160, height: 26), pullsDown: false)
        fpsPopup.addItems(withTitles: ["30", "60 (Recommended)", "120"])
        switch settings.maxFps {
        case "30": fpsPopup.selectItem(at: 0)
        case "120": fpsPopup.selectItem(at: 2)
        default: fpsPopup.selectItem(at: 1)
        }
        self.fpsPopup = fpsPopup
        view.addSubview(fpsPopup)
        
        let stayCheck = NSButton(checkboxWithTitle: "Prevent phone sleep (Stay Awake while connected)", target: nil, action: nil)
        stayCheck.state = settings.stayAwake ? .on : .off
        stayCheck.frame = NSRect(x: 20, y: 200, width: 450, height: 22)
        self.stayAwakeCheckbox = stayCheck
        view.addSubview(stayCheck)
        
        let offCheck = NSButton(checkboxWithTitle: "Turn phone physical screen off when mirroring starts", target: nil, action: nil)
        offCheck.state = settings.turnScreenOff ? .on : .off
        offCheck.frame = NSRect(x: 20, y: 170, width: 450, height: 22)
        self.turnOffScreenCheckbox = offCheck
        view.addSubview(offCheck)
        
        let saveBtn = NSButton(title: "Save Settings", target: self, action: #selector(saveSettingsAction))
        saveBtn.frame = NSRect(x: 20, y: 110, width: 140, height: 32)
        saveBtn.bezelColor = .systemBlue
        view.addSubview(saveBtn)
        
        return view
    }
    
    @objc func saveSettingsAction() {
        if let title = bitratePopup?.selectedItem?.title {
            settings.bitrate = title.components(separatedBy: " ").first ?? "16M"
        }
        if let fps = fpsPopup?.selectedItem?.title {
            settings.maxFps = fps.components(separatedBy: " ").first ?? "60"
        }
        settings.stayAwake = (stayAwakeCheckbox?.state == .on)
        settings.turnScreenOff = (turnOffScreenCheckbox?.state == .on)
        settings.save()
        
        let alert = NSAlert()
        alert.messageText = "Settings Saved"
        alert.informativeText = "Settings will apply on future mirror sessions."
        alert.runModal()
    }
    
    @objc func quitApp() {
        stopScrcpy()
        mdnsPairProcess?.terminate()
        NSApp.terminate(nil)
    }
}

// MARK: - NSTableView DataSource & Delegate
extension AppDelegate: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return deviceList.count
    }
    
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < deviceList.count else { return nil }
        let dev = deviceList[row]
        let colId = tableColumn?.identifier.rawValue ?? ""
        
        let text = NSTextField(labelWithString: "")
        text.isEditable = false
        text.isBordered = false
        text.backgroundColor = .clear
        
        if colId == "Name" {
            text.stringValue = dev.name
            text.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        } else if colId == "Type" {
            text.stringValue = dev.isWifi ? "📶 Wi-Fi" : "🔌 USB"
        } else if colId == "State" {
            text.stringValue = dev.state
            text.textColor = (dev.state == "device") ? .systemGreen : .systemOrange
        }
        return text
    }
}

// Clean up saved window state that macOS uses for crash recovery prompts
let appSupport = "\(NSHomeDirectory())/Library/Saved Application State/com.erkam.phonemirroring.savedState"
try? FileManager.default.removeItem(atPath: appSupport)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
