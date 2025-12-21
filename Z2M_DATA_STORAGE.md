# Zigbee2MQTT (Z2M) Data Storage Research

## Overview

This document details how Zigbee2MQTT stores its data and configuration. Z2M uses the **zigbee-herdsman** library as its underlying Zigbee stack, which handles the core device database storage. Z2M adds additional layers for configuration, state management, and coordinator backups.

---

## 1. Data Directory Structure

### Default Location
- **Default path**: `data/` directory relative to Zigbee2MQTT installation
- **Environment variable**: Can be overridden via `ZIGBEE2MQTT_DATA` environment variable
- **Docker/Home Assistant Add-on**: Typically `/share/zigbee2mqtt/` or `/config/zigbee2mqtt/`

### Directory Contents
```
data/
├── configuration.yaml      # Main configuration file
├── database.db            # Device database (zigbee-herdsman)
├── coordinator_backup.json # Coordinator backup (unified format)
├── state.json             # Device state cache
├── secret.yaml            # Optional secrets file
├── devices.yaml           # Optional separate devices config
├── groups.yaml            # Optional separate groups config
└── log/                   # Log directory
    └── %TIMESTAMP%/       # Timestamped log directories
        └── log.log        # Log file
```

---

## 2. database.db - Device Database

### File Format
- **Format**: NDJSON (Newline Delimited JSON) - NOT SQLite!
- **One JSON object per line**
- **Each line represents a complete entity (device or group)**
- **Write strategy**: Atomic write via temp file + rename

### File Structure
```
{"id":1,"type":"Coordinator","ieeeAddr":"0x00124b0028c4e7d5",...}
{"id":2,"type":"Router","ieeeAddr":"0x00158d00044a89b2",...}
{"id":3,"type":"EndDevice","ieeeAddr":"0x00158d0006b3a421",...}
{"id":4,"type":"Group","groupID":1,"members":[...],"meta":{}}
```

### Database Operations (from `zigbee-herdsman/src/controller/database.ts`)
```typescript
export class Database {
    private entries: {[id: number]: DatabaseEntry};
    private path: string;
    private maxId: number;

    // Open database - parses each line as JSON
    public static open(path: string): Database {
        const entries: {[id: number]: DatabaseEntry} = {};
        if (fs.existsSync(path)) {
            const file = fs.readFileSync(path, "utf-8");
            for (const row of file.split("\n")) {
                if (!row) continue;
                const json = JSON.parse(row);
                if (json.id != null) {
                    entries[json.id] = json;
                }
            }
        }
        return new Database(entries, path);
    }

    // Write database - writes all entries as newline-delimited JSON
    public write(): void {
        let lines = "";
        for (const id in this.entries) {
            lines += `${JSON.stringify(this.entries[id])}\n`;
        }
        const tmpPath = `${this.path}.tmp`;
        const fd = fs.openSync(tmpPath, "w");
        fs.writeFileSync(fd, lines.slice(0, -1)); // remove last newline
        fs.fsyncSync(fd);  // Ensure file is on disk
        fs.closeSync(fd);
        fs.renameSync(tmpPath, this.path);  // Atomic rename
    }
}
```

### DatabaseEntry Interface
```typescript
export interface DatabaseEntry {
    id: number;
    type: EntityType;  // "Coordinator" | "Router" | "EndDevice" | "Unknown" | "GreenPower" | "Group"
    [s: string]: any;
}
```

---

## 3. Device Entry Structure

### Full Device Entry (from `device.toDatabaseEntry()`)
```typescript
{
    // Core identifiers
    id: number,                    // Internal database ID (auto-incremented)
    type: DeviceType,              // "Coordinator" | "Router" | "EndDevice" | "Unknown" | "GreenPower"
    ieeeAddr: string,              // IEEE address (e.g., "0x00158d0006b3a421")
    nwkAddr: number,               // Network address (16-bit, e.g., 0x5A3C)
    
    // Manufacturer info
    manufId: number | undefined,       // Manufacturer ID (e.g., 4151 for Xiaomi/LUMI)
    manufName: string | undefined,     // Manufacturer name (e.g., "LUMI")
    modelId: string | undefined,       // Model ID (e.g., "lumi.sensor_motion.aq2")
    
    // Power and version info
    powerSource: string | undefined,   // "Battery", "Mains (single phase)", etc.
    appVersion: number | undefined,    // Application version
    stackVersion: number | undefined,  // Stack version
    hwVersion: number | undefined,     // Hardware version
    zclVersion: number | undefined,    // ZCL version
    dateCode: string | undefined,      // Date code
    swBuildId: string | undefined,     // Software build ID
    
    // Endpoints
    epList: number[],              // List of endpoint IDs (e.g., [1, 2, 3])
    endpoints: {                   // Endpoint details keyed by endpoint ID
        [endpointId: number]: EndpointRecord
    },
    
    // Interview status
    interviewCompleted: boolean,       // @deprecated - kept for backwards compatibility
    interviewState: InterviewState,    // "PENDING" | "IN_PROGRESS" | "SUCCESSFUL" | "FAILED"
    
    // Metadata
    meta: KeyValue,                // Application-specific metadata
    lastSeen: number | undefined,  // Unix timestamp in milliseconds
    checkinInterval: number | undefined,  // Poll control check-in interval (seconds)
    
    // Green Power specific
    gpSecurityKey: number[] | undefined  // Security key for Green Power devices
}
```

### InterviewState Enum
```typescript
export enum InterviewState {
    Pending = "PENDING",
    InProgress = "IN_PROGRESS",
    Successful = "SUCCESSFUL",
    Failed = "FAILED",
}
```

### Example Device Entry
```json
{
    "id": 2,
    "type": "EndDevice",
    "ieeeAddr": "0x00158d0006b3a421",
    "nwkAddr": 23100,
    "manufId": 4151,
    "manufName": "LUMI",
    "powerSource": "Battery",
    "modelId": "lumi.sensor_motion.aq2",
    "epList": [1],
    "endpoints": {
        "1": {
            "profId": 260,
            "epId": 1,
            "devId": 263,
            "inClusterList": [0, 65535, 1030, 1024, 1280],
            "outClusterList": [0, 25],
            "clusters": {
                "genBasic": {
                    "attributes": {
                        "modelId": "lumi.sensor_motion.aq2",
                        "manufacturerName": "LUMI"
                    }
                }
            },
            "binds": [],
            "configuredReportings": [],
            "meta": {}
        }
    },
    "appVersion": 4,
    "stackVersion": 2,
    "hwVersion": 1,
    "zclVersion": 1,
    "dateCode": "20170627",
    "swBuildId": null,
    "interviewCompleted": true,
    "interviewState": "SUCCESSFUL",
    "meta": {},
    "lastSeen": 1703159234567
}
```

---

## 4. Endpoint Structure

### Endpoint Database Record (from `endpoint.toDatabaseRecord()`)
```typescript
{
    profId: number | undefined,        // Profile ID (260 = Home Automation, 49246 = ZLL)
    epId: number,                      // Endpoint ID (1-255)
    devId: number | undefined,         // Device ID (defines device type)
    inClusterList: number[],           // Input (server) clusters
    outClusterList: number[],          // Output (client) clusters
    clusters: {                        // Cluster attribute cache
        [clusterName: string]: {
            attributes: {
                [attributeName: string]: number | string
            }
        }
    },
    binds: BindInternal[],             // Binding table
    configuredReportings: ConfiguredReportingInternal[],  // Reporting config
    meta: KeyValue                     // Endpoint-specific metadata
}
```

### Profile IDs
| Profile ID | Name | Description |
|------------|------|-------------|
| 260 (0x0104) | Home Automation (HA) | Standard ZigBee HA profile |
| 49246 (0xC05E) | ZigBee Light Link (ZLL) | Light Link profile |
| 41440 (0xA1E0) | Green Power | Green Power profile |

### BindInternal Structure
```typescript
interface BindInternal {
    cluster: number;                   // Cluster ID
    type: "endpoint" | "group";        // Bind target type
    deviceIeeeAddress?: string;        // Target device IEEE (for endpoint binds)
    endpointID?: number;               // Target endpoint ID
    groupID?: number;                  // Target group ID (for group binds)
}
```

### ConfiguredReportingInternal Structure
```typescript
interface ConfiguredReportingInternal {
    cluster: number;                   // Cluster ID
    attrId: number;                    // Attribute ID
    minRepIntval: number;              // Minimum reporting interval (seconds)
    maxRepIntval: number;              // Maximum reporting interval (seconds)
    repChange: number;                 // Reportable change threshold
    manufacturerCode?: number;         // Manufacturer code (if manufacturer-specific)
}
```

---

## 5. Group Entry Structure

### Group Database Record (from `group.toDatabaseRecord()`)
```typescript
{
    id: number,                        // Internal database ID
    type: "Group",                     // Always "Group"
    groupID: number,                   // Zigbee group ID (1-65534)
    members: {                         // Member endpoints
        deviceIeeeAddr: string,        // Device IEEE address
        endpointID: number             // Endpoint ID
    }[],
    meta: KeyValue                     // Group-specific metadata
}
```

### Example Group Entry
```json
{
    "id": 10,
    "type": "Group",
    "groupID": 1,
    "members": [
        {"deviceIeeeAddr": "0x00158d0006b3a421", "endpointID": 1},
        {"deviceIeeeAddr": "0x00124b0028c4e7d5", "endpointID": 1}
    ],
    "meta": {}
}
```

---

## 6. configuration.yaml Structure

### File Format
- **Format**: YAML
- **Location**: `data/configuration.yaml`
- **Schema**: Validated by AJV against `settings.schema.json`
- **Current Version**: 4

### Core Structure
```yaml
version: 4                           # Configuration version

# MQTT settings (required)
mqtt:
    base_topic: zigbee2mqtt          # Base MQTT topic
    server: mqtt://localhost:1883    # MQTT broker URL
    user: ""                         # Optional MQTT username
    password: ""                     # Optional MQTT password
    include_device_information: false
    force_disable_retain: false
    maximum_packet_size: 1048576     # 1MB default
    keepalive: 60
    reject_unauthorized: true
    version: 4                       # MQTT protocol version

# Serial adapter settings
serial:
    port: /dev/ttyUSB0              # Serial port path
    adapter: zstack                  # Adapter type: zstack, ezsp, deconz, zigate, zboss
    disable_led: false
    baudrate: 115200                 # Optional, adapter-specific

# Network settings
advanced:
    pan_id: 0x1A62                   # PAN ID (0x0001-0xFFFE) or "GENERATE"
    ext_pan_id: [0xDD, 0xDD, 0xDD, 0xDD, 0xDD, 0xDD, 0xDD, 0xDD]  # Extended PAN ID or "GENERATE"
    channel: 11                      # Zigbee channel (11-26)
    network_key: [1, 3, 5, 7, 9, 11, 13, 15, 0, 2, 4, 6, 8, 10, 12, 13]  # 16-byte key or "GENERATE"
    
    # Logging
    log_level: info                  # error, warning, info, debug
    log_output: [console, file]
    log_directory: data/log/%TIMESTAMP%
    log_file: log.log
    log_rotation: true
    log_symlink_current: false
    log_console_json: false
    
    # State caching
    cache_state: true
    cache_state_persistent: true
    cache_state_send_on_startup: true
    
    # Timestamps
    last_seen: disable               # disable, ISO_8601, ISO_8601_local, epoch
    elapsed: false
    timestamp_format: "YYYY-MM-DD HH:mm:ss"
    output: json

# Frontend settings
frontend:
    enabled: true
    port: 8080
    base_url: /
    auth_token: ""                   # Optional authentication token

# Home Assistant integration
homeassistant:
    enabled: true
    discovery_topic: homeassistant
    status_topic: homeassistant/status
    legacy_action_sensor: false
    experimental_event_entities: false

# Device availability
availability:
    enabled: true
    active:
        timeout: 10
        max_jitter: 30000
        backoff: true
    passive:
        timeout: 1500

# OTA updates
ota:
    update_check_interval: 1440      # Minutes (24 hours)
    disable_automatic_update_check: false
    image_block_response_delay: 250
    default_maximum_data_size: 50

# Blocklist/Passlist
blocklist: []                        # IEEE addresses to block
passlist: []                         # IEEE addresses to allow (if set, only these allowed)

# Devices configuration (can be separate file)
devices:
    '0x00158d0006b3a421':
        friendly_name: motion_sensor_living_room
        retain: false
        icon: device_icons/motion.png
        # ... other device options

# Groups configuration (can be separate file)
groups:
    '1':
        friendly_name: living_room_lights
        retain: false
        # ... other group options
```

### Secrets Support
Reference secrets from a separate file:
```yaml
mqtt:
    password: '!secret mqtt_password'
advanced:
    network_key: '!secret network_key'
```

File `data/secret.yaml`:
```yaml
mqtt_password: my_secure_password
network_key: [1, 3, 5, 7, 9, 11, 13, 15, 0, 2, 4, 6, 8, 10, 12, 13]
```

### Separate Device/Group Files
Configuration can reference separate files:
```yaml
devices: devices.yaml
groups: groups.yaml
```

Or arrays of files:
```yaml
devices:
    - devices_floor1.yaml
    - devices_floor2.yaml
```

---

## 7. Network Key Storage

### Location
The network key is stored in `configuration.yaml` under `advanced.network_key`.

### Formats
```yaml
# Array format (16 bytes)
advanced:
    network_key: [1, 3, 5, 7, 9, 11, 13, 15, 0, 2, 4, 6, 8, 10, 12, 13]

# GENERATE keyword (auto-generates on first start)
advanced:
    network_key: GENERATE

# Secret reference
advanced:
    network_key: '!secret network_key'
```

### Default Key (zigbee-herdsman)
```typescript
const DefaultOptions = {
    network: {
        networkKey: [0x01, 0x03, 0x05, 0x07, 0x09, 0x0b, 0x0d, 0x0f, 
                     0x00, 0x02, 0x04, 0x06, 0x08, 0x0a, 0x0c, 0x0d],
        panID: 0x1a62,
        extendedPanID: [0xdd, 0xdd, 0xdd, 0xdd, 0xdd, 0xdd, 0xdd, 0xdd],
        channelList: [11],
    }
};
```

### Backup Storage
In `coordinator_backup.json`, the network key is stored in hex format:
```json
{
    "network_key": {
        "key": "0103050709 0b0d0f00020406080a0c0d",
        "sequence_number": 0,
        "frame_counter": 12345
    }
}
```

---

## 8. coordinator_backup.json Structure

### File Format
- **Format**: JSON (pretty-printed)
- **Standard**: [zigpy/open-coordinator-backup](https://github.com/zigpy/open-coordinator-backup)
- **Created**: Automatically every 24 hours and on shutdown
- **Purpose**: Cross-adapter compatible backup format

### UnifiedBackupStorage Interface
```typescript
interface UnifiedBackupStorage {
    metadata: {
        format: "zigpy/open-coordinator-backup";
        version: 1;
        source: string;              // e.g., "zigbee-herdsman@0.50.0"
        internal: {
            date: string;            // ISO 8601 timestamp
            znpVersion?: number;     // Z-Stack version (if applicable)
            ezspVersion?: number;    // EZSP version (if applicable)
        };
    };
    
    stack_specific?: {
        zstack?: {
            tclk_seed?: string;      // Trust Center Link Key seed (hex)
        };
        ezsp?: {
            hashed_tclk?: string;    // Hashed TCLK (hex)
        };
    };
    
    coordinator_ieee: string;        // Coordinator IEEE address (hex, lowercase)
    pan_id: string;                  // PAN ID (hex)
    extended_pan_id: string;         // Extended PAN ID (hex)
    security_level: number;          // Security level (typically 5)
    nwk_update_id: number;           // Network update ID
    channel: number;                 // Current channel (11-26)
    channel_mask: number[];          // Allowed channels array
    
    network_key: {
        key: string;                 // Network key (hex, 32 chars)
        sequence_number: number;     // Key sequence number
        frame_counter: number;       // Frame counter
    };
    
    devices: {
        nwk_address: string | null;  // Network address (hex) or null
        ieee_address: string;        // IEEE address (hex, lowercase)
        is_child: boolean;           // Is direct child of coordinator
        link_key?: {
            key: string;             // Link key (hex)
            rx_counter: number;      // RX counter
            tx_counter: number;      // TX counter
        };
    }[];
}
```

### Example coordinator_backup.json
```json
{
    "metadata": {
        "format": "zigpy/open-coordinator-backup",
        "version": 1,
        "source": "zigbee-herdsman@0.50.4",
        "internal": {
            "date": "2024-12-21T10:30:00.000Z",
            "znpVersion": 3
        }
    },
    "stack_specific": {
        "zstack": {
            "tclk_seed": "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"
        }
    },
    "coordinator_ieee": "00124b0028c4e7d5",
    "pan_id": "1a62",
    "extended_pan_id": "dddddddddddddddd",
    "security_level": 5,
    "nwk_update_id": 0,
    "channel": 11,
    "channel_mask": [11],
    "network_key": {
        "key": "0103050709 0b0d0f00020406080a0c0d",
        "sequence_number": 0,
        "frame_counter": 123456
    },
    "devices": [
        {
            "nwk_address": "5a3c",
            "ieee_address": "00158d0006b3a421",
            "is_child": true,
            "link_key": {
                "key": "abcdef0123456789abcdef0123456789",
                "rx_counter": 100,
                "tx_counter": 200
            }
        },
        {
            "nwk_address": "1234",
            "ieee_address": "00158d00044a89b2",
            "is_child": false
        }
    ]
}
```

### Backup Creation (from `controller.ts`)
```typescript
public async backup(): Promise<void> {
    this.databaseSave();
    if (this.options.backupPath && (await this.adapter.supportsBackup())) {
        logger.debug("Creating coordinator backup", NS);
        const backup = await this.adapter.backup(this.getDeviceIeeeAddresses());
        const unifiedBackup = BackupUtils.toUnifiedBackup(backup);
        const tmpBackupPath = `${this.options.backupPath}.tmp`;
        fs.writeFileSync(tmpBackupPath, JSON.stringify(unifiedBackup, null, 2));
        fs.renameSync(tmpBackupPath, this.options.backupPath);
    }
}
```

---

## 9. state.json Structure

### File Format
- **Format**: JSON (pretty-printed with 4-space indent)
- **Location**: `data/state.json`
- **Purpose**: Persistent state cache for devices and groups
- **Save interval**: Every 5 minutes + on shutdown

### Structure
```typescript
{
    // Keys are IEEE addresses (devices) or group IDs (groups)
    [ieeeAddrOrGroupId: string]: {
        // State values depend on device type
        [stateProperty: string]: any
    }
}
```

### Example state.json
```json
{
    "0x00158d0006b3a421": {
        "occupancy": false,
        "illuminance": 45,
        "illuminance_lux": 45,
        "battery": 92,
        "voltage": 3025,
        "linkquality": 89
    },
    "0x00158d00044a89b2": {
        "state": "ON",
        "brightness": 254,
        "color_temp": 370,
        "linkquality": 156
    },
    "1": {
        "state": "ON",
        "brightness": 200
    }
}
```

### State Loading/Saving (from `state.ts`)
```typescript
class State {
    private readonly state = new Map<string | number, KeyValue>();
    private readonly file = data.joinPath("state.json");

    private load(): void {
        this.state.clear();
        if (existsSync(this.file)) {
            const stateObj = JSON.parse(readFileSync(this.file, "utf8"));
            for (const key in stateObj) {
                // IEEE addresses are strings, group IDs are numbers
                this.state.set(
                    key.startsWith("0x") ? key : Number.parseInt(key, 10),
                    stateObj[key]
                );
            }
        }
    }

    private save(): void {
        if (settings.get().advanced.cache_state_persistent) {
            const json = JSON.stringify(Object.fromEntries(this.state), null, 4);
            writeFileSync(this.file, json, "utf8");
        }
    }
}
```

### Ignored Properties (not cached)
The following properties are not persisted to state.json:
```typescript
const CACHE_IGNORE_PROPERTIES = [
    "action",
    "action_.*",
    "button",
    "button_left",
    "button_right",
    "forgotten",
    "keyerror",
    "step_size",
    "transition_time",
    "group_list",
    "group_capacity",
    "no_occupancy_since",
    "step_mode",
    "duration",
    "elapsed",
    "from_side",
    "to_side",
    "illuminance_lux"  // removed in z2m 2.0.0
];
```

---

## 10. Device Type Classification

### DeviceType Enum
```typescript
type DeviceType = "Coordinator" | "Router" | "EndDevice" | "Unknown" | "GreenPower";
```

### Type Characteristics
| Type | Description | Mains Powered | Routes Messages |
|------|-------------|---------------|-----------------|
| Coordinator | Network coordinator (the adapter) | Yes | Yes |
| Router | Mains-powered routing device | Yes | Yes |
| EndDevice | Battery-powered sleepy device | Usually No | No |
| GreenPower | Green Power device (energy harvesting) | No | No |
| Unknown | Not yet determined (before interview) | Unknown | Unknown |

### Type Determination (from Node Descriptor)
```typescript
switch (nodeDescriptor.logicalType) {
    case 0x0:
        this._type = "Coordinator";
        break;
    case 0x1:
        this._type = "Router";
        break;
    case 0x2:
        this._type = "EndDevice";
        break;
}
```

---

## 11. Common Cluster Reference

### Frequently Used Clusters
| Cluster ID | Name | Description |
|------------|------|-------------|
| 0 (0x0000) | genBasic | Basic device information |
| 1 (0x0001) | genPowerCfg | Battery/power configuration |
| 3 (0x0003) | genIdentify | Identify (blinking) |
| 4 (0x0004) | genGroups | Group membership |
| 5 (0x0005) | genScenes | Scene storage |
| 6 (0x0006) | genOnOff | On/Off control |
| 8 (0x0008) | genLevelCtrl | Level/dimming control |
| 768 (0x0300) | lightingColorCtrl | Color control |
| 1024 (0x0400) | msIlluminanceMeasurement | Light sensor |
| 1026 (0x0402) | msTemperatureMeasurement | Temperature sensor |
| 1029 (0x0405) | msRelativeHumidity | Humidity sensor |
| 1030 (0x0406) | msOccupancySensing | Motion/occupancy sensor |
| 1280 (0x0500) | ssIasZone | Security sensor |
| 2820 (0x0B04) | haElectricalMeasurement | Power measurement |

---

## 12. MQTT Bridge Topics

### Device Information (published on startup/join/leave)
Topic: `zigbee2mqtt/bridge/devices`
```json
[
    {
        "ieee_address": "0x00158d0006b3a421",
        "type": "EndDevice",
        "network_address": 23100,
        "supported": true,
        "disabled": false,
        "friendly_name": "motion_sensor",
        "description": "Living room motion sensor",
        "endpoints": {
            "1": {
                "bindings": [],
                "configured_reportings": [],
                "clusters": {
                    "input": ["genBasic", "msOccupancySensing"],
                    "output": ["genOta"],
                    "scenes": []
                }
            }
        },
        "definition": {
            "source": "native",
            "model": "RTCGQ11LM",
            "vendor": "Xiaomi",
            "description": "Aqara human body movement and illuminance sensor"
        },
        "power_source": "Battery",
        "date_code": "20170627",
        "model_id": "lumi.sensor_motion.aq2",
        "interview_state": "SUCCESSFUL",
        "interviewing": false,
        "interview_completed": true
    }
]
```

---

## 13. File Operations and Safety

### Atomic Writes
Both `database.db` and `coordinator_backup.json` use atomic write operations:
1. Write to `.tmp` file
2. Call `fsync()` to ensure data is on disk
3. Rename `.tmp` to final filename (atomic on POSIX systems)

### Backup Recovery
If `database.db.tmp` exists on startup, it indicates a failed write:
```typescript
// Rename failed temp file with timestamp
const dateTmpPath = `${tmpPath}.${new Date().toISOString().replaceAll(":", "-")}`;
fs.renameSync(tmpPath, dateTmpPath);
logger.warning(`Found '${tmpPath}' when writing database, indicating past write failure`);
```

### Database Backup Path
From `configuration.yaml`:
```yaml
advanced:
    database_backup_path: data/database.db.backup
```

---

## 14. Summary: Key Differences from ZHA

| Aspect | ZHA (zigpy) | Z2M (zigbee-herdsman) |
|--------|-------------|----------------------|
| Database Format | SQLite3 | NDJSON (line-delimited JSON) |
| Schema Versioning | Via migrations | None (simple JSON) |
| Network Key Location | SQLite table | configuration.yaml |
| State Storage | Entity registry | state.json |
| Backup Format | Custom | open-coordinator-backup (standard) |
| Configuration | Home Assistant YAML | Own configuration.yaml |
| Entities | Single JSON per endpoint | Per-device with endpoint map |

### Address Formats
| Type | ZHA Format | Z2M Format |
|------|------------|------------|
| IEEE Address | `00:15:8d:00:06:b3:a4:21` | `0x00158d0006b3a421` |
| Network Address | Integer (e.g., 23100) | Integer (e.g., 23100) |
| Group ID | Integer | Integer |

---

## 15. References

### Source Code Files
- **Database**: `zigbee-herdsman/src/controller/database.ts`
- **Device model**: `zigbee-herdsman/src/controller/model/device.ts`
- **Endpoint model**: `zigbee-herdsman/src/controller/model/endpoint.ts`
- **Group model**: `zigbee-herdsman/src/controller/model/group.ts`
- **Controller**: `zigbee-herdsman/src/controller/controller.ts`
- **Backup utilities**: `zigbee-herdsman/src/utils/backup.ts`
- **Settings**: `zigbee2mqtt/lib/util/settings.ts`
- **State**: `zigbee2mqtt/lib/state.ts`

### External Resources
- [Zigbee2MQTT Documentation](https://www.zigbee2mqtt.io/)
- [Zigbee2MQTT GitHub](https://github.com/Koenkk/zigbee2mqtt)
- [zigbee-herdsman GitHub](https://github.com/Koenkk/zigbee-herdsman)
- [open-coordinator-backup Standard](https://github.com/zigpy/open-coordinator-backup)
