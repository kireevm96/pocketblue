#!/bin/bash
# FEXWRAP installer for Flatpak
# Устанавливает обертку для автоматического запуска x86_64 Flatpak приложений через FEX

set -e

echo "╔══════════════════════════════════════════════════╗"
echo "║        FEXWRAP Installer for Flatpak            ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# Определяем текущего пользователя (для настройки FEX_ROOTFS)
CURRENT_USER=$(logname 2>/dev/null || echo "${SUDO_USER:-$(whoami)}")
USER_HOME="/var/home/kireevm"
#$(eval echo "~$CURRENT_USER")

# Пути установки
FEXWRAP_BIN="/usr/bin/fexwrap"
FLATPAK_FEX_BIN="/usr/bin/flatpak-fex"
FEXWRAP_DIR="/usr/share/fexwrap"
CONFIG_FILE="/etc/fexwrap.conf"
BASH_ALIAS_FILE="/etc/profile.d/fexwrap.sh"

# Создаем директории

echo "📦 Detected user: $CURRENT_USER"
echo "📦 Home directory: $USER_HOME"
echo ""

# Функция для создания конфигурационного файла
create_config() {
    cat > "$CONFIG_FILE" << EOF
# FEXWRAP Configuration
# This file is sourced by fexwrap scripts

# Path to FEX root filesystem
# Default: ~/.fex-emu/RootFS/Ubuntu_24_04
FEX_ROOTFS="$USER_HOME/.fex-emu/RootFS/Ubuntu_24_04"

# Flatpak runtime paths (usually don't need to change)
FLATPAK_RUNTIME_AARCH64="/var/lib/flatpak/runtime/org.freedesktop.Platform/aarch64/25.08/active/files"
FLATPAK_RUNTIME_X86_64="/var/lib/flatpak/runtime/org.freedesktop.Platform/x86_64/24.08/active/files"
FLATPAK_SDK_AARCH64="/var/lib/flatpak/runtime/org.freedesktop.Sdk/aarch64/25.08/active/files"

# Debug mode (0 = off, 1 = on)
DEBUG=0

# Auto-cleanup old temp directories (in hours)
CLEANUP_AGE_HOURS=24
EOF
    echo "✅ Created configuration file: $CONFIG_FILE"
}

# Функция для создания основного скрипта fexwrap
create_fexwrap() {
    cat > "$FEXWRAP_BIN" << 'EOF'
#!/usr/bin/env bash
# SPDX-License-Identifier: WTFPL
# FEX wrapper for Flatpak - automatically runs x86_64 apps through FEX

# Load configuration
if [ -f /etc/fexwrap.conf ]; then
    source /etc/fexwrap.conf
fi

# Default values if not set in config
: "${FEX_ROOTFS:=/var/home/kireevm/.fex-emu/RootFS/Ubuntu_24_04}"
: "${FLATPAK_RUNTIME_AARCH64:=/var/lib/flatpak/runtime/org.freedesktop.Platform/aarch64/25.08/active/files}"
: "${FLATPAK_RUNTIME_X86_64:=/var/lib/flatpak/runtime/org.freedesktop.Platform/x86_64/24.08/active/files}"
: "${FLATPAK_SDK_AARCH64:=/var/lib/flatpak/runtime/org.freedesktop.Sdk/aarch64/25.08/active/files}"
: "${DEBUG:=0}"
: "${CLEANUP_AGE_HOURS:=24}"

# Debug output
debug() {
    if [ "$DEBUG" -eq 1 ]; then
        echo "DEBUG: $1" >&2
    fi
}

# Cleanup old temporary directories
cleanup_old_tmpdirs() {
    local pattern="/tmp/fexwrap-*"
    find /tmp -maxdepth 1 -name "fexwrap-*" -type d -mmin +$((CLEANUP_AGE_HOURS * 60)) 2>/dev/null | while read -r dir; do
        debug "Removing old directory: $dir"
        rm -rf "$dir"
    done
}

# Call cleanup at start
cleanup_old_tmpdirs

if [ "x$4" = "xxdg-dbus-proxy" ]; then
    debug "bailing for xdg-dbus-proxy"
    exec bwrap "$@"
fi

# Global variable for temp directory
OVERUSR_TMPDIR=""

# Cleanup function
cleanup() {
    if [ -n "$OVERUSR_TMPDIR" ] && [ -d "$OVERUSR_TMPDIR" ]; then
        debug "Cleaning up temporary directory: $OVERUSR_TMPDIR"
        rm -rf "$OVERUSR_TMPDIR"
    fi
}

# Set up traps
trap cleanup EXIT INT TERM HUP QUIT ABRT

# Get app ID from environment
APP_ID="${FEXWRAP_APP_ID:-unknown}"

debug "APP_ID: $APP_ID"
debug "Command line args: $*"

# Function to get app runtime info
get_app_runtime_info() {
    local app_id="$1"
    local arch="$2"
    
    if [ "$app_id" = "unknown" ]; then
        return 1
    fi
    
    local app_info
    if app_info=$(flatpak info "$app_id" --arch="$arch" 2>/dev/null); then
        local runtime=$(echo "$app_info" | grep -E "^[[:space:]]*Runtime:" | awk '{print $2}')
        if [ -n "$runtime" ]; then
            echo "$runtime"
            return 0
        fi
    fi
    
    return 1
}

# Function to get runtime path
get_runtime_path() {
    local runtime_ref="$1"
    
    local possible_paths=(
        "/var/lib/flatpak/runtime/$runtime_ref/active/files"
        "$HOME/.local/share/flatpak/runtime/$runtime_ref/active/files"
    )
    
    for path in "${possible_paths[@]}"; do
        if [ -d "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    
    return 1
}

# Determine runtimes to use
APP_RUNTIME_AARCH64_PATH="$FLATPAK_RUNTIME_AARCH64"
APP_RUNTIME_X86_64_PATH="$FLATPAK_RUNTIME_X86_64"
APP_SDK_PATH="$FLATPAK_SDK_AARCH64"

if [ "$APP_ID" != "unknown" ]; then
    debug "Getting runtime info for application: $APP_ID"
    
    if x86_64_runtime_ref=$(get_app_runtime_info "$APP_ID" "x86_64"); then
        debug "App runtime (x86_64): $x86_64_runtime_ref"
        
        if app_runtime_path=$(get_runtime_path "$x86_64_runtime_ref"); then
            APP_RUNTIME_X86_64_PATH="$app_runtime_path"
            debug "Using app x86_64 runtime path: $APP_RUNTIME_X86_64_PATH"
            
            if [ ! -d "$APP_RUNTIME_X86_64_PATH/lib/x86_64-linux-gnu" ]; then
                debug "WARNING: No x86_64 libraries found in app runtime, using default"
                APP_RUNTIME_X86_64_PATH="$FLATPAK_RUNTIME_X86_64"
            fi
        fi
    else
        debug "Could not get x86_64 runtime info, using default"
    fi
fi

debug "Final paths:"
debug "  AARCH64 (host): $APP_RUNTIME_AARCH64_PATH"
debug "  X86_64 (guest): $APP_RUNTIME_X86_64_PATH"
debug "  SDK: $APP_SDK_PATH"

# Create temporary directory
OVERUSR_TMPDIR=$(mktemp -d /tmp/fexwrap-overusr.XXXXXX)
debug "Created temporary directory: $OVERUSR_TMPDIR"

# Create directory structure
mkdir -p "$OVERUSR_TMPDIR/lib/aarch64-linux-gnu"

# Copy or create necessary files
if [ -f "$APP_RUNTIME_AARCH64_PATH/lib/ld-linux-aarch64.so.1" ]; then
    debug "Copying ld-linux-aarch64.so.1 from $APP_RUNTIME_AARCH64_PATH"
    cp "$APP_RUNTIME_AARCH64_PATH/lib/ld-linux-aarch64.so.1" "$OVERUSR_TMPDIR/lib/"
else
    debug "Creating symlink for ld-linux-aarch64.so.1"
    ln -sf /lib/ld-linux-aarch64.so.1 "$OVERUSR_TMPDIR/lib/ld-linux-aarch64.so.1" 2>/dev/null || true
fi

prefx=
pargs=()
rtdir_set=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --args) argfd="$2"; shift 2; IFS= mapfile -d '' -u "$argfd" fileargs; set -- "${fileargs[@]}" "$@";;
        --seccomp) shift 2;;
        --setenv)
            if [ "x$2" = "xLD_LIBRARY_PATH" ]; then
                pargs+=("--setenv" "$2" "$3:/usr/lib/aarch64-linux-gnu/GL/default/lib");
            elif [ "x$2" = "xLIBGL_DRIVERS_PATH" ]; then
                pargs+=("--setenv" "$2" "$3:/usr/lib/aarch64-linux-gnu/GL/lib/dri");
            else
                if [ "x$2" = "xXDG_RUNTIME_DIR" ]; then
                    rtdir_set=true
                fi
                pargs+=("--setenv" "$2" "$3");
            fi
            shift 3;;
        --symlink)
            if [[ "$2" =~ ^\.\./\.\./\.\./\.\./.* ]]; then
                debug "SKIPlink:$2"
            else
                pargs+=("--symlink" "$2" "$3");
            fi
            shift 3;;
        --ro-bind)
            debug "robind:$2:$3";
            if [ "x$3" = "x/usr" -o "x$3" = "x/run/parent/usr" ]; then
                pargs+=(
                    --overlay-src "$2"
                    --overlay-src "$OVERUSR_TMPDIR"
                    --ro-overlay "$3"
                    --ro-bind "$APP_RUNTIME_AARCH64_PATH/lib/aarch64-linux-gnu" "$3/lib/aarch64-linux-gnu"
                    --tmpfs "$3/lib/aarch64-linux-gnu/GL"
                    --ro-bind "/var/lib/flatpak/runtime/org.freedesktop.Platform.GL.default/aarch64/25.08/active/files" "$3/lib/aarch64-linux-gnu/GL/default"
                    --symlink "$3/lib/aarch64-linux-gnu/GL/default/vulkan/icd.d/freedreno_icd.aarch64.json" "$3/lib/aarch64-linux-gnu/GL/vulkan/icd.d/freedreno_icd.aarch64.json"
                    --symlink "$3/lib/aarch64-linux-gnu/GL/default/glvnd/egl_vendor.d/50_mesa.json" "$3/lib/aarch64-linux-gnu/GL/glvnd/egl_vendor.d/50_mesa.json"
                    --symlink "$3/lib/aarch64-linux-gnu/GL/default/lib/dri/msm_dri.so" "$3/lib/aarch64-linux-gnu/GL/lib/dri/msm_dri.so"
                    --symlink "$3/lib/aarch64-linux-gnu/GL/default/lib/gbm/dri_gbm.so" "$3/lib/aarch64-linux-gnu/GL/lib/gbm/dri_gbm.so"
                )
            else
                pargs+=("--ro-bind" "$2" "$3");
            fi
            shift 3;;
        --|ldconfig)
            if [ "x$1" = "x--" ]; then
                shift
            fi
            if [ "x$rtdir_set" != "xtrue" ]; then
                pargs+=(
                    --tmpfs /tmp/run/owowo
                    --setenv XDG_RUNTIME_DIR /tmp/run/owowo
                )
            fi
            
            # Create temporary directory for FEX libraries
            pargs+=(
                --tmpfs /tmp/fex-libs
                --ro-bind /usr /tmp/fex
            )
            
            # Add libxxhash.so.0
            if [ -f "$APP_SDK_PATH/lib/aarch64-linux-gnu/libxxhash.so.0" ]; then
                pargs+=(--ro-bind "$APP_SDK_PATH/lib/aarch64-linux-gnu/libxxhash.so.0" /tmp/fex-libs/libxxhash.so.0)
            else
                echo "ERROR: libxxhash.so.0 not found at $APP_SDK_PATH/lib/aarch64-linux-gnu/libxxhash.so.0" >&2
                exit 1
            fi
            
            pargs+=(
                --ro-bind "$FEX_ROOTFS" /fex-rootfs
                --ro-bind "$APP_RUNTIME_X86_64_PATH/lib/x86_64-linux-gnu" /tmp/usr/lib/x86_64-linux-gnu
            )
            
            # Update library path and configure FEX
            pargs+=(
                --setenv LD_LIBRARY_PATH "/tmp/fex-libs:${LD_LIBRARY_PATH:-}"
                --setenv FEX_APP_CONFIG_LOCATION /tmp/fex/share/fex-emu
                --setenv FEX_ROOTFS /fex-rootfs
                --
                /tmp/fex/bin/FEXInterpreter
                /usr/bin/env
                "$@"
            )
            break;;
        *) pargs+=("$1"); shift;;
    esac
done

debug "fexwrap: pargs: ${pargs[*]}"
exec bwrap "${pargs[@]}"
EOF
    
    chmod +x "$FEXWRAP_BIN"
    echo "✅ Created main script: $FEXWRAP_BIN"
}

# Функция для создания скрипта-обертки flatpak-fex с правильной логикой определения архитектуры
create_flatpak_fex() {
    cat > "$FLATPAK_FEX_BIN" << 'EOF'
#!/usr/bin/env bash
# Flatpak wrapper that automatically uses FEX for x86_64 applications

# Configuration
CONFIG_FILE="/etc/fexwrap.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

: "${DEBUG:=0}"

debug() {
    if [ "$DEBUG" -eq 1 ]; then
        echo "DEBUG: $1" >&2
    fi
}

# Main fexwrap script
FEXWRAP_SCRIPT="/usr/bin/fexwrap"

# Function to parse command line arguments and extract app ID and architecture
parse_arguments() {
    local app_id=""
    local cmd_arch=""
    local in_run=false
    
    for arg in "$@"; do
        if [ "$arg" = "run" ]; then
            in_run=true
            continue
        fi
        
        if [ "$in_run" = true ]; then
            # Extract architecture if specified
            if [[ "$arg" == --arch=* ]]; then
                cmd_arch="${arg#--arch=}"
                continue
            fi
            
            # Skip other options
            if [[ "$arg" == -* ]]; then
                continue
            fi
            
            # Check if it looks like an app ID (this should come after options)
            if [[ "$arg" =~ ^(com|org|net|io|edu)\.[a-zA-Z0-9.-]+\.[a-zA-Z0-9.-]+$ ]]; then
                if [ -z "$app_id" ]; then
                    app_id="$arg"
                fi
            fi
        fi
    done
    
    echo "$app_id:$cmd_arch"
}

# Function to get installed architecture of an app
get_installed_arch() {
    local app_id="$1"
    
    # Try to get architecture from flatpak info
    if flatpak info "$app_id" &>/dev/null; then
        # Get all installed architectures for this app
        local installed_archs=$(flatpak info "$app_id" | grep -E "^[[:space:]]*Arch:" | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')
        if [ -n "$installed_archs" ]; then
            echo "$installed_archs"
            return 0
        fi
    fi
    
    return 1
}

# Function to determine which architecture to use
determine_architecture() {
    local app_id="$1"
    local cmdline_arch="$2"
    
    # If architecture is explicitly specified in command line, use it
    if [ -n "$cmdline_arch" ]; then
        echo "$cmdline_arch"
        debug "Using command line specified architecture: $cmdline_arch"
        return 0
    fi
    
    # Check if app is installed for x86_64
    local installed_archs=$(get_installed_arch "$app_id")
    if echo "$installed_archs" | grep -q "x86_64"; then
        echo "x86_64"
        debug "App is installed for x86_64, using FEX"
        return 0
    fi
    
    # If not installed for x86_64, check what is available
    debug "App is not installed for x86_64, installed architectures: $installed_archs"
    
    # If app is installed for aarch64, use native
    if echo "$installed_archs" | grep -q "aarch64"; then
        echo "aarch64"
        debug "App is installed for aarch64, running natively"
        return 0
    fi
    
    # Default to x86_64 for compatibility
    echo "x86_64"
    debug "Defaulting to x86_64 for compatibility"
    return 1
}

# Main function
main() {
    # If not "run" command, just pass through
    if [ "$1" != "run" ]; then
        debug "Not a 'run' command, passing through"
        exec /usr/bin/flatpak "$@"
    fi
    
    # Parse arguments
    local parsed=$(parse_arguments "$@")
    local app_id=$(echo "$parsed" | cut -d: -f1)
    local cmdline_arch=$(echo "$parsed" | cut -d: -f2)
    
    if [ -z "$app_id" ]; then
        debug "Could not extract app ID, passing through"
        exec /usr/bin/flatpak "$@"
    fi
    
    debug "Detected application: $app_id"
    debug "Command line architecture: $cmdline_arch"
    
    # Determine architecture to use
    local use_arch=$(determine_architecture "$app_id" "$cmdline_arch")
    
    debug "Will use architecture: $use_arch"
    
    echo "🔍 Application: $app_id" >&2
    
    if [ "$use_arch" = "x86_64" ]; then
        echo "🚀 Using FEX for x86_64 application" >&2
        
        # Set environment variables for FEX
        export FLATPAK_BWRAP="$FEXWRAP_SCRIPT"
        export FEXWRAP_APP_ID="$app_id"
        
        # Pass FEX_ROOTFS from config
        if [ -n "$FEX_ROOTFS" ]; then
            export FEXWRAP_ROOTFS="$FEX_ROOTFS"
        fi
        
        debug "Using FEXWRAP_SCRIPT: $FEXWRAP_SCRIPT"
        debug "FEXWRAP_APP_ID: $app_id"
        
        # If architecture wasn't specified, add it
        local args=("$@")
        if [ -z "$cmdline_arch" ]; then
            # Find position of app ID and insert --arch=x86_64 before it
            local new_args=()
            local found_app=false
            
            for arg in "${args[@]}"; do
                if [ "$arg" = "$app_id" ] && [ "$found_app" = false ]; then
                    new_args+=("--arch=x86_64")
                    found_app=true
                fi
                new_args+=("$arg")
            done
            
            args=("${new_args[@]}")
        fi
        
        exec /usr/bin/flatpak "${args[@]}"
    else
        echo "⚡ Running native $use_arch application without FEX" >&2
        exec /usr/bin/flatpak "$@"
    fi
}

# Handle errors
trap 'echo "Error in flatpak-fex" >&2; exit 1' ERR

main "$@"
EOF
    
    chmod +x "$FLATPAK_FEX_BIN"
    echo "✅ Created flatpak wrapper: $FLATPAK_FEX_BIN"
}

# Функция для создания alias файла
create_alias_file() {
    cat > "$BASH_ALIAS_FILE" << 'EOF'
#!/bin/bash
# FEXWRAP alias configuration
# This file is sourced by bash to set up the flatpak alias

# Only set alias if flatpak-fex exists
if [ -x /usr/bin/flatpak-fex ]; then
    # Check if we're in an interactive shell
    if [[ $- == *i* ]]; then
        # Don't show message on every terminal open, only on first load
        if [ -z "$FEXWRAP_ALIAS_SET" ]; then
            echo "🔧 FEXWRAP: flatpak command is now wrapped to auto-detect x86_64 apps" >&2
            echo "   Use 'flatpak-fex' directly or disable with: unalias flatpak" >&2
            echo "   For direct access use: /usr/bin/flatpak" >&2
            export FEXWRAP_ALIAS_SET=1
        fi
    fi
    alias flatpak='flatpak-fex'
fi
EOF
    
    chmod +x "$BASH_ALIAS_FILE"
    echo "✅ Created alias file: $BASH_ALIAS_FILE"
}

# Функция для создания файла справки
create_help_file() {
    cat > "$FEXWRAP_DIR/README.md" << EOF
# FEXWRAP for Flatpak

## Overview
FEXWRAP is a wrapper that automatically detects x86_64 Flatpak applications and runs them through FEX (FEX-Emu) on ARM64 systems.

## How it works
1. When you run \`flatpak run com.example.App\`, the wrapper checks:
   - If \`--arch=x86_64\` is specified in command line
   - If the app is installed for x86_64 architecture
2. If x86_64 is detected, it sets up environment variables to use FEX
3. Otherwise, it runs the app natively

## Installation
The system has been installed to:
- Main script: /usr/bin/fexwrap
- Flatpak wrapper: /usr/bin/flatpak-fex
- Configuration: /etc/fexwrap.conf
- Bash alias: /etc/profile.d/fexwrap.sh

## Usage
Simply use the normal flatpak command:
\`\`\`bash
flatpak run com.bambulab.BambuStudio
\`\`\`

Or explicitly specify architecture:
\`\`\`bash
flatpak run --arch=x86_64 com.bambulab.BambuStudio
\`\`\`

The wrapper will automatically:
1. Detect if x86_64 is needed
2. Use FEX for x86_64 applications
3. Run ARM64 applications natively

## Manual Control
You can also use FEXWRAP manually:
\`\`\`bash
FEXWRAP_APP_ID=com.bambulab.BambuStudio FLATPAK_BWRAP=/usr/bin/fexwrap flatpak run --arch=x86_64 ...
\`\`\`

To bypass the wrapper completely:
\`\`\`bash
/usr/bin/flatpak run ...
\`\`\`

## Important Notes
1. The app must be installed for x86_64 architecture to use FEX:
   \`\`\`bash
   flatpak install --arch=x86_64 com.bambulab.BambuStudio
   \`\`\`

2. You can have multiple architectures installed:
   \`\`\`bash
   flatpak install --arch=x86_64 --arch=aarch64 com.bambulab.BambuStudio
   \`\`\`

3. Check installed architectures:
   \`\`\`bash
   flatpak info com.bambulab.BambuStudio | grep Arch
   \`\`\`

## Configuration
Edit \`/etc/fexwrap.conf\` to change settings:
- \`FEX_ROOTFS\`: Path to your FEX root filesystem
- \`DEBUG\`: Set to 1 for debug output
- Runtime paths: Usually don't need to change

## Troubleshooting

### 1. "Application not installed" error
Make sure the app is installed for x86_64:
\`\`\`bash
flatpak install --arch=x86_64 com.example.App
\`\`\`

### 2. Check FEX installation:
\`\`\`bash
ls -la ~/.fex-emu/RootFS/
which FEXInterpreter
\`\`\`

### 3. Enable debug mode:
\`\`\`bash
sudo sed -i 's/DEBUG=0/DEBUG=1/' /etc/fexwrap.conf
\`\`\`

### 4. Check if wrapper is working:
\`\`\`bash
flatpak-fex run --help
\`\`\`

### 5. Disable wrapper (temporarily):
\`\`\`bash
unalias flatpak
/usr/bin/flatpak run ...
\`\`\`

## Files
- \`/usr/bin/fexwrap\`: Main FEX wrapper script
- \`/usr/bin/flatpak-fex\`: Flatpak wrapper that auto-detects architecture
- \`/etc/fexwrap.conf\`: Configuration file
- \`/etc/profile.d/fexwrap.sh\`: Bash alias setup
- \`/usr/share/fexwrap/\`: Documentation and logs

## Support
For issues, check:
1. FEX installation: https://github.com/FEX-Emu/FEX
2. Flatpak runtime paths
3. Application compatibility
EOF
    
    echo "✅ Created documentation: $FEXWRAP_DIR/README.md"
}

# Функция для проверки зависимостей
check_dependencies() {
    echo "🔍 Checking dependencies..."
    
    # Check for flatpak
    if ! command -v flatpak &> /dev/null; then
        echo "❌ Flatpak is not installed"
        echo "   Install with: sudo dnf install flatpak"
        exit 1
    fi
    
    # Check for bwrap
    if ! command -v bwrap &> /dev/null; then
        echo "❌ bwrap (bubblewrap) is not installed"
        echo "   Install with: sudo dnf install bubblewrap"
        exit 1
    fi
    
    # Check for FEX (optional, but warn)
    if ! command -v FEXInterpreter &> /dev/null; then
        echo "⚠️  WARNING: FEX-Emu not found in PATH"
        echo "   FEX is required for x86_64 emulation"
        echo "   Install from: https://github.com/FEX-Emu/FEX"
    fi
    
    # Check for FEX root filesystem
    if [ ! -d "$USER_HOME/.fex-emu/RootFS" ]; then
        echo "⚠️  WARNING: FEX root filesystem not found at: $USER_HOME/.fex-emu/RootFS"
        echo "   You may need to set FEX_ROOTFS in /etc/fexwrap.conf"
    fi
    
    echo "✅ Dependencies check passed"
}

# Функция для создания скрипта управления
create_management_script() {
    cat > "/usr/bin/fexwrap-manage" << 'EOF'
#!/bin/bash
# FEXWRAP management script

CONFIG_FILE="/etc/fexwrap.conf"

case "${1:-help}" in
    status)
        echo "FEXWRAP Status:"
        echo "================"
        echo "Main script: $(ls -la /usr/bin/fexwrap 2>/dev/null || echo 'Not found')"
        echo "Wrapper: $(ls -la /usr/bin/flatpak-fex 2>/dev/null || echo 'Not found')"
        echo "Config: $(ls -la /etc/fexwrap.conf 2>/dev/null || echo 'Not found')"
        
        if [ -f /etc/fexwrap.conf ]; then
            echo ""
            echo "Configuration:"
            grep -E '^[A-Z_]' /etc/fexwrap.conf
        fi
        ;;
    
    enable-debug)
        if [ -f "$CONFIG_FILE" ]; then
            sed -i 's/DEBUG=.*/DEBUG=1/' "$CONFIG_FILE"
            echo "Debug mode enabled"
        else
            echo "Config file not found: $CONFIG_FILE"
        fi
        ;;
    
    disable-debug)
        if [ -f "$CONFIG_FILE" ]; then
            sed -i 's/DEBUG=.*/DEBUG=0/' "$CONFIG_FILE"
            echo "Debug mode disabled"
        else
            echo "Config file not found: $CONFIG_FILE"
        fi
        ;;
    
    cleanup)
        echo "Cleaning up old temporary directories..."
        find /tmp -maxdepth 1 -name "fexwrap-*" -type d -mmin +60 2>/dev/null | while read -r dir; do
            echo "Removing: $dir"
            rm -rf "$dir"
        done
        echo "Done"
        ;;
    
    reinstall)
        echo "Reinstalling FEXWRAP..."
        curl -s https://raw.githubusercontent.com/yourusername/fexwrap/main/install.sh | sudo bash
        ;;
    
    help|*)
        echo "FEXWRAP Management Script"
        echo "Usage: fexwrap-manage COMMAND"
        echo ""
        echo "Commands:"
        echo "  status        - Show current status"
        echo "  enable-debug  - Enable debug mode"
        echo "  disable-debug - Disable debug mode"
        echo "  cleanup       - Clean up old temp directories"
        echo "  reinstall     - Reinstall from repository"
        echo "  help          - Show this help"
        ;;
esac
EOF
    
    chmod +x "/usr/bin/fexwrap-manage"
    echo "✅ Created management script: /usr/bin/fexwrap-manage"
}

# Основная установка
main_install() {
    echo "🚀 Starting FEXWRAP installation..."
    echo ""
    
    check_dependencies
    echo ""
    
    echo "📁 Creating configuration..."
    create_config
    echo ""
    
    echo "⚙️  Creating main FEX wrapper..."
    create_fexwrap
    echo ""
    
    echo "🔄 Creating Flatpak wrapper..."
    create_flatpak_fex
    echo ""
    
    echo "📝 Creating alias configuration..."
    create_alias_file
    echo ""
    
    
    echo "🔧 Creating management script..."
    create_management_script
    echo ""
    
    echo "🎉 Installation complete!"
    echo ""
    echo "══════════════════════════════════════════════════"
    echo "✨ FEXWRAP has been successfully installed!"
    echo ""
    echo "Quick start:"
    echo "1. Open a new terminal or run:"
    echo "   source /etc/profile.d/fexwrap.sh"
    echo ""
    echo "2. Install app for x86_64 architecture:"
    echo "   flatpak install --arch=x86_64 com.bambulab.BambuStudio"
    echo ""
    echo "3. Use flatpak normally:"
    echo "   flatpak run com.bambulab.BambuStudio"
    echo "   or explicitly:"
    echo "   flatpak run --arch=x86_64 com.bambulab.BambuStudio"
    echo ""
    echo "The wrapper will automatically:"
    echo "  • Use FEX for x86_64 apps (when installed)"
    echo "  • Run ARM64 apps natively"
    echo ""
    echo "Management:"
    echo "  fexwrap-manage status    - Check status"
    echo "  fexwrap-manage cleanup   - Clean temp files"
    echo ""
    echo "To disable wrapper temporarily:"
    echo "  unalias flatpak"
    echo "  or use: /usr/bin/flatpak"
    echo ""
    echo "══════════════════════════════════════════════════"
}

# Запуск установки
main_install
