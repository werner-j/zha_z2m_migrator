# ZHA (Zigbee Home Automation) Data Storage Research

## Overview

This document details how Home Assistant's ZHA integration stores its data and configuration. ZHA uses the **zigpy** library as its underlying Zigbee stack, which handles the database storage.

---

## 1. Database Location

### File Path
- **Default filename**: `zigbee.db`
- **Default location**: Home Assistant config directory (e.g., `/config/zigbee.db` or `~/.homeassistant/zigbee.db`)
- **Configuration option**: Can be overridden via `configuration.yaml`:
  ```yaml
  zha:
    database_path: /custom/path/zigbee.db
  ```

### Configuration Constant
From `homeassistant/components/zha/const.py`:
```python
DEFAULT_DATABASE_NAME = "zigbee.db"
```

The path is resolved in `homeassistant/components/zha/helpers.py`:
```python
database = ha_zha_data.yaml_config.get(
    CONF_DATABASE,
    hass.config.path(DEFAULT_DATABASE_NAME),  # defaults to config_dir/zigbee.db
)
```

### File Format
- **Format**: SQLite3 database
- **Current Schema Version**: **13** (as of late 2024)
- **Minimum SQLite Version Required**: 3.24.0
- **Journal Mode**: WAL (Write-Ahead Logging)

---

## 2. Database Schema (Version 13)

### Tables Overview

| Table Name | Description |
|------------|-------------|
| `devices_v13` | All paired Zigbee devices |
| `endpoints_v13` | Device endpoints |
| `clusters_v13` | Zigbee clusters (both server/client) |
| `attributes_cache_v13` | Cached attribute values |
| `node_descriptors_v13` | Device node descriptors |
| `neighbors_v13` | Network topology - neighbor information |
| `routes_v13` | Network routing table |
| `groups_v13` | Zigbee groups |
| `group_members_v13` | Group membership |
| `relays_v13` | Source routing relay information |
| `unsupported_attributes_v13` | Attributes marked as unsupported |
| `network_backups_v13` | Network backup snapshots (JSON) |

---

## 3. Detailed Table Schemas

### devices_v13 (Device Storage)
```sql
CREATE TABLE devices_v13 (
    ieee ieee NOT NULL,           -- IEEE address (EUI64) - e.g., "00:11:22:33:44:55:66:77"
    nwk INTEGER NOT NULL,         -- Network (short) address - 16-bit
    status INTEGER NOT NULL,      -- Device status enum
    last_seen REAL NOT NULL       -- Unix timestamp (float) of last communication
);

CREATE UNIQUE INDEX devices_idx_v13 ON devices_v13(ieee);
```

**Device Status Values** (from `zigpy.device.Status`):
- `0` = NEW
- `1` = ZDO_INIT
- `2` = ENDPOINTS_INIT

### endpoints_v13
```sql
CREATE TABLE endpoints_v13 (
    ieee ieee NOT NULL,           -- Device IEEE address (foreign key)
    endpoint_id INTEGER NOT NULL, -- Endpoint number (1-254, 0 is ZDO)
    profile_id INTEGER NOT NULL,  -- ZCL Profile ID (0x0104 = HA, 0xC05E = ZLL)
    device_type INTEGER NOT NULL, -- Device type within profile
    status INTEGER NOT NULL,      -- Endpoint status

    FOREIGN KEY(ieee) REFERENCES devices_v13(ieee) ON DELETE CASCADE
);

CREATE UNIQUE INDEX endpoint_idx_v13 ON endpoints_v13(ieee, endpoint_id);
```

**Common Profile IDs**:
- `0x0104` = Zigbee Home Automation (ZHA)
- `0xC05E` = Zigbee Light Link (ZLL)

### clusters_v13
```sql
CREATE TABLE clusters_v13 (
    ieee ieee NOT NULL,
    endpoint_id INTEGER NOT NULL,
    cluster_type INTEGER NOT NULL,  -- 0 = Server (in_cluster), 1 = Client (out_cluster)
    cluster_id INTEGER NOT NULL,    -- Cluster ID (e.g., 0x0006 = On/Off)

    FOREIGN KEY(ieee, endpoint_id) REFERENCES endpoints_v13(ieee, endpoint_id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX clusters_idx_v13 ON clusters_v13(ieee, endpoint_id, cluster_type, cluster_id);
```

**Cluster Types** (from `zigpy.zcl.ClusterType`):
- `0` = Server (in_cluster) - device implements the cluster
- `1` = Client (out_cluster) - device sends commands to this cluster

### attributes_cache_v13
```sql
CREATE TABLE attributes_cache_v13 (
    ieee ieee NOT NULL,
    endpoint_id INTEGER NOT NULL,
    cluster_type INTEGER NOT NULL,
    cluster_id INTEGER NOT NULL,
    attr_id INTEGER NOT NULL,       -- Attribute ID within the cluster
    value BLOB NOT NULL,            -- Cached attribute value (Python pickle)
    last_updated REAL NOT NULL,     -- Unix timestamp of last update

    FOREIGN KEY(ieee) REFERENCES devices_v13(ieee) ON DELETE CASCADE
);

CREATE UNIQUE INDEX attributes_cache_idx_v13 
    ON attributes_cache_v13(ieee, endpoint_id, cluster_type, cluster_id, attr_id);
```

**Important Cached Attributes**:
- Basic cluster (0x0000):
  - `attr_id=4`: Manufacturer name
  - `attr_id=5`: Model identifier

### node_descriptors_v13
```sql
CREATE TABLE node_descriptors_v13 (
    ieee ieee NOT NULL,

    logical_type INTEGER NOT NULL,                    -- 0=Coordinator, 1=Router, 2=EndDevice
    complex_descriptor_available INTEGER NOT NULL,
    user_descriptor_available INTEGER NOT NULL,
    reserved INTEGER NOT NULL,
    aps_flags INTEGER NOT NULL,
    frequency_band INTEGER NOT NULL,                  -- 2.4GHz = 0x08
    mac_capability_flags INTEGER NOT NULL,
    manufacturer_code INTEGER NOT NULL,              -- Manufacturer-specific code
    maximum_buffer_size INTEGER NOT NULL,
    maximum_incoming_transfer_size INTEGER NOT NULL,
    server_mask INTEGER NOT NULL,
    maximum_outgoing_transfer_size INTEGER NOT NULL,
    descriptor_capability_field INTEGER NOT NULL,

    FOREIGN KEY(ieee) REFERENCES devices_v13(ieee) ON DELETE CASCADE
);

CREATE UNIQUE INDEX node_descriptors_idx_v13 ON node_descriptors_v13(ieee);
```

**Logical Types**:
- `0` = Coordinator
- `1` = Router
- `2` = End Device

### neighbors_v13 (Network Topology)
```sql
CREATE TABLE neighbors_v13 (
    device_ieee ieee NOT NULL,        -- Device that reported these neighbors
    extended_pan_id ieee NOT NULL,    -- Network Extended PAN ID
    ieee ieee NOT NULL,               -- Neighbor's IEEE address
    nwk INTEGER NOT NULL,             -- Neighbor's network address
    device_type INTEGER NOT NULL,     -- Neighbor device type
    rx_on_when_idle INTEGER NOT NULL, -- Whether device listens when idle
    relationship INTEGER NOT NULL,    -- Parent/Child/Sibling relationship
    reserved1 INTEGER NOT NULL,
    permit_joining INTEGER NOT NULL,
    reserved2 INTEGER NOT NULL,
    depth INTEGER NOT NULL,           -- Network depth
    lqi INTEGER NOT NULL,             -- Link Quality Indicator (0-255)

    FOREIGN KEY(device_ieee) REFERENCES devices_v13(ieee) ON DELETE CASCADE
);

CREATE INDEX neighbors_idx_v13 ON neighbors_v13(device_ieee);
```

### routes_v13
```sql
CREATE TABLE routes_v13 (
    device_ieee ieee NOT NULL,
    dst_nwk INTEGER NOT NULL,            -- Destination network address
    route_status INTEGER NOT NULL,
    memory_constrained INTEGER NOT NULL,
    many_to_one INTEGER NOT NULL,
    route_record_required INTEGER NOT NULL,
    reserved INTEGER NOT NULL,
    next_hop INTEGER NOT NULL            -- Next hop network address
);

CREATE INDEX routes_idx_v13 ON routes_v13(device_ieee);
```

### groups_v13
```sql
CREATE TABLE groups_v13 (
    group_id INTEGER NOT NULL,  -- Zigbee group ID (16-bit)
    name TEXT NOT NULL          -- User-friendly group name
);

CREATE UNIQUE INDEX groups_idx_v13 ON groups_v13(group_id);
```

### group_members_v13
```sql
CREATE TABLE group_members_v13 (
    group_id INTEGER NOT NULL,
    ieee ieee NOT NULL,
    endpoint_id INTEGER NOT NULL,

    FOREIGN KEY(group_id) REFERENCES groups_v13(group_id) ON DELETE CASCADE,
    FOREIGN KEY(ieee, endpoint_id) REFERENCES endpoints_v13(ieee, endpoint_id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX group_members_idx_v13 ON group_members_v13(group_id, ieee, endpoint_id);
```

### relays_v13
```sql
CREATE TABLE relays_v13 (
    ieee ieee NOT NULL,
    relays BLOB NOT NULL,  -- Serialized list of relay addresses

    FOREIGN KEY(ieee) REFERENCES devices_v13(ieee) ON DELETE CASCADE
);

CREATE UNIQUE INDEX relays_idx_v13 ON relays_v13(ieee);
```

### unsupported_attributes_v13
```sql
CREATE TABLE unsupported_attributes_v13 (
    ieee ieee NOT NULL,
    endpoint_id INTEGER NOT NULL,
    cluster_type INTEGER NOT NULL,
    cluster_id INTEGER NOT NULL,
    attr_id INTEGER NOT NULL,

    FOREIGN KEY(ieee) REFERENCES devices_v13(ieee) ON DELETE CASCADE,
    FOREIGN KEY(ieee, endpoint_id, cluster_type, cluster_id) 
        REFERENCES clusters_v13(ieee, endpoint_id, cluster_type, cluster_id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX unsupported_attributes_idx_v13 
    ON unsupported_attributes_v13(ieee, endpoint_id, cluster_type, cluster_id, attr_id);
```

### network_backups_v13
```sql
CREATE TABLE network_backups_v13 (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    backup_json TEXT NOT NULL  -- JSON serialized NetworkBackup object
);
```

---

## 4. Coordinator/Adapter Information

The coordinator (adapter) information is stored in two places:

### 4.1 In the Database (as a device)
The coordinator is stored in `devices_v13` like any other device, but with:
- IEEE address: The adapter's IEEE address
- NWK address: `0x0000` (coordinators always have NWK 0)
- Node descriptor logical_type: `0` (Coordinator)

### 4.2 In Network Backups (network_backups_v13)
The backup JSON contains `node_info`:
```json
{
  "node_info": {
    "nwk": "0000",
    "ieee": "00:11:22:33:44:55:66:77",
    "logical_type": "coordinator",
    "model": "EZSP",
    "manufacturer": "Silicon Labs",
    "version": "7.2.0.0"
  }
}
```

### 4.3 In State Object (Runtime)
From `zigpy/state.py`:
```python
@dataclasses.dataclass
class NodeInfo:
    nwk: t.NWK = t.NWK(0xFFFE)
    ieee: t.EUI64 = ...
    logical_type: zdo_t.LogicalType = zdo_t.LogicalType.EndDevice
    model: str | None = None
    manufacturer: str | None = None
    version: str | None = None
```

---

## 5. Network Key Storage

### Location
The network key is stored in the `network_backups_v13` table as part of the backup JSON.

### Structure (from `zigpy/state.py`)
```python
@dataclasses.dataclass
class Key:
    key: t.KeyData = ...        # 16-byte network key
    tx_counter: t.uint32_t = 0  # Frame counter for transmissions
    rx_counter: t.uint32_t = 0  # Frame counter for receptions
    seq: t.uint8_t = 0          # Key sequence number
    partner_ieee: t.EUI64 = ... # For link keys, the partner device

@dataclasses.dataclass
class NetworkInfo:
    extended_pan_id: t.ExtendedPanId = ...
    pan_id: t.PanId = ...
    nwk_update_id: t.uint8_t = ...
    nwk_manager_id: t.NWK = ...
    channel: t.uint8_t = 0
    channel_mask: t.Channels = ...
    security_level: t.uint8_t = 0
    network_key: Key = ...           # THE NETWORK KEY
    tc_link_key: Key = ...           # Trust Center link key
    key_table: list[Key] = ...       # Individual device link keys
    children: list[t.EUI64] = ...
    nwk_addresses: dict[t.EUI64, t.NWK] = ...
    stack_specific: dict[str, Any] = ...  # Radio-specific data
```

### Backup JSON Format
```json
{
  "version": 1,
  "backup_time": "2024-01-15T10:30:00+00:00",
  "network_info": {
    "extended_pan_id": "00:11:22:33:44:55:66:77",
    "pan_id": "1234",
    "nwk_update_id": 0,
    "nwk_manager_id": "0000",
    "channel": 15,
    "channel_mask": [11, 15, 20, 25],
    "security_level": 5,
    "network_key": {
      "key": "01:02:03:04:05:06:07:08:09:0a:0b:0c:0d:0e:0f:10",
      "tx_counter": 12345,
      "rx_counter": 0,
      "seq": 0,
      "partner_ieee": "ff:ff:ff:ff:ff:ff:ff:ff"
    },
    "tc_link_key": {
      "key": "5a:69:67:42:65:65:41:6c:6c:69:61:6e:63:65:30:39",
      "tx_counter": 0,
      "rx_counter": 0,
      "seq": 0,
      "partner_ieee": "00:00:00:00:00:00:00:00"
    },
    "key_table": [],
    "children": [],
    "nwk_addresses": {
      "aa:bb:cc:dd:ee:ff:00:11": "1234"
    },
    "stack_specific": {},
    "metadata": {},
    "source": "zigpy"
  },
  "node_info": {
    "nwk": "0000",
    "ieee": "00:11:22:33:44:55:66:77",
    "logical_type": "coordinator"
  }
}
```

### Default Trust Center Link Key
The default TC link key used by Zigbee Alliance:
```python
CONF_NWK_TC_LINK_KEY_DEFAULT = t.KeyData.convert(
    "5A:69:67:42:65:65:41:6C:6C:69:61:6E:63:65:30:39"  # "ZigBeeAlliance09"
)
```

---

## 6. Device Configurations and Settings

### 6.1 ZHA Options (Home Assistant)
Stored in the config entry options (`.storage/core.config_entries`):
```json
{
  "options": {
    "custom_configuration": {
      "zha_options": {
        "default_light_transition": 0,
        "enhanced_light_transition": false,
        "light_transitioning_flag": true,
        "group_members_assume_state": true,
        "enable_identify_on_join": true,
        "consider_unavailable_mains": 7200,
        "consider_unavailable_battery": 21600,
        "enable_mains_startup_polling": true
      },
      "zha_alarm_options": {
        "alarm_master_code": "1234",
        "alarm_failed_tries": 3,
        "alarm_arm_requires_code": false
      }
    }
  }
}
```

### 6.2 Device-Specific Overrides
In `configuration.yaml`:
```yaml
zha:
  device_config:
    "00:11:22:33:44:55:66:77-1":  # IEEE-endpoint
      type: "switch"
```

### 6.3 Quirks Configuration
```yaml
zha:
  enable_quirks: true
  custom_quirks_path: /config/custom_zha_quirks/
```

---

## 7. All Files Involved in ZHA Configuration

### Primary Database
| File | Description |
|------|-------------|
| `zigbee.db` | Main SQLite database (zigpy) |
| `zigbee.db-shm` | SQLite shared memory file (WAL mode) |
| `zigbee.db-wal` | SQLite write-ahead log (WAL mode) |

### Home Assistant Configuration
| File | Description |
|------|-------------|
| `configuration.yaml` | ZHA YAML configuration |
| `.storage/core.config_entries` | Config entry data (device path, radio type, options) |
| `.storage/core.device_registry` | Device registry (names, areas, etc.) |
| `.storage/core.entity_registry` | Entity registry (entity IDs, customizations) |

### Config Entry Structure
The config entry (in `.storage/core.config_entries`) contains:
```json
{
  "entry_id": "abcd1234...",
  "version": 5,
  "domain": "zha",
  "title": "Zigbee Coordinator",
  "data": {
    "device": {
      "path": "/dev/ttyUSB0",
      "baudrate": 115200,
      "flow_control": null
    },
    "radio_type": "ezsp"
  },
  "options": { ... },
  "unique_id": "epid=0011223344556677"
}
```

---

## 8. Querying the Database

### Example: List All Devices
```sql
SELECT 
    d.ieee,
    d.nwk,
    d.status,
    datetime(d.last_seen, 'unixepoch') as last_seen,
    nd.logical_type,
    nd.manufacturer_code
FROM devices_v13 d
LEFT JOIN node_descriptors_v13 nd ON d.ieee = nd.ieee;
```

### Example: Get Device with Manufacturer/Model
```sql
SELECT 
    d.ieee,
    d.nwk,
    ac_mfr.value as manufacturer,
    ac_model.value as model
FROM devices_v13 d
LEFT JOIN attributes_cache_v13 ac_mfr 
    ON d.ieee = ac_mfr.ieee 
    AND ac_mfr.cluster_id = 0 
    AND ac_mfr.attr_id = 4
LEFT JOIN attributes_cache_v13 ac_model 
    ON d.ieee = ac_model.ieee 
    AND ac_model.cluster_id = 0 
    AND ac_model.attr_id = 5;
```

### Example: Get Network Key from Backup
```sql
SELECT 
    id,
    json_extract(backup_json, '$.backup_time') as backup_time,
    json_extract(backup_json, '$.network_info.network_key.key') as network_key,
    json_extract(backup_json, '$.network_info.channel') as channel,
    json_extract(backup_json, '$.network_info.pan_id') as pan_id,
    json_extract(backup_json, '$.network_info.extended_pan_id') as extended_pan_id
FROM network_backups_v13
ORDER BY id DESC
LIMIT 1;
```

### Example: List All Endpoints and Clusters
```sql
SELECT 
    e.ieee,
    e.endpoint_id,
    e.profile_id,
    e.device_type,
    c.cluster_type,
    c.cluster_id
FROM endpoints_v13 e
JOIN clusters_v13 c ON e.ieee = c.ieee AND e.endpoint_id = c.endpoint_id
ORDER BY e.ieee, e.endpoint_id, c.cluster_type, c.cluster_id;
```

---

## 9. Open Coordinator Backup Format

ZHA/zigpy supports the **Open Coordinator Backup** format for interoperability:

```json
{
  "metadata": {
    "version": 1,
    "format": "zigpy/open-coordinator-backup",
    "source": "zigpy",
    "internal": {
      "creation_time": "2024-01-15T10:30:00+00:00",
      "node": { ... },
      "network": { ... }
    }
  },
  "stack_specific": { },
  "coordinator_ieee": "0011223344556677",
  "pan_id": "1234",
  "extended_pan_id": "0011223344556677",
  "nwk_update_id": 0,
  "security_level": 5,
  "channel": 15,
  "channel_mask": [11, 15, 20, 25],
  "network_key": {
    "key": "01020304050607080910111213141516",
    "sequence_number": 0,
    "frame_counter": 12345
  },
  "devices": [
    {
      "ieee_address": "aabbccddeeff0011",
      "nwk_address": "1234",
      "is_child": false,
      "link_key": {
        "key": "...",
        "tx_counter": 0,
        "rx_counter": 0
      }
    }
  ]
}
```

---

## 10. Source Code References

| Component | Repository | Path |
|-----------|------------|------|
| ZHA Integration | home-assistant/core | `homeassistant/components/zha/` |
| zigpy Library | zigpy/zigpy | `zigpy/` |
| Database Handler | zigpy/zigpy | `zigpy/appdb.py` |
| Database Schemas | zigpy/zigpy | `zigpy/appdb_schemas/schema_v*.sql` |
| State Classes | zigpy/zigpy | `zigpy/state.py` |
| Backup Manager | zigpy/zigpy | `zigpy/backups.py` |
| ZHA Library | zigpy/zha | `zha/` |

---

## 11. Key Classes and Their Roles

### zigpy.appdb.PersistingListener
- Main database handler class
- Handles all CRUD operations for devices, clusters, attributes
- Manages database migrations between schema versions
- Event-driven: reacts to device/attribute changes

### zigpy.state.NetworkInfo
- Holds complete network configuration
- Contains network key, PAN ID, channel, etc.
- Used for backup/restore operations

### zigpy.state.NodeInfo
- Coordinator/device node information
- IEEE address, NWK address, device type
- Manufacturer and model information

### zigpy.backups.NetworkBackup
- Complete network state snapshot
- Can be serialized to JSON
- Used for migration between coordinators

### zigpy.backups.BackupManager
- Manages backup creation and restoration
- Periodic backup support
- Handles frame counter management

---

## Summary

ZHA stores all Zigbee network data in a SQLite database called `zigbee.db`. The database contains:

1. **Device information**: IEEE addresses, NWK addresses, last seen times
2. **Device structure**: Endpoints, clusters, node descriptors
3. **Attribute cache**: Manufacturer names, model names, and other ZCL attributes
4. **Network topology**: Neighbors and routing information
5. **Groups**: Zigbee group definitions and membership
6. **Network backups**: Complete network state including the **network key**

The network key and coordinator information are stored in the `network_backups_v13` table as JSON, making it possible to migrate to a new coordinator or restore the network after issues.
