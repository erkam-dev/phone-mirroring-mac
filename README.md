# Phone Mirroring for Mac
A smooth, native macOS companion app to mirror and control your Android screen wirelessly or via USB with low-latency hardware acceleration using `scrcpy`.

## ✨ Features
- **Auto-Connect**: Detects USB-connected devices or auto-reconnects to your last paired Wi-Fi device immediately.
- **Mac Camera QR Code Scanner**:
  - Opens your Mac's camera with live viewfinder preview.
  - Automatically reads the Android Wireless Debugging QR code (`WIFI:T:ADB;S:...;P:...;;`) straight from your phone screen using Apple's Vision framework.
- **Manual IP & Code Pairing**: Easy fallback dialog to enter IP:Port and 6-digit pairing code manually.
- **Ultra-Smooth Low Latency Tuning**:
  - Hardware accelerated H.264 decoding on Apple Silicon
  - Locked 60 FPS pacing
  - 16 Mbps bitrate for sharp text and crisp UI
  - 20ms video jitter buffer & 50ms audio buffer to eliminate Wi-Fi audio/video drops

## 🚀 How to Use
1. Install prerequisites (if not already installed):
   ```bash
   brew install scrcpy
   ```
2. Open **Phone Mirroring** from Launchpad or Spotlight (`Cmd + Space` → `Phone Mirroring`).
3. Connect wirelessly:
   - On Android: Go to **Settings → Developer Options → Wireless Debugging → "Pair device with QR code"**.
   - Hold your phone screen up to your Mac's camera.
   - The app instantly detects the QR code, extracts the credentials, and establishes the wireless ADB connection.
4. Or connect via USB cable for instant plug-and-play mirroring.
