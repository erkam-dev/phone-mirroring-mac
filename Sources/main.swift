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

let PREFS_FILE = "\(NSHomeDirectory())/Library/Application Support/PhoneMirroring/last_device.txt"

// MARK: - Process Execution Helpers
func runCommand(_ launchPath: String, args: [String]) -> (output: String, exitCode: Int32) {
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
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (out.trimmingCharacters(in: .whitespacesAndNewlines), process.terminationStatus)
    } catch {
        return (error.localizedDescription, 1)
    }
}

func getConnectedDevices() -> [String] {
    let result = runCommand(ADB_PATH, args: ["devices"])
    var devices: [String] = []
    let lines = result.output.components(separatedBy: "\n")
    for line in lines {
        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if parts.count >= 2 && parts[1] == "device" {
            devices.append(parts[0])
        }
    }
    return devices
}

func startScrcpy(serial: String? = nil) {
    DispatchQueue.main.async {
        var args = [
            "--video-codec=h264",
            "--video-bit-rate=16M",
            "--max-fps=60",
            "--video-buffer=20",
            "--audio-buffer=50",
            "--stay-awake",
            "--turn-screen-off"
        ]
        if let s = serial {
            args.append(contentsOf: ["-s", s])
        }
        
        let p = Process()
        p.executableURL = URL(fileURLWithPath: SCRCPY_PATH)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(NSHomeDirectory())/Library/Android/sdk/platform-tools"
        p.environment = env
        
        do {
            try p.run()
            exit(0)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to launch scrcpy"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            exit(1)
        }
    }
}

// MARK: - Auto-Connect Discovered Wireless Devices via mDNS
func autoConnectMdnsWirelessDevices() -> Bool {
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
        
        // Find reachability: e.g. "can be reached at Android_84QIQDCK.local.:46145"
        if let range = lookupOut.range(of: "can be reached at ") {
            let after = String(lookupOut[range.upperBound...])
            let tokens = after.components(separatedBy: .whitespacesAndNewlines)
            if let hostPort = tokens.first, hostPort.contains(":") {
                let cleanHP = hostPort.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let connRes = runCommand(ADB_PATH, args: ["connect", hostPort])
                if connRes.exitCode == 0 || connRes.output.contains("connected") {
                    try? FileManager.default.createDirectory(atPath: "\(NSHomeDirectory())/Library/Application Support/PhoneMirroring", withIntermediateDirectories: true)
                    try? cleanHP.write(toFile: PREFS_FILE, atomically: true, encoding: .utf8)
                    return true
                }
            }
        }
    }
    return false
}

// MARK: - Main Application Delegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var statusLabel: NSTextField!
    var qrImageView: NSImageView!
    var pairCodeLabel: NSTextField!
    var progressIndicator: NSProgressIndicator!
    
    var serviceName: String = ""
    var pairingPassword: String = ""
    var mdnsProcess: Process?
    var isChecking = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        
        // 1. Check if device is already connected
        let devices = getConnectedDevices()
        if let first = devices.first {
            startScrcpy(serial: first)
            return
        }
        
        // 2. Try mDNS discovery of already paired wireless devices
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if autoConnectMdnsWirelessDevices() {
                let post = getConnectedDevices()
                if let dev = post.first {
                    startScrcpy(serial: dev)
                    return
                }
            }
            
            // 3. Try saved target IP
            if let saved = try? String(contentsOfFile: PREFS_FILE, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
                _ = runCommand(ADB_PATH, args: ["connect", saved])
                let postSaved = getConnectedDevices()
                if let dev = postSaved.first {
                    startScrcpy(serial: dev)
                    return
                }
            }
            
            // 4. Otherwise, show QR pairing window
            DispatchQueue.main.async {
                self?.setupWindow()
            }
        }
    }
    
    func setupWindow() {
        let width: CGFloat = 520
        let height: CGFloat = 640
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered,
                          defer: false)
        window.title = "Phone Mirroring — Wireless Connect"
        window.center()
        window.isReleasedWhenClosed = false
        
        let visualEffect = NSVisualEffectView(frame: rect)
        visualEffect.material = .underWindowBackground
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        window.contentView = visualEffect
        
        let title = NSTextField(labelWithString: "Connect Your Android Phone")
        title.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        title.alignment = .center
        title.frame = NSRect(x: 20, y: height - 55, width: width - 40, height: 30)
        visualEffect.addSubview(title)
        
        let subtitle = NSTextField(wrappingLabelWithString: "On Android: Settings → Developer options → Wireless debugging → 'Pair device with QR code'\nScan this QR code with your phone camera:")
        subtitle.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.frame = NSRect(x: 35, y: height - 105, width: width - 70, height: 40)
        visualEffect.addSubview(subtitle)
        
        let qrBox = NSBox(frame: NSRect(x: (width - 290) / 2, y: height - 415, width: 290, height: 290))
        qrBox.boxType = .custom
        qrBox.fillColor = .white
        qrBox.cornerRadius = 16
        qrBox.borderWidth = 1
        qrBox.borderColor = NSColor.separatorColor
        visualEffect.addSubview(qrBox)
        
        qrImageView = NSImageView(frame: NSRect(x: 10, y: 10, width: 270, height: 270))
        qrBox.addSubview(qrImageView)
        
        pairCodeLabel = NSTextField(labelWithString: "Code: Generating...")
        pairCodeLabel.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        pairCodeLabel.alignment = .center
        pairCodeLabel.frame = NSRect(x: 20, y: height - 450, width: width - 40, height: 25)
        visualEffect.addSubview(pairCodeLabel)
        
        progressIndicator = NSProgressIndicator(frame: NSRect(x: (width - 24) / 2, y: height - 485, width: 24, height: 24))
        progressIndicator.style = .spinning
        progressIndicator.startAnimation(nil)
        visualEffect.addSubview(progressIndicator)
        
        statusLabel = NSTextField(labelWithString: "Waiting for QR scan on the same Wi-Fi network...")
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.frame = NSRect(x: 20, y: height - 515, width: width - 40, height: 20)
        visualEffect.addSubview(statusLabel)
        
        let manualBtn = NSButton(title: "Enter IP & Pairing Code manually...", target: self, action: #selector(openManualPairDialog))
        manualBtn.bezelStyle = .rounded
        manualBtn.frame = NSRect(x: (width - 280) / 2, y: 65, width: 280, height: 32)
        visualEffect.addSubview(manualBtn)
        
        let usbHelpLabel = NSTextField(labelWithString: "💡 Or connect via USB cable once to start mirroring instantly.")
        usbHelpLabel.font = NSFont.systemFont(ofSize: 11)
        usbHelpLabel.textColor = .tertiaryLabelColor
        usbHelpLabel.alignment = .center
        usbHelpLabel.frame = NSRect(x: 20, y: 25, width: width - 40, height: 20)
        visualEffect.addSubview(usbHelpLabel)
        
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        generateNewQRPairing()
        startPeriodicDeviceCheck()
    }
    
    func generateNewQRPairing() {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let randomSuffix = String((0..<8).map { _ in chars.randomElement()! })
        serviceName = "adb-pair-\(randomSuffix)"
        pairingPassword = String((0..<6).map { _ in "0123456789".randomElement()! })
        
        let payload = "WIFI:T:ADB;S:\(serviceName);P:\(pairingPassword);;"
        pairCodeLabel.stringValue = "Pairing Code: \(pairingPassword)"
        
        if let qr = generateQRImage(from: payload) {
            qrImageView.image = NSImage(cgImage: qr, size: NSSize(width: 270, height: 270))
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
        mdnsProcess?.terminate()
        
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
                        self?.statusLabel.stringValue = "Phone paired! Connecting to screen stream..."
                        self?.completeConnectionAfterPair()
                    }
                }
            }
        }
        
        do {
            try p.run()
            mdnsProcess = p
        } catch {
            print("Failed to run dns-sd:", error)
        }
    }
    
    func completeConnectionAfterPair() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Android shifts to _adb-tls-connect._tcp right after pairing
            for _ in 0..<12 {
                if autoConnectMdnsWirelessDevices() {
                    let devices = getConnectedDevices()
                    if let first = devices.first {
                        DispatchQueue.main.async {
                            self?.window?.close()
                            startScrcpy(serial: first)
                        }
                        return
                    }
                }
                Thread.sleep(forTimeInterval: 0.8)
            }
            
            // Fallback: check adb devices list directly
            let devices = getConnectedDevices()
            if let first = devices.first {
                DispatchQueue.main.async {
                    self?.window?.close()
                    startScrcpy(serial: first)
                }
            } else {
                DispatchQueue.main.async {
                    self?.statusLabel.stringValue = "Paired! Connecting to phone..."
                }
            }
        }
    }
    
    func startPeriodicDeviceCheck() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, !self.isChecking else { return }
            self.isChecking = true
            DispatchQueue.global(qos: .background).async {
                let list = getConnectedDevices()
                if let first = list.first {
                    DispatchQueue.main.async {
                        self.mdnsProcess?.terminate()
                        self.window?.close()
                        startScrcpy(serial: first)
                    }
                }
                self.isChecking = false
            }
        }
    }
    
    @objc func openManualPairDialog() {
        let alert = NSAlert()
        alert.messageText = "Manual Wi-Fi Pairing"
        alert.informativeText = "On your Android device:\nGo to Developer Options → Wireless Debugging → 'Pair device with pairing code'.\n\nEnter the Wi-Fi pairing details shown on your phone:"
        alert.alertStyle = .informational
        
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        
        let ipLabel = NSTextField(labelWithString: "IP address & Port (e.g. 192.168.1.50:37123):")
        ipLabel.frame = NSRect(x: 0, y: 55, width: 320, height: 20)
        container.addSubview(ipLabel)
        
        let ipField = NSTextField(frame: NSRect(x: 0, y: 32, width: 320, height: 22))
        ipField.placeholderString = "192.168.1.50:37123"
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
                self.statusLabel.stringValue = "Pairing with \(hostPort)..."
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = runCommand(ADB_PATH, args: ["pair", hostPort, code])
                    if result.exitCode == 0 || result.output.contains("Successfully paired") {
                        _ = autoConnectMdnsWirelessDevices()
                        let devices = getConnectedDevices()
                        if let first = devices.first {
                            DispatchQueue.main.async {
                                self.window?.close()
                                startScrcpy(serial: first)
                            }
                        } else {
                            DispatchQueue.main.async {
                                self.promptForConnectPort(baseIP: hostPort.components(separatedBy: ":")[0])
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
        alert.informativeText = "Check the main 'Wireless debugging' screen on your phone for 'IP address & Port'.\n\nEnter the connection port (or full IP:Port):"
        alert.alertStyle = .informational
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "e.g. 5555 or \(baseIP):46145"
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
                try? FileManager.default.createDirectory(atPath: "\(NSHomeDirectory())/Library/Application Support/PhoneMirroring", withIntermediateDirectories: true)
                try? target.write(toFile: PREFS_FILE, atomically: true, encoding: .utf8)
                
                Thread.sleep(forTimeInterval: 1.0)
                let connected = getConnectedDevices()
                if let dev = connected.first {
                    self.window?.close()
                    startScrcpy(serial: dev)
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
