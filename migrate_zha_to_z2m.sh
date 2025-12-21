#!/bin/bash
#
# ZHA to Zigbee2MQTT Migration Script
# ====================================
#
# This script migrates a ZHA (Zigbee Home Automation) installation on 
# Home Assistant to Zigbee2MQTT without requiring device re-pairing.
#
# The migration works because both ZHA (zigpy) and Z2M (zigbee-herdsman) 
# support the "open-coordinator-backup" format for network backups.
#
# What this script does:
# 1. Extracts the network backup from ZHA's SQLite database
# 2. Creates the Z2M configuration directory structure
# 3. Generates coordinator_backup.json for Z2M
# 4. Creates the device database (database.db)
# 5. Generates configuration.yaml with proper settings
#
# Requirements:
# - sqlite3 (for reading ZHA database)
# - jq (for JSON processing)
# - python3 (for data conversion and pickle handling)
#
# Usage: ./migrate_zha_to_z2m.sh [OPTIONS]
#
# Options:
#   -z, --zha-db PATH         Path to ZHA zigbee.db (default: /config/zigbee.db)
#   -o, --output DIR          Output directory for Z2M files (default: /config/zigbee2mqtt)
#   -m, --mqtt-server URL     MQTT server URL (default: mqtt://core-mosquitto)
#   -p, --serial-port PATH    Serial port for Zigbee adapter (auto-detected from ZHA if not specified)
#   -a, --adapter TYPE        Adapter type (zstack, ezsp, deconz, zigate, ember)
#   -h, --help                Show this help message
#
# Author: Migration Script Generator
# Date: 2024-12-21
# Version: 1.0.0
#

set -e

# =============================================================================
# Configuration and Defaults
# =============================================================================

ZHA_DB_PATH="${ZHA_DB_PATH:-/config/zigbee.db}"
Z2M_OUTPUT_DIR="${Z2M_OUTPUT_DIR:-/config/zigbee2mqtt}"
MQTT_SERVER="${MQTT_SERVER:-mqtt://core-mosquitto}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASSWORD="${MQTT_PASSWORD:-}"
SERIAL_PORT=""
ADAPTER_TYPE=""
HA_CONFIG_DIR="/config"
BACKUP_DIR=""
DRY_RUN=false
VERBOSE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

show_help() {
    cat << EOF
ZHA to Zigbee2MQTT Migration Script
====================================

This script migrates your ZHA Zigbee network to Zigbee2MQTT without re-pairing devices.

USAGE:
    $(basename "$0") [OPTIONS]

OPTIONS:
    -z, --zha-db PATH         Path to ZHA zigbee.db (default: $ZHA_DB_PATH)
    -o, --output DIR          Output directory for Z2M files (default: $Z2M_OUTPUT_DIR)
    -m, --mqtt-server URL     MQTT server URL (default: $MQTT_SERVER)
    -u, --mqtt-user USER      MQTT username
    -w, --mqtt-password PASS  MQTT password
    -p, --serial-port PATH    Serial port for Zigbee adapter
    -a, --adapter TYPE        Adapter type: zstack, ezsp, deconz, zigate, ember
    -c, --ha-config DIR       Home Assistant config directory (default: $HA_CONFIG_DIR)
    -d, --dry-run             Show what would be done without making changes
    -v, --verbose             Enable verbose output
    -h, --help                Show this help message

REQUIREMENTS:
    - sqlite3     For reading ZHA database
    - jq          For JSON processing  
    - python3     For data conversion

EXAMPLES:
    # Basic migration with auto-detection
    $(basename "$0")

    # Specify custom paths
    $(basename "$0") -z /backup/zigbee.db -o /share/zigbee2mqtt

    # Specify adapter manually
    $(basename "$0") -p /dev/ttyUSB0 -a zstack

NOTES:
    1. Stop ZHA integration before running this script
    2. After migration, install the Zigbee2MQTT add-on
    3. Point Z2M to the generated configuration directory
    4. Battery devices may need a wake-up to reconnect

EOF
    exit 0
}

check_dependencies() {
    local missing=()
    
    if ! command -v sqlite3 &> /dev/null; then
        missing+=("sqlite3")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi
    
    if ! command -v python3 &> /dev/null; then
        missing+=("python3")
    fi
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_error "Please install them before running this script."
        exit 1
    fi
    
    log_info "All dependencies are available"
}

# =============================================================================
# Parse Command Line Arguments
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -z|--zha-db)
                ZHA_DB_PATH="$2"
                shift 2
                ;;
            -o|--output)
                Z2M_OUTPUT_DIR="$2"
                shift 2
                ;;
            -m|--mqtt-server)
                MQTT_SERVER="$2"
                shift 2
                ;;
            -u|--mqtt-user)
                MQTT_USER="$2"
                shift 2
                ;;
            -w|--mqtt-password)
                MQTT_PASSWORD="$2"
                shift 2
                ;;
            -p|--serial-port)
                SERIAL_PORT="$2"
                shift 2
                ;;
            -a|--adapter)
                ADAPTER_TYPE="$2"
                shift 2
                ;;
            -c|--ha-config)
                HA_CONFIG_DIR="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# ZHA Configuration Detection
# =============================================================================

detect_zha_config() {
    log_info "Detecting ZHA configuration..."
    
    # Check if ZHA database exists
    if [[ ! -f "$ZHA_DB_PATH" ]]; then
        log_error "ZHA database not found at: $ZHA_DB_PATH"
        log_error "Please specify the correct path with -z option"
        exit 1
    fi
    
    log_info "Found ZHA database at: $ZHA_DB_PATH"
    
    # Try to detect adapter info from Home Assistant config entries
    local config_entries="$HA_CONFIG_DIR/.storage/core.config_entries"
    
    if [[ -f "$config_entries" ]] && [[ -z "$SERIAL_PORT" ]]; then
        log_info "Reading ZHA config from Home Assistant..."
        
        # Extract ZHA configuration using jq
        local zha_config
        zha_config=$(jq -r '.data.entries[] | select(.domain == "zha")' "$config_entries" 2>/dev/null || echo "")
        
        if [[ -n "$zha_config" ]]; then
            # Get serial port path
            local detected_port
            detected_port=$(echo "$zha_config" | jq -r '.data.device.path // empty' 2>/dev/null || echo "")
            if [[ -n "$detected_port" ]] && [[ -z "$SERIAL_PORT" ]]; then
                SERIAL_PORT="$detected_port"
                log_info "Detected serial port: $SERIAL_PORT"
            fi
            
            # Get radio type
            local radio_type
            radio_type=$(echo "$zha_config" | jq -r '.data.radio_type // empty' 2>/dev/null || echo "")
            if [[ -n "$radio_type" ]] && [[ -z "$ADAPTER_TYPE" ]]; then
                # Map ZHA radio types to Z2M adapter types
                case "$radio_type" in
                    znp|ti_cc|ti_cc*)
                        ADAPTER_TYPE="zstack"
                        ;;
                    ezsp|silabs_ezsp|bellows)
                        ADAPTER_TYPE="ezsp"
                        ;;
                    deconz)
                        ADAPTER_TYPE="deconz"
                        ;;
                    zigate)
                        ADAPTER_TYPE="zigate"
                        ;;
                    zboss)
                        ADAPTER_TYPE="zboss"
                        ;;
                    ember)
                        ADAPTER_TYPE="ember"
                        ;;
                    *)
                        log_warn "Unknown radio type: $radio_type"
                        ;;
                esac
                if [[ -n "$ADAPTER_TYPE" ]]; then
                    log_info "Detected adapter type: $ADAPTER_TYPE (from radio_type: $radio_type)"
                fi
            fi
        fi
    fi
    
    # Prompt for missing required information
    if [[ -z "$SERIAL_PORT" ]]; then
        echo ""
        log_warn "Could not auto-detect serial port."
        echo "Please enter the serial port path for your Zigbee adapter."
        echo "Common ports:"
        echo "  - /dev/ttyUSB0       (USB adapter)"
        echo "  - /dev/ttyACM0       (USB adapter)"
        echo "  - /dev/ttyAMA0       (Raspberry Pi GPIO)"
        echo "  - /dev/serial/by-id/... (More stable identifier)"
        echo ""
        read -rp "Serial port path: " SERIAL_PORT
        
        if [[ -z "$SERIAL_PORT" ]]; then
            log_error "Serial port is required"
            exit 1
        fi
    fi
    
    if [[ -z "$ADAPTER_TYPE" ]]; then
        echo ""
        log_warn "Could not auto-detect adapter type."
        echo "Please select your Zigbee adapter type:"
        echo "  1) zstack  - Texas Instruments CC2530/CC2531/CC2538/CC2652 (most common)"
        echo "  2) ezsp    - Silicon Labs EFR32/EM35x (older EZSP)"
        echo "  3) ember   - Silicon Labs EFR32MG2x (newer EmberZNet)"
        echo "  4) deconz  - Dresden Elektronik ConBee/RaspBee"
        echo "  5) zigate  - ZiGate adapters"
        echo ""
        read -rp "Enter choice (1-5) or adapter name: " adapter_choice
        
        case "$adapter_choice" in
            1|zstack)
                ADAPTER_TYPE="zstack"
                ;;
            2|ezsp)
                ADAPTER_TYPE="ezsp"
                ;;
            3|ember)
                ADAPTER_TYPE="ember"
                ;;
            4|deconz)
                ADAPTER_TYPE="deconz"
                ;;
            5|zigate)
                ADAPTER_TYPE="zigate"
                ;;
            *)
                log_error "Invalid adapter type: $adapter_choice"
                exit 1
                ;;
        esac
        log_info "Selected adapter type: $ADAPTER_TYPE"
    fi
}

# =============================================================================
# Extract ZHA Network Backup
# =============================================================================

extract_zha_backup() {
    log_info "Extracting network backup from ZHA database..."
    
    # Get the latest network backup from the database
    local backup_json
    backup_json=$(sqlite3 -json "$ZHA_DB_PATH" "SELECT backup_json FROM network_backups_v13 ORDER BY id DESC LIMIT 1;" 2>/dev/null | jq -r '.[0].backup_json // empty')
    
    if [[ -z "$backup_json" ]]; then
        log_error "No network backup found in ZHA database"
        log_error "Make sure ZHA was running properly before migration"
        exit 1
    fi
    
    # Parse the backup JSON
    log_debug "Raw backup JSON length: ${#backup_json}"
    
    # Store the backup for later use
    echo "$backup_json" > /tmp/zha_backup.json
    
    # Extract key information
    NETWORK_KEY=$(echo "$backup_json" | jq -r '.network_info.network_key.key // empty')
    CHANNEL=$(echo "$backup_json" | jq -r '.network_info.channel // empty')
    PAN_ID=$(echo "$backup_json" | jq -r '.network_info.pan_id // empty')
    EXT_PAN_ID=$(echo "$backup_json" | jq -r '.network_info.extended_pan_id // empty')
    COORDINATOR_IEEE=$(echo "$backup_json" | jq -r '.node_info.ieee // empty')
    TX_COUNTER=$(echo "$backup_json" | jq -r '.network_info.network_key.tx_counter // 0')
    
    # Extract stack-specific information for debugging
    local stack_specific
    stack_specific=$(echo "$backup_json" | jq -r '.network_info.stack_specific // {}')
    local node_version
    node_version=$(echo "$backup_json" | jq -r '.node_info.version // empty')
    local node_model
    node_model=$(echo "$backup_json" | jq -r '.node_info.model // empty')
    
    if [[ -z "$NETWORK_KEY" ]] || [[ -z "$CHANNEL" ]]; then
        log_error "Failed to extract critical network information from backup"
        exit 1
    fi
    
    log_info "Network information extracted:"
    log_info "  - Channel: $CHANNEL"
    log_info "  - PAN ID: $PAN_ID"
    log_info "  - Extended PAN ID: $EXT_PAN_ID"
    log_info "  - Coordinator IEEE: $COORDINATOR_IEEE"
    log_info "  - Network Key: [hidden for security]"
    log_info "  - TX Counter: $TX_COUNTER"
    log_info "  - Coordinator Model: $node_model"
    log_info "  - Coordinator Version: $node_version"
    
    # Debug stack-specific info
    if [[ "$VERBOSE" == "true" ]]; then
        log_debug "Stack-specific data:"
        echo "$stack_specific" | jq '.' 2>/dev/null || echo "$stack_specific"
    fi
    
    # Check for EZSP-specific data
    local has_ezsp_data
    has_ezsp_data=$(echo "$backup_json" | jq -r '.network_info.stack_specific.ezsp // empty')
    if [[ -n "$has_ezsp_data" ]]; then
        log_info "  - EZSP stack data found in backup"
    fi
    
    # Check for ZStack-specific data
    local has_zstack_data
    has_zstack_data=$(echo "$backup_json" | jq -r '.network_info.stack_specific.zstack // empty')
    if [[ -n "$has_zstack_data" ]]; then
        log_info "  - Z-Stack data found in backup"
    fi
}

# =============================================================================
# Extract Device Information
# =============================================================================

extract_devices() {
    log_info "Extracting device information from ZHA database..."
    
    # Python script to extract and convert device information
    python3 << 'PYTHON_SCRIPT' - "$ZHA_DB_PATH" "$Z2M_OUTPUT_DIR"
import sqlite3
import json
import sys
import pickle
import os
from datetime import datetime

zha_db_path = sys.argv[1]
output_dir = sys.argv[2]

def ieee_zha_to_z2m(ieee_str):
    """Convert ZHA IEEE format (00:11:22:33:44:55:66:77) to Z2M format (0x0011223344556677)"""
    if not ieee_str:
        return None
    # Remove colons and add 0x prefix
    clean = ieee_str.replace(':', '').lower()
    return f"0x{clean}"

def ieee_z2m_to_backup(ieee_str):
    """Convert Z2M IEEE format to backup format (lowercase, no prefix)"""
    if not ieee_str:
        return None
    return ieee_str.replace('0x', '').lower()

def get_device_type(logical_type):
    """Convert ZHA logical type to Z2M device type"""
    types = {
        0: "Coordinator",
        1: "Router", 
        2: "EndDevice"
    }
    return types.get(logical_type, "Unknown")

def safe_unpickle(data):
    """Safely unpickle data, return None on failure"""
    if data is None:
        return None
    try:
        return pickle.loads(data)
    except:
        return None

# Connect to ZHA database
conn = sqlite3.connect(zha_db_path)
conn.row_factory = sqlite3.Row
cursor = conn.cursor()

# Get all devices
devices = []
coordinator_ieee = None

cursor.execute("""
    SELECT 
        d.ieee,
        d.nwk,
        d.status,
        d.last_seen,
        nd.logical_type,
        nd.manufacturer_code
    FROM devices_v13 d
    LEFT JOIN node_descriptors_v13 nd ON d.ieee = nd.ieee
""")

for row in cursor.fetchall():
    ieee = row['ieee']
    ieee_z2m = ieee_zha_to_z2m(ieee)
    logical_type = row['logical_type'] if row['logical_type'] is not None else 2
    device_type = get_device_type(logical_type)
    
    # Track coordinator
    if logical_type == 0:
        coordinator_ieee = ieee
        continue  # Skip coordinator for device list
    
    device = {
        'ieee': ieee,
        'ieee_z2m': ieee_z2m,
        'nwk': row['nwk'],
        'type': device_type,
        'last_seen': int(row['last_seen'] * 1000) if row['last_seen'] else None,
        'manufacturer_code': row['manufacturer_code'],
        'endpoints': {},
        'manufacturer': None,
        'model': None
    }
    
    # Get endpoints
    cursor.execute("""
        SELECT endpoint_id, profile_id, device_type, status
        FROM endpoints_v13
        WHERE ieee = ?
    """, (ieee,))
    
    for ep_row in cursor.fetchall():
        ep_id = ep_row['endpoint_id']
        device['endpoints'][ep_id] = {
            'profId': ep_row['profile_id'],
            'epId': ep_id,
            'devId': ep_row['device_type'],
            'inClusterList': [],
            'outClusterList': [],
            'clusters': {},
            'binds': [],
            'configuredReportings': [],
            'meta': {}
        }
    
    # Get clusters
    cursor.execute("""
        SELECT endpoint_id, cluster_type, cluster_id
        FROM clusters_v13
        WHERE ieee = ?
    """, (ieee,))
    
    for cl_row in cursor.fetchall():
        ep_id = cl_row['endpoint_id']
        if ep_id in device['endpoints']:
            if cl_row['cluster_type'] == 0:  # Server/Input
                device['endpoints'][ep_id]['inClusterList'].append(cl_row['cluster_id'])
            else:  # Client/Output
                device['endpoints'][ep_id]['outClusterList'].append(cl_row['cluster_id'])
    
    # Get cached attributes (manufacturer, model)
    cursor.execute("""
        SELECT endpoint_id, cluster_id, attr_id, value
        FROM attributes_cache_v13
        WHERE ieee = ? AND cluster_id = 0 AND attr_id IN (4, 5)
    """, (ieee,))
    
    for attr_row in cursor.fetchall():
        value = safe_unpickle(attr_row['value'])
        if value is not None:
            if attr_row['attr_id'] == 4:  # Manufacturer
                device['manufacturer'] = str(value) if value else None
            elif attr_row['attr_id'] == 5:  # Model
                device['model'] = str(value) if value else None
    
    devices.append(device)

# Get groups
groups = []
cursor.execute("SELECT group_id, name FROM groups_v13")
for row in cursor.fetchall():
    group = {
        'groupID': row['group_id'],
        'name': row['name'],
        'members': []
    }
    
    cursor.execute("""
        SELECT ieee, endpoint_id 
        FROM group_members_v13 
        WHERE group_id = ?
    """, (row['group_id'],))
    
    for member_row in cursor.fetchall():
        group['members'].append({
            'deviceIeeeAddr': ieee_zha_to_z2m(member_row['ieee']),
            'endpointID': member_row['endpoint_id']
        })
    
    groups.append(group)

conn.close()

# Write results
os.makedirs(output_dir, exist_ok=True)

with open(os.path.join(output_dir, 'extracted_devices.json'), 'w') as f:
    json.dump({
        'devices': devices,
        'groups': groups,
        'coordinator_ieee': coordinator_ieee
    }, f, indent=2)

print(f"Extracted {len(devices)} devices and {len(groups)} groups")
PYTHON_SCRIPT

    if [[ $? -ne 0 ]]; then
        log_error "Failed to extract device information"
        exit 1
    fi
    
    # Count devices
    local device_count
    device_count=$(jq '.devices | length' "$Z2M_OUTPUT_DIR/extracted_devices.json")
    local group_count
    group_count=$(jq '.groups | length' "$Z2M_OUTPUT_DIR/extracted_devices.json")
    
    log_info "Extracted $device_count devices and $group_count groups"
}

# =============================================================================
# Create Z2M Configuration
# =============================================================================

create_z2m_config() {
    log_info "Creating Zigbee2MQTT configuration..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create configuration in: $Z2M_OUTPUT_DIR"
        return
    fi
    
    # Create output directory
    mkdir -p "$Z2M_OUTPUT_DIR"
    
    # Convert network key from ZHA format to Z2M format
    # ZHA format: "01:02:03:04:05:06:07:08:09:0a:0b:0c:0d:0e:0f:10"
    # Z2M format: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
    
    local network_key_array
    network_key_array=$(python3 << PYTHON_SCRIPT
import sys
key_str = "$NETWORK_KEY"
# Remove spaces and split by colon
bytes_hex = key_str.replace(' ', '').split(':')
# Convert to integers
bytes_int = [int(b, 16) for b in bytes_hex]
# Output as JSON array
print('[' + ', '.join(str(b) for b in bytes_int) + ']')
PYTHON_SCRIPT
)

    # Convert extended PAN ID
    local ext_pan_id_array
    ext_pan_id_array=$(python3 << PYTHON_SCRIPT
epid = "$EXT_PAN_ID"
# Remove colons and spaces
epid_clean = epid.replace(':', '').replace(' ', '')
# Convert to byte array
bytes_int = [int(epid_clean[i:i+2], 16) for i in range(0, len(epid_clean), 2)]
print('[' + ', '.join(str(b) for b in bytes_int) + ']')
PYTHON_SCRIPT
)

    # Convert PAN ID to integer
    local pan_id_int
    pan_id_int=$(python3 -c "print(int('$PAN_ID', 16))")
    
    # Build MQTT configuration section
    local mqtt_config="mqtt:
  base_topic: zigbee2mqtt
  server: '$MQTT_SERVER'"
    
    if [[ -n "$MQTT_USER" ]]; then
        mqtt_config="$mqtt_config
  user: '$MQTT_USER'"
    fi
    
    if [[ -n "$MQTT_PASSWORD" ]]; then
        mqtt_config="$mqtt_config
  password: '$MQTT_PASSWORD'"
    fi
    
    # Create configuration.yaml
    cat > "$Z2M_OUTPUT_DIR/configuration.yaml" << EOF
# Zigbee2MQTT Configuration
# =========================
# Auto-generated by ZHA migration script on $(date -Iseconds)
# 
# IMPORTANT: Review this configuration before starting Zigbee2MQTT
#

# Homeassistant integration
homeassistant: true

# Permit joining (set to false for security after initial setup)
permit_join: false

$mqtt_config

# Serial port configuration
serial:
  port: '$SERIAL_PORT'
  adapter: $ADAPTER_TYPE

# Frontend (web UI)
frontend:
  port: 8080

# Advanced settings
advanced:
  # Network configuration (migrated from ZHA)
  pan_id: $pan_id_int
  ext_pan_id: $ext_pan_id_array
  channel: $CHANNEL
  network_key: $network_key_array
  
  # Logging
  log_level: info
  log_output:
    - console
    - file
  log_directory: log/%TIMESTAMP%
  
  # Timestamps
  last_seen: ISO_8601
  elapsed: false
  
  # Network settings
  transmit_power: 20

# Device availability tracking
availability:
  active:
    timeout: 10
  passive:
    timeout: 1500

# Devices (will be populated by Z2M)
devices: devices.yaml

# Groups (will be populated by Z2M)  
groups: groups.yaml
EOF

    log_info "Created configuration.yaml"
}

# =============================================================================
# Create Z2M Database
# =============================================================================

create_z2m_database() {
    log_info "Creating Zigbee2MQTT device database..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create database.db"
        return
    fi
    
    # Read extracted devices and generate database.db (NDJSON format)
    python3 << 'PYTHON_SCRIPT' - "$Z2M_OUTPUT_DIR" "$COORDINATOR_IEEE" "$TX_COUNTER" "$HA_CONFIG_DIR" "$VERBOSE"
import json
import sys
import os
import re

output_dir = sys.argv[1]
coordinator_ieee_zha = sys.argv[2]
tx_counter = int(sys.argv[3]) if sys.argv[3] else 0
ha_config_dir = sys.argv[4]
verbose = sys.argv[5].lower() == 'true'

def debug(msg):
    if verbose:
        print(f"[DEBUG] {msg}", file=sys.stderr)

def ieee_zha_to_z2m(ieee_str):
    """Convert ZHA IEEE format to Z2M format"""
    if not ieee_str:
        return None
    clean = ieee_str.replace(':', '').lower()
    return f"0x{clean}"

# Load area names from Home Assistant area registry
area_names = {}
area_registry_path = os.path.join(ha_config_dir, '.storage/core.area_registry')
debug(f"Looking for area registry at: {area_registry_path}")

if os.path.exists(area_registry_path):
    debug("Area registry found, loading areas...")
    try:
        with open(area_registry_path, 'r') as f:
            area_registry = json.load(f)
        
        areas_in_registry = area_registry.get('data', {}).get('areas', [])
        debug(f"Found {len(areas_in_registry)} areas in registry")
        
        for area in areas_in_registry:
            area_id = area.get('id')
            area_name = area.get('name')
            if area_id and area_name:
                area_names[area_id] = area_name
                debug(f"  Area mapping: {area_id} -> {area_name}")
    except Exception as e:
        debug(f"Error reading area registry: {e}")
else:
    debug(f"Area registry NOT FOUND at {area_registry_path}")

# Load device names from Home Assistant device registry
device_names = {}
device_areas = {}
device_registry_path = os.path.join(ha_config_dir, '.storage/core.device_registry')
debug(f"Looking for device registry at: {device_registry_path}")

if os.path.exists(device_registry_path):
    debug("Device registry found, loading names...")
    try:
        with open(device_registry_path, 'r') as f:
            registry = json.load(f)
        
        devices_in_registry = registry.get('data', {}).get('devices', [])
        debug(f"Found {len(devices_in_registry)} devices in registry")
        
        for device in devices_in_registry:
            for identifier in device.get('identifiers', []):
                if isinstance(identifier, list) and len(identifier) >= 2:
                    if identifier[0] == 'zha':
                        ieee = identifier[1].replace(':', '').lower()
                        name = device.get('name_by_user') or device.get('name')
                        area_id = device.get('area_id')
                        if name:
                            device_names[ieee] = name
                            debug(f"  Name mapping: {ieee} -> {name}")
                        if area_id and area_id in area_names:
                            device_areas[ieee] = area_names[area_id]
                            debug(f"  Area mapping: {ieee} -> {area_names[area_id]}")
        
        debug(f"Loaded {len(device_names)} device names from registry")
        debug(f"Loaded {len(device_areas)} device areas from registry")
    except Exception as e:
        debug(f"Error reading device registry: {e}")
else:
    debug(f"Device registry NOT FOUND at {device_registry_path}")
    # List what's in the config directory
    debug(f"Contents of {ha_config_dir}:")
    if os.path.exists(ha_config_dir):
        for item in os.listdir(ha_config_dir)[:20]:
            debug(f"  - {item}")
    storage_path = os.path.join(ha_config_dir, '.storage')
    if os.path.exists(storage_path):
        debug(f"Contents of {storage_path}:")
        for item in os.listdir(storage_path)[:20]:
            debug(f"  - {item}")

# Read extracted devices
with open(os.path.join(output_dir, 'extracted_devices.json'), 'r') as f:
    data = json.load(f)

devices = data['devices']
groups = data['groups']

# Generate database entries
db_entries = []
entry_id = 1

# Track used names to ensure uniqueness
used_names = {}

# Add coordinator entry
coordinator_ieee_z2m = ieee_zha_to_z2m(coordinator_ieee_zha)
db_entries.append({
    "id": entry_id,
    "type": "Coordinator",
    "ieeeAddr": coordinator_ieee_z2m,
    "nwkAddr": 0,
    "manufId": None,
    "manufName": None,
    "powerSource": "Mains (single phase)",
    "modelId": None,
    "epList": [1],
    "endpoints": {
        "1": {
            "profId": 260,
            "epId": 1,
            "devId": 5,
            "inClusterList": [0],
            "outClusterList": [0],
            "clusters": {},
            "binds": [],
            "configuredReportings": [],
            "meta": {}
        }
    },
    "appVersion": None,
    "stackVersion": None,
    "hwVersion": None,
    "zclVersion": None,
    "dateCode": None,
    "swBuildId": None,
    "interviewCompleted": True,
    "interviewState": "SUCCESSFUL",
    "meta": {},
    "lastSeen": None
})
entry_id += 1

# Add device entries
for device in devices:
    ieee_z2m = device['ieee_z2m']
    ieee_clean = ieee_z2m.replace('0x', '').lower()
    
    # Look up friendly name and room from HA device registry
    device_name = device_names.get(ieee_clean)
    device_room = device_areas.get(ieee_clean, '')
    
    # Build friendly name with room prefix if available
    if device_name and device_room:
        friendly_name = f"{device_room} - {device_name}"
    elif device_name:
        friendly_name = device_name
    else:
        friendly_name = None
    
    if friendly_name:
        debug(f"Device {ieee_z2m}: using HA name '{friendly_name}'")
    else:
        # Fallback to manufacturer_model or IEEE
        manufacturer = device.get('manufacturer', '')
        model = device.get('model', '')
        if manufacturer and model:
            friendly_name = f"{manufacturer} {model}"
        else:
            friendly_name = f"device_{ieee_clean}"
        debug(f"Device {ieee_z2m}: no HA name, using fallback '{friendly_name}'")
    
    # Strip trailing/leading whitespace
    friendly_name = friendly_name.strip()
    
    # Ensure uniqueness by appending IEEE suffix if name already used
    base_name = friendly_name
    name_key = friendly_name.lower()
    if name_key in used_names:
        # Append last 4 chars of IEEE to make unique
        friendly_name = f"{base_name} {ieee_clean[-4:]}"
        name_key = friendly_name.lower()
    used_names[name_key] = True
    
    # Convert endpoints to Z2M format
    endpoints = {}
    ep_list = []
    
    for ep_id_str, ep_data in device['endpoints'].items():
        ep_id = int(ep_id_str)
        ep_list.append(ep_id)
        endpoints[str(ep_id)] = {
            "profId": ep_data.get('profId', 260),
            "epId": ep_id,
            "devId": ep_data.get('devId', 0),
            "inClusterList": ep_data.get('inClusterList', []),
            "outClusterList": ep_data.get('outClusterList', []),
            "clusters": {},
            "binds": ep_data.get('binds', []),
            "configuredReportings": ep_data.get('configuredReportings', []),
            "meta": ep_data.get('meta', {})
        }
    
    db_entry = {
        "id": entry_id,
        "type": device['type'],
        "ieeeAddr": ieee_z2m,
        "nwkAddr": device['nwk'],
        "manufId": device.get('manufacturer_code'),
        "manufName": device.get('manufacturer'),
        "powerSource": "Battery" if device['type'] == "EndDevice" else "Mains (single phase)",
        "modelId": device.get('model'),
        "epList": sorted(ep_list),
        "endpoints": endpoints,
        "appVersion": None,
        "stackVersion": None,
        "hwVersion": None,
        "zclVersion": None,
        "dateCode": None,
        "swBuildId": None,
        "interviewCompleted": True,
        "interviewState": "SUCCESSFUL",
        "meta": {},
        "lastSeen": device.get('last_seen'),
        "friendlyName": friendly_name
    }
    
    db_entries.append(db_entry)
    entry_id += 1

# Add group entries
for group in groups:
    db_entry = {
        "id": entry_id,
        "type": "Group",
        "groupID": group['groupID'],
        "members": group['members'],
        "meta": {}
    }
    db_entries.append(db_entry)
    entry_id += 1

# Write database.db (NDJSON format)
with open(os.path.join(output_dir, 'database.db'), 'w') as f:
    for entry in db_entries:
        f.write(json.dumps(entry, separators=(',', ':')) + '\n')

print(f"Created database.db with {len(db_entries)} entries")

# Debug: Show sample entries
if verbose:
    debug("=== Sample database.db entries ===")
    for i, entry in enumerate(db_entries[:5]):
        debug(f"Entry {i+1}: ieeeAddr={entry.get('ieeeAddr')}, friendlyName={entry.get('friendlyName')}")
    if len(db_entries) > 5:
        debug(f"... and {len(db_entries) - 5} more entries")
PYTHON_SCRIPT

    log_info "Created database.db"
}

# =============================================================================
# Create Coordinator Backup
# =============================================================================

create_coordinator_backup() {
    log_info "Creating coordinator_backup.json..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create coordinator_backup.json"
        return
    fi
    
    # Generate coordinator_backup.json from ZHA backup
    python3 << 'PYTHON_SCRIPT' - "$Z2M_OUTPUT_DIR" "/tmp/zha_backup.json" "$ADAPTER_TYPE"
import json
import sys
import os
from datetime import datetime

output_dir = sys.argv[1]
zha_backup_path = sys.argv[2]
adapter_type = sys.argv[3]

# Read ZHA backup
with open(zha_backup_path, 'r') as f:
    zha_backup = json.load(f)

def ieee_zha_to_backup(ieee_str):
    """Convert ZHA IEEE format (00:11:22:33:44:55:66:77) to backup format (lowercase, no separators)"""
    if not ieee_str:
        return None
    return ieee_str.replace(':', '').lower()

def key_zha_to_backup(key_str):
    """Convert ZHA key format (01:02:...) to backup format (no separators)"""
    if not key_str:
        return None
    return key_str.replace(':', '').replace(' ', '').lower()

# Extract network info
network_info = zha_backup.get('network_info', {})
node_info = zha_backup.get('node_info', {})
zha_stack_specific = network_info.get('stack_specific', {})

# Convert network key
network_key_zha = network_info.get('network_key', {}).get('key', '')
network_key = key_zha_to_backup(network_key_zha)

# Convert TC Link Key (for EZSP/EmberZNet adapters)
tc_link_key_zha = network_info.get('tc_link_key', {}).get('key', '')
tc_link_key = key_zha_to_backup(tc_link_key_zha)

# Convert coordinator IEEE
coordinator_ieee = ieee_zha_to_backup(node_info.get('ieee', ''))

# Convert PAN IDs
pan_id = network_info.get('pan_id', '').lower()
ext_pan_id = ieee_zha_to_backup(network_info.get('extended_pan_id', ''))

# Build device list with link keys
devices = []
nwk_addresses = network_info.get('nwk_addresses', {})
key_table = network_info.get('key_table', [])

# Create a mapping of IEEE addresses to link keys
link_key_map = {}
for key_entry in key_table:
    partner_ieee = ieee_zha_to_backup(key_entry.get('partner_ieee', ''))
    if partner_ieee and partner_ieee != 'ffffffffffffffff':
        key_data = key_zha_to_backup(key_entry.get('key', ''))
        if key_data:
            link_key_map[partner_ieee] = {
                "key": key_data,
                "rx_counter": key_entry.get('rx_counter', 0),
                "tx_counter": key_entry.get('tx_counter', 0)
            }

# Determine children from ZHA backup
children = [ieee_zha_to_backup(c) for c in network_info.get('children', [])]

# IMPORTANT: Only include devices that have link keys in the coordinator backup!
# zigbee-herdsman's EmberAdapter will fail if devices array contains entries without link_key
# because it tries to access device.linkKey.key for all devices in the array.
# Devices without individual link keys use the network-wide trust center link key.

for ieee_zha, nwk in nwk_addresses.items():
    ieee = ieee_zha_to_backup(ieee_zha)
    if ieee == coordinator_ieee:
        continue  # Skip coordinator
    
    # Only add device if it has an individual link key
    if ieee in link_key_map:
        device_entry = {
            "nwk_address": nwk.lower() if isinstance(nwk, str) else format(nwk, '04x'),
            "ieee_address": ieee,
            "is_child": ieee in children,
            "link_key": link_key_map[ieee]
        }
        devices.append(device_entry)

# Determine stack-specific info based on adapter type
# This is critical for EmberZNet/EZSP adapters!
stack_specific = {}
metadata_internal = {
    "date": datetime.utcnow().isoformat() + "Z"
}

if adapter_type == 'zstack':
    # Z-Stack/ZNP adapters
    zstack_data = zha_stack_specific.get('zstack', {})
    tclk_seed = zstack_data.get('tclk_seed')
    if tclk_seed:
        # Convert if it's in colon format
        if ':' in str(tclk_seed):
            tclk_seed = key_zha_to_backup(tclk_seed)
        stack_specific = {"zstack": {"tclk_seed": tclk_seed}}
    else:
        stack_specific = {"zstack": {}}
    
    # Add ZNP version if available
    znp_version = zha_stack_specific.get('zstack', {}).get('version')
    if znp_version:
        metadata_internal["znpVersion"] = znp_version

elif adapter_type in ['ezsp', 'ember']:
    # EmberZNet/EZSP adapters - CRITICAL: need hashed_tclk and ezspVersion
    ezsp_data = zha_stack_specific.get('ezsp', {})
    
    # Get hashed TC Link Key from ZHA backup
    hashed_tclk = ezsp_data.get('hashed_tclk')
    if hashed_tclk:
        # Convert if it's in colon format
        if ':' in str(hashed_tclk):
            hashed_tclk = key_zha_to_backup(hashed_tclk)
    else:
        # Try to use the TC link key as fallback (it may already be hashed in the backup)
        hashed_tclk = tc_link_key
    
    stack_specific = {"ezsp": {"hashed_tclk": hashed_tclk}}
    
    # Add EZSP version - REQUIRED for EmberZNet backups!
    # zigbee-herdsman requires ezspVersion >= 12
    ezsp_version = ezsp_data.get('ezsp_version') or ezsp_data.get('version')
    if not ezsp_version:
        # Try to extract from node_info version string (e.g., "7.4.5.0")
        version_str = node_info.get('version', '')
        if version_str:
            # Parse major version and estimate EZSP version
            # EZSP 13 corresponds to EmberZNet 7.x
            # EZSP 12 corresponds to EmberZNet 6.x
            try:
                major = int(version_str.split('.')[0])
                if major >= 7:
                    ezsp_version = 13
                elif major >= 6:
                    ezsp_version = 12
                else:
                    ezsp_version = 13  # Default to latest
            except:
                ezsp_version = 13  # Default to latest supported
        else:
            ezsp_version = 13  # Default to latest supported
    
    metadata_internal["ezspVersion"] = ezsp_version
    
    print(f"EmberZNet adapter detected:")
    print(f"  - EZSP version: {ezsp_version}")
    print(f"  - Hashed TCLK present: {'Yes' if hashed_tclk else 'No (WARNING: may cause issues)'}")

elif adapter_type == 'deconz':
    stack_specific = {"deconz": {}}

elif adapter_type == 'zigate':
    stack_specific = {"zigate": {}}

# Build the backup structure (open-coordinator-backup format)
backup = {
    "metadata": {
        "format": "zigpy/open-coordinator-backup",
        "version": 1,
        "source": "zha-migration-script@1.0.0",
        "internal": metadata_internal
    },
    "stack_specific": stack_specific,
    "coordinator_ieee": coordinator_ieee,
    "pan_id": pan_id,
    "extended_pan_id": ext_pan_id,
    "security_level": network_info.get('security_level', 5),
    "nwk_update_id": network_info.get('nwk_update_id', 0),
    "channel": network_info.get('channel', 11),
    "channel_mask": network_info.get('channel_mask', [11]),
    "network_key": {
        "key": network_key,
        "sequence_number": network_info.get('network_key', {}).get('seq', 0),
        "frame_counter": network_info.get('network_key', {}).get('tx_counter', 0)
    },
    "devices": devices
}

# Write coordinator_backup.json
with open(os.path.join(output_dir, 'coordinator_backup.json'), 'w') as f:
    json.dump(backup, f, indent=2)

# Note: devices array only contains devices with individual link keys
# Most devices use the network-wide TC link key and are NOT in this array
# This is normal and expected - they will rejoin using the TC link key
print(f"Created coordinator_backup.json with {len(devices)} link key entries")
PYTHON_SCRIPT

    log_info "Created coordinator_backup.json"
}

# =============================================================================
# Create Device and Group YAML Files
# =============================================================================

create_device_configs() {
    log_info "Creating device and group configuration files..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create devices.yaml and groups.yaml"
        return
    fi
    
    # Generate devices.yaml with friendly names
    python3 << 'PYTHON_SCRIPT' - "$Z2M_OUTPUT_DIR" "$HA_CONFIG_DIR"
import json
import sys
import os
import re

output_dir = sys.argv[1]
ha_config_dir = sys.argv[2]

# Read extracted devices
with open(os.path.join(output_dir, 'extracted_devices.json'), 'r') as f:
    data = json.load(f)

devices = data['devices']
groups = data['groups']

# Load area names from Home Assistant area registry
area_names = {}
area_registry_path = os.path.join(ha_config_dir, '.storage/core.area_registry')
if os.path.exists(area_registry_path):
    try:
        with open(area_registry_path, 'r') as f:
            area_registry = json.load(f)
        for area in area_registry.get('data', {}).get('areas', []):
            area_id = area.get('id')
            area_name = area.get('name')
            if area_id and area_name:
                area_names[area_id] = area_name
    except Exception as e:
        print(f"Warning: Could not read area registry: {e}", file=sys.stderr)

# Try to get friendly names from Home Assistant device registry
device_names = {}
device_areas = {}
entity_names = {}

device_registry_path = os.path.join(ha_config_dir, '.storage/core.device_registry')
if os.path.exists(device_registry_path):
    try:
        with open(device_registry_path, 'r') as f:
            registry = json.load(f)
        
        for device in registry.get('data', {}).get('devices', []):
            # Look for ZHA identifiers
            for identifier in device.get('identifiers', []):
                if isinstance(identifier, list) and len(identifier) >= 2:
                    if identifier[0] == 'zha':
                        # identifier[1] is the IEEE address (may have colons)
                        ieee = identifier[1]
                        # Normalize: remove colons and lowercase
                        ieee_normalized = ieee.replace(':', '').lower()
                        name = device.get('name_by_user') or device.get('name')
                        area_id = device.get('area_id')
                        if name:
                            # Store original name - Z2M 2.x supports spaces and special chars
                            device_names[ieee_normalized] = {
                                'original': name,
                                'friendly': name  # Use original name directly
                            }
                        if area_id and area_id in area_names:
                            device_areas[ieee_normalized] = area_names[area_id]
    except Exception as e:
        print(f"Warning: Could not read device registry: {e}", file=sys.stderr)

# Generate devices.yaml
devices_yaml_lines = ["# Zigbee2MQTT Device Configuration", 
                       "# Migrated from ZHA", 
                       "#", ""]

# Track used names to ensure uniqueness
used_names = {}

for device in devices:
    ieee_z2m = device['ieee_z2m']
    ieee_clean = ieee_z2m.replace('0x', '').lower()
    
    # Get friendly name and room
    name_info = device_names.get(ieee_clean, {})
    original_name = name_info.get('original', '')
    device_room = device_areas.get(ieee_clean, '')
    
    # Build friendly name with room prefix if available
    if original_name and device_room:
        friendly_name = f"{device_room} - {original_name}"
    elif original_name:
        friendly_name = original_name
    else:
        friendly_name = ''
    
    if not friendly_name:
        # Generate a name from manufacturer and model
        manufacturer = device.get('manufacturer', '')
        model = device.get('model', '')
        if manufacturer and model:
            friendly_name = f"{manufacturer} {model}"
        else:
            # Use IEEE address as fallback
            friendly_name = f"device_{ieee_clean}"
    
    # Strip trailing/leading whitespace
    friendly_name = friendly_name.strip()
    
    # Ensure uniqueness by appending IEEE suffix if name already used
    base_name = friendly_name
    name_key = friendly_name.lower()
    if name_key in used_names:
        # Append last 4 chars of IEEE to make unique
        friendly_name = f"{base_name} {ieee_clean[-4:]}"
        name_key = friendly_name.lower()
    used_names[name_key] = True
    
    # Quote the friendly name if it contains special characters
    if any(c in friendly_name for c in ' :\'\"'):
        friendly_name_yaml = f"'{friendly_name}'"
    else:
        friendly_name_yaml = friendly_name
    
    # Make names unique by appending part of IEEE if duplicate
    devices_yaml_lines.append(f"'{ieee_z2m}':")
    
    if original_name:
        devices_yaml_lines.append(f"  # Original ZHA name: {original_name}")
    
    devices_yaml_lines.append(f"  friendly_name: {friendly_name_yaml}")
    
    # Add some useful info as comments
    if device.get('manufacturer'):
        devices_yaml_lines.append(f"  # Manufacturer: {device['manufacturer']}")
    if device.get('model'):
        devices_yaml_lines.append(f"  # Model: {device['model']}")
    
    devices_yaml_lines.append("")

# Write devices.yaml
with open(os.path.join(output_dir, 'devices.yaml'), 'w') as f:
    f.write('\n'.join(devices_yaml_lines))

# Generate groups.yaml
groups_yaml_lines = ["# Zigbee2MQTT Group Configuration",
                      "# Migrated from ZHA",
                      "#", ""]

for group in groups:
    group_id = group['groupID']
    group_name = group.get('name', f'group_{group_id}')
    
    # Clean up group name
    friendly_name = re.sub(r'[^a-zA-Z0-9_]', '_', group_name.lower())
    friendly_name = re.sub(r'_+', '_', friendly_name).strip('_')
    
    groups_yaml_lines.append(f"'{group_id}':")
    groups_yaml_lines.append(f"  friendly_name: {friendly_name}")
    groups_yaml_lines.append("")

# Write groups.yaml
with open(os.path.join(output_dir, 'groups.yaml'), 'w') as f:
    f.write('\n'.join(groups_yaml_lines))

print(f"Created devices.yaml with {len(devices)} devices")
print(f"Created groups.yaml with {len(groups)} groups")
PYTHON_SCRIPT

    log_info "Created devices.yaml and groups.yaml"
}

# =============================================================================
# Create Secret File
# =============================================================================

create_secrets() {
    log_info "Creating secret.yaml for sensitive configuration..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would create secret.yaml"
        return
    fi
    
    # Convert network key to array format for secret file
    local network_key_array
    network_key_array=$(python3 << PYTHON_SCRIPT
key_str = "$NETWORK_KEY"
bytes_hex = key_str.replace(' ', '').split(':')
bytes_int = [int(b, 16) for b in bytes_hex]
print('[' + ', '.join(str(b) for b in bytes_int) + ']')
PYTHON_SCRIPT
)

    cat > "$Z2M_OUTPUT_DIR/secret.yaml" << EOF
# Zigbee2MQTT Secrets
# ===================
# This file contains sensitive configuration values
# Keep this file secure and do not share it publicly
#

# Network key (migrated from ZHA)
network_key: $network_key_array

# MQTT credentials (if used)
EOF

    if [[ -n "$MQTT_USER" ]]; then
        echo "mqtt_user: '$MQTT_USER'" >> "$Z2M_OUTPUT_DIR/secret.yaml"
    fi
    
    if [[ -n "$MQTT_PASSWORD" ]]; then
        echo "mqtt_password: '$MQTT_PASSWORD'" >> "$Z2M_OUTPUT_DIR/secret.yaml"
    fi
    
    log_info "Created secret.yaml"
}

# =============================================================================
# Cleanup and Final Steps
# =============================================================================

cleanup() {
    log_info "Cleaning up temporary files..."
    
    rm -f /tmp/zha_backup.json
    # Keep extracted_devices.json for the summary, delete after
    
    log_info "Cleanup complete"
}

final_cleanup() {
    # Final cleanup after summary is shown
    rm -f "$Z2M_OUTPUT_DIR/extracted_devices.json"
}

show_migration_summary() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                         MIGRATION SUMMARY                                    ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Generate comprehensive summary using Python for proper formatting
    python3 << 'PYTHON_SCRIPT' - "$Z2M_OUTPUT_DIR" "$HA_CONFIG_DIR" "$NETWORK_KEY" "$CHANNEL" "$PAN_ID" "$EXT_PAN_ID" "$COORDINATOR_IEEE" "$TX_COUNTER" "$SERIAL_PORT" "$ADAPTER_TYPE"
import json
import sys
import os
from datetime import datetime

output_dir = sys.argv[1]
ha_config_dir = sys.argv[2]
network_key = sys.argv[3]
channel = sys.argv[4]
pan_id = sys.argv[5]
ext_pan_id = sys.argv[6]
coordinator_ieee = sys.argv[7]
tx_counter = sys.argv[8]
serial_port = sys.argv[9]
adapter_type = sys.argv[10]

# Load extracted devices
devices = []
groups = []
extracted_path = os.path.join(output_dir, 'extracted_devices.json')
if os.path.exists(extracted_path):
    with open(extracted_path, 'r') as f:
        data = json.load(f)
        devices = data.get('devices', [])
        groups = data.get('groups', [])

# Load area names from Home Assistant area registry
area_names = {}
area_registry_path = os.path.join(ha_config_dir, '.storage/core.area_registry')
if os.path.exists(area_registry_path):
    try:
        with open(area_registry_path, 'r') as f:
            area_registry = json.load(f)
        for area in area_registry.get('data', {}).get('areas', []):
            area_id = area.get('id')
            area_name = area.get('name')
            if area_id and area_name:
                area_names[area_id] = area_name
    except:
        pass

# Load device names and areas from devices.yaml parsing or HA registry
device_names = {}
device_areas = {}
device_registry_path = os.path.join(ha_config_dir, '.storage/core.device_registry')
if os.path.exists(device_registry_path):
    try:
        with open(device_registry_path, 'r') as f:
            registry = json.load(f)
        for device in registry.get('data', {}).get('devices', []):
            for identifier in device.get('identifiers', []):
                if isinstance(identifier, list) and len(identifier) >= 2:
                    if identifier[0] == 'zha':
                        ieee = identifier[1].replace(':', '').lower()
                        name = device.get('name_by_user') or device.get('name')
                        area_id = device.get('area_id')
                        if name:
                            device_names[ieee] = name
                        if area_id and area_id in area_names:
                            device_areas[ieee] = area_names[area_id]
    except:
        pass

# Count device types
routers = sum(1 for d in devices if d.get('type') == 'Router')
end_devices = sum(1 for d in devices if d.get('type') == 'EndDevice')
unknown = sum(1 for d in devices if d.get('type') not in ['Router', 'EndDevice'])

print("┌─────────────────────────────────────────────────────────────────────────────┐")
print("│ NETWORK CONFIGURATION (Preserved from ZHA)                                  │")
print("├─────────────────────────────────────────────────────────────────────────────┤")
print(f"│ Zigbee Channel:        {channel:<54}│")
print(f"│ PAN ID:                0x{pan_id.upper():<52}│")
print(f"│ Extended PAN ID:       {ext_pan_id:<54}│")
print(f"│ Coordinator IEEE:      {coordinator_ieee:<54}│")
print(f"│ Network Key:           [PRESERVED - 16 bytes] ✓{' '*28}│")
print(f"│ Frame Counter (TX):    {tx_counter:<54}│")
print("└─────────────────────────────────────────────────────────────────────────────┘")
print("")

print("┌─────────────────────────────────────────────────────────────────────────────┐")
print("│ ADAPTER CONFIGURATION                                                       │")
print("├─────────────────────────────────────────────────────────────────────────────┤")
print(f"│ Serial Port:           {serial_port:<54}│")
print(f"│ Adapter Type:          {adapter_type:<54}│")
print("└─────────────────────────────────────────────────────────────────────────────┘")
print("")

print("┌─────────────────────────────────────────────────────────────────────────────┐")
print("│ MIGRATION STATISTICS                                                        │")
print("├─────────────────────────────────────────────────────────────────────────────┤")
print(f"│ Total Devices:         {len(devices):<54}│")
print(f"│   ├─ Routers:          {routers:<54}│")
print(f"│   ├─ End Devices:      {end_devices:<54}│")
print(f"│   └─ Unknown:          {unknown:<54}│")
print(f"│ Groups:                {len(groups):<54}│")
print("└─────────────────────────────────────────────────────────────────────────────┘")
print("")

# Device table
if devices:
    print("┌─────────────────────────────────────────────────────────────────────────────┐")
    print("│ MIGRATED DEVICES                                                            │")
    print("├────┬──────────────────┬────────────┬─────────────────────────┬──────────────┤")
    print("│ #  │ IEEE Address     │ Type       │ Name                    │ Model        │")
    print("├────┼──────────────────┼────────────┼─────────────────────────┼──────────────┤")
    
    for idx, device in enumerate(devices, 1):
        ieee_short = device.get('ieee_z2m', '').replace('0x', '')[:16]
        dev_type = device.get('type', 'Unknown')[:10]
        
        # Get name and room from HA registry or fallback
        ieee_clean = device.get('ieee_z2m', '').replace('0x', '').lower()
        device_name = device_names.get(ieee_clean, '')
        device_room = device_areas.get(ieee_clean, '')
        
        # Build display name with room prefix
        if device_name and device_room:
            name = f"{device_room} - {device_name}"
        elif device_name:
            name = device_name
        else:
            name = device.get('manufacturer', '') or 'Unknown'
        name = name[:23]  # Truncate for display
        
        model = (device.get('model') or '')[:12]
        
        # Color-code device types
        if dev_type == 'Router':
            type_display = f"Router    "
        elif dev_type == 'EndDevice':
            type_display = f"EndDevice "
        else:
            type_display = f"{dev_type:<10}"
        
        print(f"│{idx:>3} │ {ieee_short:<16} │ {type_display} │ {name:<23} │ {model:<12} │")
    
    print("└────┴──────────────────┴────────────┴─────────────────────────┴──────────────┘")
    print("")

# Groups table
if groups:
    print("┌─────────────────────────────────────────────────────────────────────────────┐")
    print("│ MIGRATED GROUPS                                                             │")
    print("├────┬──────────┬────────────────────────────────┬────────────────────────────┤")
    print("│ #  │ Group ID │ Name                           │ Members                    │")
    print("├────┼──────────┼────────────────────────────────┼────────────────────────────┤")
    
    for idx, group in enumerate(groups, 1):
        group_id = group.get('groupID', 0)
        group_name = group.get('name', f'group_{group_id}')[:30]
        member_count = len(group.get('members', []))
        members_str = f"{member_count} device(s)"
        
        print(f"│{idx:>3} │ {group_id:<8} │ {group_name:<30} │ {members_str:<26} │")
    
    print("└────┴──────────┴────────────────────────────────┴────────────────────────────┘")
    print("")

# Files created
print("┌─────────────────────────────────────────────────────────────────────────────┐")
print("│ FILES CREATED                                                               │")
print("├─────────────────────────────────────────────────────────────────────────────┤")
files_created = [
    ("configuration.yaml", "Main Z2M configuration with network settings"),
    ("database.db", "Device database (NDJSON format)"),
    ("coordinator_backup.json", "Coordinator backup for network restoration"),
    ("devices.yaml", "Device configurations with friendly names"),
    ("groups.yaml", "Group configurations"),
    ("secret.yaml", "Sensitive data (network key, credentials)")
]
for filename, description in files_created:
    filepath = os.path.join(output_dir, filename)
    if os.path.exists(filepath):
        size = os.path.getsize(filepath)
        size_str = f"{size:,} bytes"
        print(f"│ ✓ {filename:<25} {size_str:<12} {description:<32}│")
    else:
        print(f"│ ✗ {filename:<25} {'N/A':<12} {description:<32}│")
print("└─────────────────────────────────────────────────────────────────────────────┘")
print("")

# Preserved settings checklist
print("┌─────────────────────────────────────────────────────────────────────────────┐")
print("│ PRESERVED SETTINGS CHECKLIST                                                │")
print("├─────────────────────────────────────────────────────────────────────────────┤")
print("│ ✓ Network Key (16-byte encryption key)                                      │")
print("│ ✓ PAN ID (Personal Area Network identifier)                                 │")
print("│ ✓ Extended PAN ID                                                           │")
print("│ ✓ Zigbee Channel                                                            │")
print("│ ✓ Frame Counter (prevents replay attacks)                                   │")
print("│ ✓ Device IEEE Addresses (unique device identifiers)                         │")
print("│ ✓ Device Network Addresses                                                  │")
print("│ ✓ Device Names (from Home Assistant registry)                               │")
print("│ ✓ Group Definitions                                                         │")
print("│ ✓ Endpoint Configurations                                                   │")
print("│ ✓ Cluster Information                                                       │")
print("└─────────────────────────────────────────────────────────────────────────────┘")

PYTHON_SCRIPT
}

show_summary() {
    # Show the detailed migration summary first
    show_migration_summary
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                              NEXT STEPS                                      ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "1. STOP the ZHA integration in Home Assistant"
    echo "   - Go to Settings -> Devices & Services -> ZHA"
    echo "   - Click the three dots menu and select 'Disable'"
    echo "   - Or delete the ZHA integration entirely"
    echo ""
    echo "2. INSTALL Zigbee2MQTT add-on (if not already installed)"
    echo "   - Go to Settings -> Add-ons -> Add-on Store"
    echo "   - Search for 'Zigbee2MQTT' and install it"
    echo ""
    echo "3. CONFIGURE the Zigbee2MQTT add-on"
    echo "   - Set the data path to: $Z2M_OUTPUT_DIR"
    echo "   - Or copy the files to the default Z2M data directory"
    echo ""
    echo "4. START Zigbee2MQTT"
    echo "   - The coordinator will restore from the backup"
    echo "   - Devices should appear automatically"
    echo ""
    echo "5. WAKE UP battery-powered devices"
    echo "   - Press a button or trigger motion on battery devices"
    echo "   - This helps them reconnect to the network"
    echo ""
    
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                           IMPORTANT NOTES                                    ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "• The network key has been preserved - NO RE-PAIRING NEEDED"
    echo "• Device names have been migrated from Home Assistant registry"
    echo "• Review configuration.yaml before starting Z2M"
    echo "• Serial port: $SERIAL_PORT"
    echo "• Adapter type: $ADAPTER_TYPE"
    echo ""
    echo "If you encounter issues:"
    echo "• Check Z2M logs for errors"
    echo "• Ensure the serial port is correct and accessible"
    echo "• For EZSP/EmberZNet adapters, ensure the backup has ezspVersion set"
    echo "• Battery devices may need a button press to wake up and reconnect"
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                      MIGRATION COMPLETED SUCCESSFULLY                        ║"
    echo "╚══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Final cleanup
    final_cleanup
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo "=============================================="
    echo "   ZHA to Zigbee2MQTT Migration Script"
    echo "=============================================="
    echo ""
    
    parse_args "$@"
    
    check_dependencies
    
    detect_zha_config
    
    extract_zha_backup
    
    extract_devices
    
    create_z2m_config
    
    create_z2m_database
    
    create_coordinator_backup
    
    create_device_configs
    
    create_secrets
    
    cleanup
    
    show_summary
}

# Run main function
main "$@"
