# ZHA to Zigbee2MQTT Migration Tool

Migrate your Zigbee Home Automation (ZHA) network to Zigbee2MQTT **without re-pairing any devices**.

## Overview

This script extracts network credentials, device information, and group configurations from ZHA's SQLite database and generates all the files needed to run Zigbee2MQTT with your existing network.

### How It Works

Both ZHA (zigpy) and Zigbee2MQTT (zigbee-herdsman) support the **open-coordinator-backup** format. This script:

1. Extracts the network backup from ZHA's `zigbee.db` SQLite database
2. Converts device and group information to Z2M format
3. Generates all required Z2M configuration files
4. Preserves network credentials (network key, PAN ID, channel, frame counters)

After migration, your devices will continue to work because the network identity remains the same—they don't know (or care) that the coordinator software changed.

## Requirements

### Software Dependencies

- `sqlite3` - For reading ZHA database
- `jq` - For JSON processing
- `python3` - For data conversion and pickle handling

### On macOS
```bash
brew install sqlite3 jq python3
```

### On Debian/Ubuntu
```bash
sudo apt install sqlite3 jq python3
```

### On Home Assistant OS
These tools are available in the Terminal & SSH add-on.

## Pre-Migration Checklist

### ⚠️ IMPORTANT: Stop ZHA Before Running

**You MUST stop ZHA before running this script and starting Z2M.** Running two coordinators on the same network simultaneously will cause conflicts and potentially corrupt your network.

### Step-by-Step Preparation

1. **Create a Home Assistant backup** (Settings → System → Backups)

2. **Copy your ZHA database** to a safe location:
   ```bash
   cp /config/zigbee.db /config/zigbee.db.backup
   ```

3. **Stop ZHA Integration:**
   - Go to Settings → Devices & Services → ZHA
   - Click the three dots menu → Disable
   - Or remove the integration entirely (you can re-add it later if needed)

4. **Optional: Note your adapter path**
   ```bash
   ls -la /dev/serial/by-id/
   # or
   ls -la /dev/ttyUSB* /dev/ttyACM*
   ```

## Usage

### Basic Usage

```bash
./migrate_zha_to_z2m.sh
```

The script will interactively prompt you for any information it cannot detect automatically.

### With Options

```bash
./migrate_zha_to_z2m.sh \
  --zha-db /config/zigbee.db \
  --output /config/zigbee2mqtt \
  --mqtt-server mqtt://core-mosquitto \
  --serial-port /dev/serial/by-id/usb-Nabu_Casa_SkyConnect_v1.0-if00 \
  --adapter ember
```

### All Options

| Option | Description | Default |
|--------|-------------|---------|
| `-z, --zha-db PATH` | Path to ZHA's zigbee.db | `/config/zigbee.db` |
| `-o, --output DIR` | Output directory for Z2M files | `/config/zigbee2mqtt` |
| `-m, --mqtt-server URL` | MQTT broker URL | `mqtt://core-mosquitto` |
| `-u, --mqtt-user USER` | MQTT username | (prompted if needed) |
| `-P, --mqtt-password PASS` | MQTT password | (prompted if needed) |
| `-p, --serial-port PATH` | Serial port for adapter | (auto-detected) |
| `-a, --adapter TYPE` | Adapter type | (auto-detected) |
| `-v, --verbose` | Enable verbose output | off |
| `-n, --dry-run` | Preview without creating files | off |
| `-h, --help` | Show help message | |

### Adapter Types

| Type | Chips/Adapters |
|------|----------------|
| `ember` | Silicon Labs EFR32 (SkyConnect, Sonoff Dongle-E/M, SLZB-06/07) |
| `zstack` | Texas Instruments CC2531, CC2538, CC2652 (Sonoff Dongle-P) |
| `deconz` | ConBee, ConBee II, RaspBee |
| `zigate` | ZiGate dongles |

## Generated Files

The script creates the following files in the output directory:

```
zigbee2mqtt/
├── configuration.yaml    # Main Z2M configuration
├── coordinator_backup.json  # Network credentials backup
├── database.db          # Device database (NDJSON format)
├── devices.yaml         # Friendly names for devices
├── groups.yaml          # Group definitions
└── secret.yaml          # MQTT credentials (if provided)
```

## Post-Migration Steps

### 1. Install Zigbee2MQTT

**Home Assistant Add-on:**
1. Go to Settings → Add-ons → Add-on Store
2. Search for "Zigbee2MQTT" and install it
3. **Don't start it yet!**

**Docker:**
```bash
docker run -d \
  --name zigbee2mqtt \
  -v /path/to/zigbee2mqtt:/app/data \
  --device=/dev/ttyUSB0 \
  -e TZ=Europe/Berlin \
  koenkk/zigbee2mqtt
```

### 2. Copy Generated Files

If you ran the script outside Home Assistant:
```bash
scp -r zigbee2mqtt/ root@homeassistant.local:/config/
```

### 3. Start Zigbee2MQTT

Start the add-on or container. Check the logs for:
```
Zigbee2MQTT started!
Successfully connected to MQTT server
Coordinator backup restored
```

### 4. Wake Up Battery Devices

Battery-powered devices (sensors, buttons) may need to be woken up:
- **Trigger the device** (open/close door, press button, wave at motion sensor)
- **Wait for the next check-in** (can take 1-4 hours for some devices)

Mains-powered devices (bulbs, plugs, switches) should work immediately.

### 5. Verify in Home Assistant

If using the Zigbee2MQTT Home Assistant integration:
1. Go to Settings → Devices & Services
2. Add the MQTT integration if not present
3. Devices should appear automatically via MQTT discovery

## Troubleshooting

### "BACKUP is not for EmberZNet stack"

This error occurs when migrating to an EmberZNet adapter (Sonoff E/M, SkyConnect). The script handles this automatically by including required EZSP-specific fields. If you still see this error:

1. Ensure you're using the latest version of this script
2. Check that your ZHA backup contains the required `stack_specific.ezsp` data
3. Try creating a fresh backup using `ember-zli stack` → "Backup network"

### Devices Not Responding

1. **Check Z2M logs** for communication errors
2. **Verify the network key** matches (compare `networkKey` in backups)
3. **Wake battery devices** by triggering them
4. **Wait for routers** - router devices re-establish routes automatically

### "Coordinator not found" or Serial Port Issues

```bash
# Find your adapter
ls -la /dev/serial/by-id/

# Check permissions
sudo chmod 666 /dev/ttyUSB0
```

### Frame Counter Issues

If devices reject commands due to security (frame counter mismatch):
- The migrated frame counter may be behind the device's expected value
- Solution: Remove and re-pair the affected device (rare)

## Rollback to ZHA

If you need to go back to ZHA:

1. Stop Zigbee2MQTT
2. Re-enable/reinstall ZHA integration
3. Your original `zigbee.db` backup should restore the network

## Technical Details

### Database Formats

| System | Database | Format |
|--------|----------|--------|
| ZHA | `zigbee.db` | SQLite with JSON blobs |
| Z2M | `database.db` | NDJSON (newline-delimited JSON) |

### Network Backup Format

Both systems use the **zigpy/open-coordinator-backup** format:
```json
{
  "metadata": {
    "format": "zigpy/open-coordinator-backup",
    "version": 1
  },
  "coordinator_ieee": "00:11:22:33:44:55:66:77",
  "network_key": { "key": [...], "tx_counter": 12345 },
  "pan_id": "0x1234",
  "channel": 15
}
```

### IEEE Address Formats

| System | Format | Example |
|--------|--------|---------|
| ZHA | Colon-separated | `00:15:8d:00:06:b3:a4:21` |
| Z2M | Hex with 0x prefix | `0x00158d0006b3a421` |

## About Encrypted Dongle Backups

If you have a `.enc` backup file from Sonoff ZBDongle tools (e.g., from NSPanel Pro or iHost), note that:

- These files are **encrypted** with a proprietary key
- They **cannot be used** directly for this migration
- Use the ZHA database or `ember-zli` to create a compatible backup

## Contributing

Issues and pull requests welcome!

## License

MIT License - See LICENSE file for details.

## References

- [Zigbee2MQTT Documentation](https://www.zigbee2mqtt.io/)
- [ZHA Integration Documentation](https://www.home-assistant.io/integrations/zha/)
- [open-coordinator-backup Format](https://github.com/zigpy/open-coordinator-backup)
- [ember-zli Tool](https://github.com/Nerivec/ember-zli)
