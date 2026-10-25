import Cocoa
import CoreImage

// MARK: - Paths & Config
let ADB_PATH: String = {
    let candidates = [
        "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
        "/opt/homebrew/bin/adb",
        "/usr/local/bin/adb"
    ]
    for path in candidates {
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
    }
    return "adb"
}()

let SCRCPY_PATH: String = {
    let candidates = [
        "/opt/homebrew/bin/scrcpy",
        "/usr/local/bin/scrcpy"
    ]
    for path in candidates {
        if FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
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
    var stayAwake: Bool = true
    var turnScreenOff: Bool = true
    var videoBuffer: String = "20"
    var audioBuffer: String = "50"
    
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

// MARK: - Command Line Execution Helper
func runCommand(_ launchPath: String, args: [String], timeout: TimeInterval = 10.0) -> (output: String, exitCode: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(NSHomeDirectory())/Library/Android/sdk/platform-tools"
    process.environment = env
    
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    
    do {
        try process.run()
        
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            return ("Timeout", -1)
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), process.terminationStatus)
    } catch {
        return (error.localizedDescription, 1)
    }
}

func getConnectedDevices() -> [(serial: String, name: String)] {
    let result = runCommand(ADB_PATH, args: ["devices", "-l"], timeout: 3.0)
    var list: [(serial: String, name: String)] = []
    let lines = result.output.components(separatedBy: "\n")
    for line in lines {
        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if parts.count >= 2 && parts[1] == "device" {
            let serial = parts[0]
            var displayName = serial
            if let modelPart = parts.first(where: { $0.hasPrefix("model:") }) {
                displayName = modelPart.replacingOccurrences(of: "model:", with: "").replacingOccurrences(of: "_", with: " ")
            }
            list.append((serial, displayName))
        }
    }
    return list
}

// MARK: - App Delegate & Menu Bar Controller
class AppDelegate: NSObject, NSApplicationDelegate, NSTabViewDelegate {
    var statusItem: NSStatusItem!
    var deviceManagerWindow: NSWindow?
    
    // Scrcpy Managed Child Process
    var scrcpyProcess: Process?
    var activeDeviceSerial: String?
    var activeDeviceName: String = "No Device"
    
    // UI Elements in Device Manager
    var deviceStatusText: NSTextField!
    var qrImageView: NSImageView!
    var pairCodeLabel: NSTextField!
    var qrSpinner: NSProgressIndicator!
    var qrStatusLabel: NSTextField!
    
    var bitratePopUp: NSPopUpButton!
    var fpsPopUp: NSPopUpButton!
    var stayAwakeCheck: NSButton!
    var screenOffCheck: NSButton!
    
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
        let menu = NSMenu()
        
        let isMirroring = (scrcpyProcess?.isRunning == true)
        
        // Status header
        let statusTitle = isMirroring ? "Status: Mirroring (\(activeDeviceName))" : "Status: Disconnected"
        let statusMenuItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Device Manager shortcut
        let mgrItem = NSMenuItem(title: "Open Device Manager & Settings...", action: #selector(openDeviceManager), keyEquivalent: "m")
        mgrItem.target = self
        menu.addItem(mgrItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Runtime Device Controls (Enabled only when mirroring)
        let controlsHeader = NSMenuItem(title: "Device Quick Controls:", action: nil, keyEquivalent: "")
        controlsHeader.isEnabled = false
        menu.addItem(controlsHeader)
        
        let screenOffItem = NSMenuItem(title: "Turn Phone Screen Off", action: #selector(actionScreenOff), keyEquivalent: "o")
        screenOffItem.target = self
        screenOffItem.isEnabled = isMirroring
        menu.addItem(screenOffItem)
        
        let screenOnItem = NSMenuItem(title: "Turn Phone Screen On", action: #selector(actionScreenOn), keyEquivalent: "O")
        screenOnItem.target = self
        screenOnItem.isEnabled = isMirroring
        menu.addItem(screenOnItem)
        
        let powerItem = NSMenuItem(title: "Power / Lock Button", action: #selector(actionPowerKey), keyEquivalent: "p")
        powerItem.target = self
        powerItem.isEnabled = isMirroring
        menu.addItem(powerItem)
        
        let volUpItem = NSMenuItem(title: "Volume Up", action: #selector(actionVolumeUp), keyEquivalent: "+")
        volUpItem.target = self
        volUpItem.isEnabled = isMirroring
        menu.addItem(volUpItem)
        
        let volDownItem = NSMenuItem(title: "Volume Down", action: #selector(actionVolumeDown), keyEquivalent: "-")
        volDownItem.target = self
        volDownItem.isEnabled = isMirroring
        menu.addItem(volDownItem)
        
        menu.addItem(NSMenuItem.separator())
        
        if isMirroring {
            let stopItem = NSMenuItem(title: "Disconnect & Stop Mirroring", action: #selector(stopScrcpy), keyEquivalent: "d")
            stopItem.target = self
            menu.addItem(stopItem)
        } else {
            let startItem = NSMenuItem(title: "Start Mirroring", action: #selector(startDefaultMirroring), keyEquivalent: "s")
            startItem.target = self
            menu.addItem(startItem)
        }
        
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit Phone Mirroring", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem.menu = menu
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
    
    func discoverMdnsWirelessTarget() -> String? {
        let browseProcess = Process()
        browseProcess.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        browseProcess.arguments = ["-B", "_adb-tls-connect._tcp"]
        let pipe = Pipe()
        browseProcess.standardOutput = pipe
        
        try? browseProcess.run()
        Thread.sleep(forTimeInterval: 1.2)
        browseProcess.terminate()
        
        let browseData = pipe.fileHandleForReading.readDataToEndOfFile()
        let browseOut = String(data: browseData, encoding: .utf8) ?? ""
        
        var instances: [String] = []
        for line in browseOut.components(separatedBy: "\n") {
            if line.contains("Add") && line.contains("_adb-tls-connect._tcp.") {
                let parts = line.components(separatedBy: "_adb-tls-connect._tcp.")
                if parts.count > 1 {
                    let inst = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !inst.isEmpty && !instances.contains(inst) {
                        instances.append(inst)
                    }
                }
            }
        }
        
        for inst in instances {
            let lookup = Process()
            lookup.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
            lookup.arguments = ["-L", inst, "_adb-tls-connect._tcp"]
            let lookupPipe = Pipe()
            lookup.standardOutput = lookupPipe
            
            try? lookup.run()
            Thread.sleep(forTimeInterval: 1.0)
            lookup.terminate()
            
            let data = lookupPipe.fileHandleForReading.readDataToEndOfFile()
            let lookupOut = String(data: data, encoding: .utf8) ?? ""
            
            if let range = lookupOut.range(of: "can be reached at ") {
                let after = String(lookupOut[range.upperBound...])
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
                if let btn = self?.statusItem.button {
                    btn.title = "📱"
                }
            }
        }
        
        do {
            try p.run()
            self.scrcpyProcess = p
            
            DispatchQueue.main.async { [weak self] in
                self?.rebuildMenu()
                if let btn = self?.statusItem.button {
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
        if let btn = statusItem.button {
            btn.title = "📱"
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
        guard let serial = activeDeviceSerial else { return }
        // Sends Power key to turn screen off if on
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runCommand(ADB_PATH, args: ["-s", serial, "shell", "input", "keyevent", "26"])
        }
    }
    
    @objc func actionScreenOn() {
        guard let serial = activeDeviceSerial else { return }
        // Wakes screen
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runCommand(ADB_PATH, args: ["-s", serial, "shell", "input", "keyevent", "224"])
        }
    }
    
    @objc func actionPowerKey() {
        guard let serial = activeDeviceSerial else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runCommand(ADB_PATH, args: ["-s", serial, "shell", "input", "keyevent", "26"])
        }
    }
    
    @objc func actionVolumeUp() {
        guard let serial = activeDeviceSerial else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runCommand(ADB_PATH, args: ["-s", serial, "shell", "input", "keyevent", "24"])
        }
    }
    
    @objc func actionVolumeDown() {
        guard let serial = activeDeviceSerial else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = runCommand(ADB_PATH, args: ["-s", serial, "shell", "input", "keyevent", "25"])
        }
    }
    
    @objc func quitApp() {
        stopScrcpy()
        NSApp.terminate(nil)
    }
    
    // MARK: - Device Manager & Settings Window
    @objc func openDeviceManager() {
        if let win = deviceManagerWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            refreshDevicesList()
            return
        }
        
        let width: CGFloat = 540
        let height: CGFloat = 620
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        
        let window = NSWindow(contentRect: rect,
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Phone Mirroring — Device Manager & Settings"
        window.center()
        window.isReleasedWhenClosed = false
        
        let visualEffect = NSVisualEffectView(frame: rect)
        visualEffect.material = .underWindowBackground
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        window.contentView = visualEffect
        
        // Tab View
        let tabView = NSTabView(frame: NSRect(x: 20, y: 20, width: width - 40, height: height - 40))
        tabView.delegate = self
        
        // Tab 1: Devices
        let tabDevices = NSTabViewItem(identifier: "devices")
        tabDevices.label = "Devices"
        tabDevices.view = buildDevicesTabView(width: width - 40, height: height - 80)
        tabView.addTabViewItem(tabDevices)
        
        // Tab 2: Wireless QR Pairing
        let tabQR = NSTabViewItem(identifier: "qr")
        tabQR.label = "Wireless QR Pairing"
        tabQR.view = buildQRTabView(width: width - 40, height: height - 80)
        tabView.addTabViewItem(tabQR)
        
        // Tab 3: Settings
        let tabSettings = NSTabViewItem(identifier: "settings")
        tabSettings.label = "Settings"
        tabSettings.view = buildSettingsTabView(width: width - 40, height: height - 80)
        tabView.addTabViewItem(tabSettings)
        
        visualEffect.addSubview(tabView)
        self.deviceManagerWindow = window
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        refreshDevicesList()
        generateNewQRPairing()
    }
    
    // MARK: - Tab Views Builder
    func buildDevicesTabView(width: CGFloat, height: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        
        let title = NSTextField(labelWithString: "Connected & Paired Phones")
        title.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        title.frame = NSRect(x: 10, y: height - 40, width: width - 20, height: 26)
        view.addSubview(title)
        
        deviceStatusText = NSTextField(wrappingLabelWithString: "Checking for active connections...")
        deviceStatusText.font = NSFont.systemFont(ofSize: 13)
        deviceStatusText.textColor = .secondaryLabelColor
        deviceStatusText.frame = NSRect(x: 10, y: height - 90, width: width - 20, height: 40)
        view.addSubview(deviceStatusText)
        
        let refreshBtn = NSButton(title: "🔄 Scan for Devices", target: self, action: #selector(refreshDevicesList))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.frame = NSRect(x: 10, y: height - 130, width: 160, height: 30)
        view.addSubview(refreshBtn)
        
        let mirrorBtn = NSButton(title: "🚀 Start Mirroring Now", target: self, action: #selector(startDefaultMirroring))
        mirrorBtn.bezelStyle = .rounded
        mirrorBtn.frame = NSRect(x: 180, y: height - 130, width: 180, height: 30)
        view.addSubview(mirrorBtn)
        
        let box = NSBox(frame: NSRect(x: 10, y: 70, width: width - 20, height: height - 210))
        box.title = "Help & Quick Actions"
        let boxView = NSView(frame: box.bounds)
        
        let tip1 = NSTextField(wrappingLabelWithString: "• USB: Plug in any phone with USB Debugging enabled for instant mirror.")
        tip1.font = NSFont.systemFont(ofSize: 12)
        tip1.frame = NSRect(x: 15, y: 110, width: width - 50, height: 22)
        boxView.addSubview(tip1)
        
        let tip2 = NSTextField(wrappingLabelWithString: "• Wireless: Switch to the 'Wireless QR Pairing' tab to pair a new phone.")
        tip2.font = NSFont.systemFont(ofSize: 12)
        tip2.frame = NSRect(x: 15, y: 80, width: width - 50, height: 22)
        boxView.addSubview(tip2)
        
        let tip3 = NSTextField(wrappingLabelWithString: "• Menu Bar: Once mirroring starts, manage phone screen and volume from the 📱 icon at the top right of your Mac.")
        tip3.font = NSFont.systemFont(ofSize: 12)
        tip3.frame = NSRect(x: 15, y: 35, width: width - 50, height: 36)
        boxView.addSubview(tip3)
        
        box.contentView = boxView
        view.addSubview(box)
        
        let manualBtn = NSButton(title: "Connect via IP & Port Manually...", target: self, action: #selector(openManualPairDialog))
        manualBtn.bezelStyle = .rounded
        manualBtn.frame = NSRect(x: 10, y: 20, width: 260, height: 32)
        view.addSubview(manualBtn)
        
        return view
    }
    
    @objc func refreshDevicesList() {
        deviceStatusText?.stringValue = "Scanning..."
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let devices = getConnectedDevices()
            DispatchQueue.main.async {
                if devices.isEmpty {
                    self?.deviceStatusText?.stringValue = "No devices detected.\nPlug in a USB cable or connect via Wireless Debugging."
                } else {
                    let formatted = devices.map { "• \($0.name) (\($0.serial))" }.joined(separator: "\n")
                    self?.deviceStatusText?.stringValue = "Active Devices:\n\(formatted)"
                }
            }
        }
    }
    
    func buildQRTabView(width: CGFloat, height: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        
        let title = NSTextField(labelWithString: "Pair Android Wirelessly via QR")
        title.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        title.alignment = .center
        title.frame = NSRect(x: 10, y: height - 35, width: width - 20, height: 26)
        view.addSubview(title)
        
        let sub = NSTextField(wrappingLabelWithString: "On phone: Settings → Developer options → Wireless debugging → 'Pair device with QR code'")
        sub.font = NSFont.systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .center
        sub.frame = NSRect(x: 20, y: height - 70, width: width - 40, height: 28)
        view.addSubview(sub)
        
        let qrBox = NSBox(frame: NSRect(x: (width - 250) / 2, y: height - 330, width: 250, height: 250))
        qrBox.boxType = .custom
        qrBox.fillColor = .white
        qrBox.cornerRadius = 12
        qrBox.borderWidth = 1
        qrBox.borderColor = NSColor.separatorColor
        view.addSubview(qrBox)
        
        qrImageView = NSImageView(frame: NSRect(x: 10, y: 10, width: 230, height: 230))
        qrBox.addSubview(qrImageView)
        
        pairCodeLabel = NSTextField(labelWithString: "Code: Generating...")
        pairCodeLabel.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        pairCodeLabel.alignment = .center
        pairCodeLabel.frame = NSRect(x: 10, y: height - 365, width: width - 20, height: 22)
        view.addSubview(pairCodeLabel)
        
        qrSpinner = NSProgressIndicator(frame: NSRect(x: (width - 20) / 2, y: height - 395, width: 20, height: 20))
        qrSpinner.style = .spinning
        qrSpinner.startAnimation(nil)
        view.addSubview(qrSpinner)
        
        qrStatusLabel = NSTextField(labelWithString: "Awaiting phone scan...")
        qrStatusLabel.font = NSFont.systemFont(ofSize: 11)
        qrStatusLabel.textColor = .secondaryLabelColor
        qrStatusLabel.alignment = .center
        qrStatusLabel.frame = NSRect(x: 10, y: height - 425, width: width - 20, height: 20)
        view.addSubview(qrStatusLabel)
        
        let genBtn = NSButton(title: "Regenerate QR Code", target: self, action: #selector(generateNewQRPairing))
        genBtn.bezelStyle = .rounded
        genBtn.frame = NSRect(x: (width - 200) / 2, y: 40, width: 200, height: 32)
        view.addSubview(genBtn)
        
        return view
    }
    
    func buildSettingsTabView(width: CGFloat, height: CGFloat) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        
        let title = NSTextField(labelWithString: "Mirroring Performance & Stream Settings")
        title.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        title.frame = NSRect(x: 20, y: height - 40, width: width - 40, height: 26)
        view.addSubview(title)
        
        // Bitrate
        let bitLabel = NSTextField(labelWithString: "Video Bitrate:")
        bitLabel.font = NSFont.systemFont(ofSize: 13)
        bitLabel.frame = NSRect(x: 20, y: height - 85, width: 140, height: 20)
        view.addSubview(bitLabel)
        
        bitratePopUp = NSPopUpButton(frame: NSRect(x: 160, y: height - 88, width: 180, height: 26))
        bitratePopUp.addItems(withTitles: ["8 Mbps (Fastest / Low Wi-Fi)", "16 Mbps (Recommended / Balanced)", "24 Mbps (Ultra Crisp 2K/4K)"])
        if settings.bitrate == "8M" { bitratePopUp.selectItem(at: 0) }
        else if settings.bitrate == "24M" { bitratePopUp.selectItem(at: 2) }
        else { bitratePopUp.selectItem(at: 1) }
        view.addSubview(bitratePopUp)
        
        // Max FPS
        let fpsLabel = NSTextField(labelWithString: "Max Framerate:")
        fpsLabel.font = NSFont.systemFont(ofSize: 13)
        fpsLabel.frame = NSRect(x: 20, y: height - 125, width: 140, height: 20)
        view.addSubview(fpsLabel)
        
        fpsPopUp = NSPopUpButton(frame: NSRect(x: 160, y: height - 128, width: 180, height: 26))
        fpsPopUp.addItems(withTitles: ["30 FPS (Battery saver)", "60 FPS (Recommended)", "120 FPS (High Refresh Rate)"])
        if settings.maxFps == "30" { fpsPopUp.selectItem(at: 0) }
        else if settings.maxFps == "120" { fpsPopUp.selectItem(at: 2) }
        else { fpsPopUp.selectItem(at: 1) }
        view.addSubview(fpsPopUp)
        
        // Stay awake
        stayAwakeCheck = NSButton(checkboxWithTitle: "Keep phone awake while mirroring (--stay-awake)", target: nil, action: nil)
        stayAwakeCheck.state = settings.stayAwake ? .on : .off
        stayAwakeCheck.frame = NSRect(x: 20, y: height - 170, width: 400, height: 22)
        view.addSubview(stayAwakeCheck)
        
        // Turn screen off
        screenOffCheck = NSButton(checkboxWithTitle: "Turn physical phone screen off while mirroring (--turn-screen-off)", target: nil, action: nil)
        screenOffCheck.state = settings.turnScreenOff ? .on : .off
        screenOffCheck.frame = NSRect(x: 20, y: height - 200, width: 450, height: 22)
        view.addSubview(screenOffCheck)
        
        // Save button
        let saveBtn = NSButton(title: "Save Preferences", target: self, action: #selector(savePreferences))
        saveBtn.bezelStyle = .rounded
        saveBtn.frame = NSRect(x: 20, y: 30, width: 160, height: 32)
        view.addSubview(saveBtn)
        
        return view
    }
    
    @objc func savePreferences() {
        let bitIndex = bitratePopUp.indexOfSelectedItem
        settings.bitrate = (bitIndex == 0) ? "8M" : ((bitIndex == 2) ? "24M" : "16M")
        
        let fpsIndex = fpsPopUp.indexOfSelectedItem
        settings.maxFps = (fpsIndex == 0) ? "30" : ((fpsIndex == 2) ? "120" : "60")
        
        settings.stayAwake = (stayAwakeCheck.state == .on)
        settings.turnScreenOff = (screenOffCheck.state == .on)
        settings.save()
        
        let alert = NSAlert()
        alert.messageText = "Preferences Saved"
        alert.informativeText = "Settings updated for future mirroring sessions."
        alert.runModal()
    }
    
    // MARK: - QR Code Generation & mDNS Handshake
    @objc func generateNewQRPairing() {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let randomSuffix = String((0..<8).map { _ in chars.randomElement()! })
        serviceName = "adb-pair-\(randomSuffix)"
        pairingPassword = String((0..<6).map { _ in "0123456789".randomElement()! })
        
        let payload = "WIFI:T:ADB;S:\(serviceName);P:\(pairingPassword);;"
        pairCodeLabel?.stringValue = "Pairing Code: \(pairingPassword)"
        
        if let qr = generateQRImage(from: payload) {
            qrImageView?.image = NSImage(cgImage: qr, size: NSSize(width: 230, height: 230))
        }
        
        listenForMdnsPairing()
    }
    
    func generateQRImage(from string: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(string.data(using: .utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
    
    func listenForMdnsPairing() {
        mdnsPairProcess?.terminate()
        
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/dns-sd")
        p.arguments = ["-B", "_adb-tls-pairing._tcp"]
        let pipe = Pipe()
        p.standardOutput = pipe
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                if let sName = self?.serviceName, output.contains(sName) {
                    DispatchQueue.main.async {
                        self?.qrStatusLabel?.stringValue = "Phone paired! Connecting to stream..."
                        self?.completeConnectionAfterPair()
                    }
                }
            }
        }
        
        do {
            try p.run()
            mdnsPairProcess = p
        } catch {
            print("Failed to run dns-sd:", error)
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
        codeLabel.frame = NSRect(x: 0, y: 15, width: 150, height: 16)
        container.addSubview(codeLabel)
        
        let codeField = NSTextField(frame: NSRect(x: 160, y: 10, width: 160, height: 22))
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
                            errAlert.alertStyle = .warning
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
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
