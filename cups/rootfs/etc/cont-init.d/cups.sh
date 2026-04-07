#!/usr/bin/with-contenv bash

# Create CUPS data directories for persistence
mkdir -p /data/cups/cache
mkdir -p /data/cups/logs
mkdir -p /data/cups/state
mkdir -p /data/cups/config
mkdir -p /data/cups/config/ppd
mkdir -p /data/cups/config/ssl

# Set proper permissions
chown -R root:lp /data/cups
chmod -R 775 /data/cups

# Ensure NSS uses only local files to prevent CUPS hanging on user lookups
cat > /etc/nsswitch.conf << 'EOF'
passwd:    files
group:     files
shadow:    files
hosts:     files dns
networks:  files
protocols: files
services:  files
EOF

# Ensure the lp user and group exist (required for CUPS anonymous job ownership)
getent group lp  > /dev/null 2>&1 || addgroup -S lp
getent passwd lp > /dev/null 2>&1 || adduser -S -G lp -H -D lp

# Create CUPS configuration directory if it doesn't exist
mkdir -p /etc/cups

# Write cupsd.conf only on first run — preserves any manual changes across updates
if [ ! -f /data/cups/config/cupsd.conf ]; then
    echo "Writing default cupsd.conf..."
    cat > /data/cups/config/cupsd.conf << EOL
# Listen on all interfaces
Listen 0.0.0.0:631

# Allow access from local network
<Location />
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
</Location>

# Admin access (no authentication)
<Location /admin>
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
</Location>

# Job management permissions
<Location /jobs>
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
</Location>

<Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job CUPS-Get-Document>
  Order allow,deny
  Allow localhost
  Allow 10.0.0.0/8
  Allow 172.16.0.0/12
  Allow 192.168.0.0/16
</Limit>

<Policy default>
  # This is the "magic" line that stops jobs from showing as anonymous
  JobPrivateValues none
  JobPrivateAccess all
  
  # Ensure document names are visible too
  DisplayAllowedJobAttributes all

  <Limit All>
    Order deny,allow
    Allow localhost
    Allow 10.0.0.0/8
    Allow 172.16.0.0/12
    Allow 192.168.0.0/16
  </Limit>
</Policy>

# Enable web interface
WebInterface Yes

# Default settings
DefaultAuthType None
SystemGroup root
HostNameLookups Off
Browsing Off
JobSheets none,none
PreserveJobHistory No
EOL
fi

# Create a symlink from the default config location to our persistent location
ln -sf /data/cups/config/cupsd.conf /etc/cups/cupsd.conf
ln -sf /data/cups/config/printers.conf /etc/cups/printers.conf
ln -sf /data/cups/config/ppd /etc/cups/ppd
ln -sf /data/cups/config/ssl /etc/cups/ssl

# Restore previously persisted driver PPDs into the system location after a container update
if [ -d /data/cups/driver-ppds ] && [ "$(ls -A /data/cups/driver-ppds)" ]; then
    cp -r /data/cups/driver-ppds/. /usr/share/cups/model/
fi

# Install user-supplied printer driver .deb (e.g. Canon UFR II for MF4412)
DRIVER_DEB=$(jq -r '.printer_driver_deb // empty' /data/options.json 2>/dev/null)
if [ -n "$DRIVER_DEB" ]; then
    DRIVER_PATH="/share/${DRIVER_DEB}"
    if [ -f "$DRIVER_PATH" ]; then
        echo "Installing printer driver from ${DRIVER_PATH}..."
        EXTRACT_DIR=$(mktemp -d)
        dpkg -x "$DRIVER_PATH" "$EXTRACT_DIR"
        # Copy CUPS filters
        if [ -d "${EXTRACT_DIR}/usr/lib/cups/filter" ]; then
            cp -r "${EXTRACT_DIR}/usr/lib/cups/filter/." /usr/lib/cups/filter/
            chmod 755 /usr/lib/cups/filter/*
        fi
        # Copy shared libraries
        if [ -d "${EXTRACT_DIR}/usr/lib" ]; then
            find "${EXTRACT_DIR}/usr/lib" -name "*.so*" -exec cp {} /usr/lib/ \;
        fi
        # Copy PPD files to both the system location and /data so they persist across updates
        if [ -d "${EXTRACT_DIR}/usr/share/cups/model" ]; then
            cp -r "${EXTRACT_DIR}/usr/share/cups/model/." /usr/share/cups/model/
            mkdir -p /data/cups/driver-ppds
            cp -r "${EXTRACT_DIR}/usr/share/cups/model/." /data/cups/driver-ppds/
        fi
        rm -rf "$EXTRACT_DIR"
        echo "Printer driver installed."
    else
        echo "Warning: printer_driver_deb set to '${DRIVER_DEB}' but /share/${DRIVER_DEB} was not found."
    fi
fi

# Warn if Canon UFR II filter is missing (not available on aarch64 Alpine)
if ! [ -x /usr/lib/cups/filter/rastertoufr2 ]; then
    echo "WARNING: Canon UFR II filter (rastertoufr2) is not available on this platform."
    echo "  Canon MF4412 must be added using a generic PCL5e driver, not the UFR II driver."
    echo "  In the CUPS web interface select: 'Generic PCL 5e Printer' as the driver."
fi

# Auto-add Canon MF4412 via USB (auto-detected) or explicit URI if set
CANON_URI=$(jq -r '.canon_mf4412_uri // empty' /data/options.json 2>/dev/null)

# Load usblp module so CUPS USB backend can enumerate devices
modprobe usblp 2>/dev/null || true

# Start CUPS temporarily to query devices and run lpadmin
/usr/sbin/cupsd
sleep 5

if ! lpstat -p Canon-MF4412 > /dev/null 2>&1; then
    # If no URI given, detect the Canon USB device automatically
    if [ -z "$CANON_URI" ]; then
        # Retry detection up to 3 times to allow USB enumeration to complete
        for i in 1 2 3; do
            CANON_URI=$(lpinfo -v --timeout 10 2>/dev/null \
                | grep -i "usb.*canon\|usb.*MF4" \
                | head -1 | awk '{print $2}')
            [ -n "$CANON_URI" ] && break
            echo "USB detection attempt ${i}/3 failed, retrying..."
            sleep 3
        done
    fi

    if [ -n "$CANON_URI" ]; then
        echo "Adding Canon MF4412 at ${CANON_URI} using Generic PCL5e driver..."
        lpadmin \
            -p Canon-MF4412 \
            -E \
            -v "$CANON_URI" \
            -m "drv:///sample.drv/generic.ppd" \
            -D "Canon MF4412" \
            -L "Auto-configured"
        echo "Canon MF4412 added."
    else
        echo "Canon MF4412 USB device not detected. Check USB connection and that /dev/bus/usb is accessible."
        echo "Available devices:"
        lpinfo -v 2>/dev/null || true
    fi
else
    echo "Canon MF4412 already configured, skipping."
fi

pkill cupsd 2>/dev/null || true
sleep 1

# Start CUPS service
/usr/sbin/cupsd -f
