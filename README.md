# Phone Mirroring for Mac (v2.2)
A smooth, native macOS companion app to mirror and control your Android screen wirelessly or via USB with low-latency hardware acceleration using `scrcpy`.

## ✨ Features (v2.2)
- **Menu Bar Companion**: Lives in your macOS menu bar (`📱`) with live status indicators and quick-access shortcuts.
- **Device Manager Window**:
  - **Connected Devices Tab**: List all discovered USB & Wi-Fi ADB devices, view connection status, and mirror with one click.
  - **Wireless QR Pairing Tab**: Generates on-screen pairing QR code for Android's built-in scanner (`Settings → Developer options → Wireless debugging → Pair device with QR code`), with automatic background mDNS handshake.
  - **Settings Tab**: Customize scrcpy parameters (video bitrate, max FPS, stay-awake, turn-screen-off on mirror start) persisted locally in `~/.phone_mirroring_settings.json`.
- **Runtime Phone Controls**: Control your phone straight from the macOS menu bar while mirroring:
  - Turn Screen Off (`input keyevent 26`)
  - Turn Screen On (`input keyevent 224`)
  - Power / Lock Toggle
  - Volume Up / Volume Down
  - Disconnect / Stop Mirroring
- **Fault-Tolerant & Resilient**:
  - Fast connection timeouts (no infinite hangs or silent window closures when Wi-Fi drops).
  - Diagnostic logs displayed directly inside Device Manager if a connection attempt fails.
- **Ultra-Smooth Low Latency Tuning**:
  - Hardware accelerated H.264 decoding on Apple Silicon
  - Locked 60 FPS pacing
  - 16 Mbps bitrate for sharp text and crisp UI
  - Optimized jitter buffers to eliminate Wi-Fi audio/video drops

## 🚀 How to Use
1. Install prerequisites (if not already installed):
   ```bash
   brew install scrcpy android-platform-tools
   ```
2. Open **Phone Mirroring** from Launchpad, Applications, or Spotlight (`Cmd + Space` → `Phone Mirroring`).
3. Pair wirelessly:
   - Click the `📱` icon in your macOS Menu Bar → **Open Device Manager & Settings...**
   - Go to the **Wireless QR Pairing** tab.
   - On Android: Go to **Settings → Developer Options → Wireless Debugging → "Pair device with QR code"**.
   - Scan the QR code shown on your Mac. Android pairs and connects automatically.
4. Or connect via USB cable for instant plug-and-play mirroring.
