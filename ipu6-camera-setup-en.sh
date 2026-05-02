#!/bin/bash
# ============================================================
# Surface Go 4 / Intel IPU6 Camera Setup Script
# Ubuntu 25.10 (Questing) + libcamera 0.7.0 built from source
# Tested on: kernel 6.17, Intel N200, sensors ov5693/ov8865
# ============================================================

set -e

echo "=== Intel IPU6 Camera Setup ==="
echo "Ubuntu 25.10 + libcamera 0.7.0 (built from source)"
echo ""

# ----------------------------------------
# 1. Install dependencies
# ----------------------------------------
echo "[1/6] Installing dependencies..."
sudo apt update
sudo apt install -y \
    git meson ninja-build pkg-config \
    libboost-dev libgnutls28-dev openssl libssl-dev \
    python3-yaml python3-ply \
    libdw-dev libudev-dev \
    libevent-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
    gstreamer1.0-tools gstreamer1.0-plugins-good \
    pipewire-libcamera

# ----------------------------------------
# 2. Clone libcamera source
# ----------------------------------------
echo "[2/6] Cloning libcamera source..."
cd ~
if [ -d "libcamera" ]; then
    echo "Existing libcamera directory found. Skipping clone."
else
    git clone https://git.libcamera.org/libcamera/libcamera.git
fi
cd libcamera

# ----------------------------------------
# 3. Configure build
# ----------------------------------------
echo "[3/6] Configuring build..."
# Notes:
#   -Dipas=ipu3,simple  : 'simple' pipeline enables IPU6 support via soft ISP
#   -Dqcam=disabled     : Qt6 not available on Ubuntu 25.10 by default
#   -Dtest=false        : Skip tests to speed up build
meson setup --reconfigure build \
    -Dipas=ipu3,simple \
    -Dcam=enabled \
    -Dgstreamer=enabled \
    -Dqcam=disabled \
    -Dtest=false

# ----------------------------------------
# 4. Build and install
# ----------------------------------------
echo "[4/6] Building... (this may take a few minutes)"
ninja -C build

echo "[4/6] Installing..."
sudo ninja -C build install

# ----------------------------------------
# 5. Configure ldconfig
# ----------------------------------------
echo "[5/6] Configuring library path..."
# This ensures WirePlumber loads our custom-built libcamera (v0.7.0)
# instead of the system version (v0.5.0), which lacks IPU6 IPA support.
echo '/usr/local/lib/x86_64-linux-gnu' | sudo tee /etc/ld.so.conf.d/libcamera-local.conf
sudo ldconfig

# ----------------------------------------
# 6. Restart WirePlumber
# ----------------------------------------
echo "[6/6] Restarting PipeWire / WirePlumber..."
systemctl --user restart wireplumber
sleep 2

# ----------------------------------------
# Verify setup
# ----------------------------------------
echo ""
echo "=== Verification ==="

echo "--- IPU6 kernel detection ---"
sudo dmesg | grep -i ipu6 | grep -E "Connected|Found supported" || echo "No IPU6 log found"

echo ""
echo "--- PipeWire camera list ---"
pw-cli list-objects 2>/dev/null | grep -E "node.description|object.path" | grep -i "camera\|libcamera" || echo "No cameras found in PipeWire"

echo ""
echo "=== Setup complete ==="
echo ""
echo "=== Usage ==="
echo ""
echo "View rear camera (640x480, recommended):"
echo "  LD_LIBRARY_PATH=/usr/local/lib/x86_64-linux-gnu \\"
echo "  GST_PLUGIN_PATH=/usr/local/lib/x86_64-linux-gnu/gstreamer-1.0 \\"
echo "  gst-launch-1.0 libcamerasrc camera-name='\\\\_SB_.PC00.I2C5.CAMR' \\"
echo "  ! video/x-raw,width=640,height=480 ! videoconvert ! autovideosink"
echo ""
echo "Capture a still image:"
echo "  cd ~ && ~/libcamera/build/src/apps/cam/cam -c '\\_SB_.PC00.I2C5.CAMR' -C -Fframe.ppm"
echo ""
echo "=== Known limitations ==="
echo "  - Front camera (ov5693): access LED lights up but no video output"
echo "  - Image quality is blurry: no calibration file (ov5693.yaml / ov8865.yaml) available"
echo "  - CPU usage: ~50% at 640x480, over 100% at full resolution (no hardware ISP)"
echo "  - Apps like Cheese should detect the camera via PipeWire after setup"
echo "  - Firefox Snap may not detect the camera (use native Firefox if possible)"
