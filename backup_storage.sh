#!/usr/bin/env bash
# =============================================================================
#  Backup de Laravel Storage (compatible Manjaro / Debian)
#  Uso:
#     ./backup_storage.sh              -> ejecuta el respaldo una vez
#     ./backup_storage.sh --install    -> instala el timer/cron
#     ./backup_storage.sh --uninstall  -> elimina el timer/cron
#     ./backup_storage.sh --status     -> muestra estado del timer/cron
# =============================================================================

PROJECT_PATH="auto"

SOURCE_SUBDIR="storage"

BACKUP_ROOT="$HOME/backups/sistema-evidencias"

BACKUP_DIR="$BACKUP_ROOT/storage"

BACKUP_PREFIX="storage_backup"

COMPRESSION="tar.gz"

KEEP_BACKUPS=7

AUTO_EXECUTE=true

INTERVAL_SYSTEMD="daily"
INTERVAL_CRON="0 3 * * *"
SYSTEMD_ON_CALENDAR=""

SERVICE_NAME="laravel-storage-backup"

LOG_FILE="$BACKUP_ROOT/backup_storage.log"

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    if [[ -n "${LOG_FILE:-}" ]]; then
        mkdir -p "$(dirname "$LOG_FILE")"
        echo "$msg" >> "$LOG_FILE"
    fi
}

die() { log "ERROR: $*"; exit 1; }

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "${ID:-unknown}"
    else
        echo "unknown"
    fi
}

resolve_paths() {
    local distro="$1"

    if [[ "$PROJECT_PATH" == "auto" ]]; then
        case "$distro" in
            manjaro|arch)
                PROJECT_PATH="/srv/http/sistema-evidencias"
                ;;
            debian|ubuntu|linuxmint|pop)
                PROJECT_PATH="/var/www/sistema-evidencias"
                ;;
            *)
                die "Distro '$distro' no reconocida. Define PROJECT_PATH manualmente."
                ;;
        esac
    fi

    SOURCE_DIR="$PROJECT_PATH/$SOURCE_SUBDIR"
    [[ -d "$SOURCE_DIR" ]] || die "No existe la ruta origen: $SOURCE_DIR"
}

do_backup() {
    mkdir -p "$BACKUP_DIR"

    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"

    local base_name="${BACKUP_PREFIX}_${timestamp}"
    local out_file=""

    case "$COMPRESSION" in
        tar.gz)  out_file="$BACKUP_DIR/${base_name}.tar.gz"  ;;
        tar.bz2) out_file="$BACKUP_DIR/${base_name}.tar.bz2" ;;
        tar.xz)  out_file="$BACKUP_DIR/${base_name}.tar.xz"  ;;
        zip)     out_file="$BACKUP_DIR/${base_name}.zip"     ;;
        *)       die "Compresión no soportada: $COMPRESSION" ;;
    esac

    log "Iniciando respaldo de: $SOURCE_DIR"
    log "Destino: $out_file"

    case "$COMPRESSION" in
        tar.gz)
            tar -czf "$out_file" -C "$(dirname "$SOURCE_DIR")" "$(basename "$SOURCE_DIR")"
            ;;
        tar.bz2)
            tar -cjf "$out_file" -C "$(dirname "$SOURCE_DIR")" "$(basename "$SOURCE_DIR")"
            ;;
        tar.xz)
            tar -cJf "$out_file" -C "$(dirname "$SOURCE_DIR")" "$(basename "$SOURCE_DIR")"
            ;;
        zip)
            command -v zip >/dev/null || die "zip no está instalado"
            ( cd "$(dirname "$SOURCE_DIR")" && zip -rq "$out_file" "$(basename "$SOURCE_DIR")" )
            ;;
    esac

    log "Respaldo creado: $(du -h "$out_file" | cut -f1)"

    if [[ "$KEEP_BACKUPS" -gt 0 ]]; then
        log "Rotación: conservando los últimos $KEEP_BACKUPS respaldos"
        ls -1t "$BACKUP_DIR"/${BACKUP_PREFIX}_* 2>/dev/null \
            | tail -n +$((KEEP_BACKUPS + 1)) \
            | while read -r old; do
                log "Eliminando respaldo antiguo: $old"
                rm -f -- "$old"
            done
    fi

    log "Respaldo finalizado correctamente."
}

install_systemd() {
    local user_dir="$HOME/.config/systemd/user"
    mkdir -p "$user_dir"

    cat > "$user_dir/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Backup de Laravel Storage (${PROJECT_PATH})

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH}
EOF

    local on_calendar
    if [[ -n "$SYSTEMD_ON_CALENDAR" ]]; then
        on_calendar="$SYSTEMD_ON_CALENDAR"
    else
        on_calendar="$INTERVAL_SYSTEMD"
    fi

    cat > "$user_dir/${SERVICE_NAME}.timer" <<EOF
[Unit]
Description=Timer para backup de Laravel Storage

[Timer]
OnCalendar=${on_calendar}
Persistent=true
Unit=${SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now "${SERVICE_NAME}.timer"
    log "Timer systemd instalado y activado (${on_calendar})."
}

install_cron() {
    command -v crontab >/dev/null || die "crontab no está instalado"
    local line="${INTERVAL_CRON} ${SCRIPT_PATH} >> ${LOG_FILE:-/dev/null} 2>&1"
    ( crontab -l 2>/dev/null | grep -v -F "$SCRIPT_PATH" ; echo "$line" ) | crontab -
    log "Entrada cron instalada: $line"
}

install_auto() {
    [[ "$AUTO_EXECUTE" == "true" ]] || { log "AUTO_EXECUTE=false, no se instala nada."; return; }

    if command -v systemctl >/dev/null && systemctl --user show-environment >/dev/null 2>&1; then
        install_systemd
    else
        log "systemd --user no disponible, usando cron."
        install_cron
    fi
}

uninstall_auto() {
    if systemctl --user list-unit-files 2>/dev/null | grep -q "${SERVICE_NAME}.timer"; then
        systemctl --user disable --now "${SERVICE_NAME}.timer" 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/${SERVICE_NAME}.service" \
              "$HOME/.config/systemd/user/${SERVICE_NAME}.timer"
        systemctl --user daemon-reload
        log "Timer systemd eliminado."
    fi
    if command -v crontab >/dev/null; then
        crontab -l 2>/dev/null | grep -v -F "$SCRIPT_PATH" | crontab - || true
        log "Entrada cron eliminada (si existía)."
    fi
}

status_auto() {
    echo "== Estado del backup de storage =="
    if systemctl --user list-timers 2>/dev/null | grep -q "$SERVICE_NAME"; then
        systemctl --user status "${SERVICE_NAME}.timer" --no-pager || true
    fi
    if command -v crontab >/dev/null; then
        echo "-- Cron --"
        crontab -l 2>/dev/null | grep -F "$SCRIPT_PATH" || echo "(sin entrada cron)"
    fi
    echo "-- Últimos respaldos en $BACKUP_DIR --"
    ls -lh "$BACKUP_DIR" 2>/dev/null || echo "(sin respaldos aún)"
}

main() {
    local distro
    distro="$(detect_distro)"
    log "Distro detectada: $distro"
    resolve_paths "$distro"

    case "${1:-}" in
        --install)   install_auto ;;
        --uninstall) uninstall_auto ;;
        --status)    status_auto ;;
        ""|--run)    do_backup ;;
        *)           echo "Uso: $0 [--install|--uninstall|--status|--run]"; exit 1 ;;
    esac
}

main "$@"