#!/usr/bin/env bash
# =============================================================================
# Прошивка Droidian на Xiaomi POCO F4 (munch)
#
#   ./flash.sh boot      # прошить boot.img + vbmeta (телефон в fastboot)
#   ./flash.sh rootfs    # sideload rootfs- и devtools-zip (телефон в recovery)
#   ./flash.sh all       # rootfs, затем boot
#
# Предварительно (однократно):
#   1. Разблокированный загрузчик (Mi Unlock).
#   2. Прошитая стоковая MIUI на базе Android 12/12.1 (Droidian использует
#      стоковый /vendor и firmware!).
#   3. Кастомное recovery для munch (TWRP / OrangeFox).
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/config.env"

log() { printf '\033[1;32m[flash]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || die "Не найден $1 (пакет android-tools / platform-tools)"; }

flash_boot() {
    need fastboot
    local boot="$OUT_DIR/boot.img"
    [ -f "$boot" ] || die "Нет $boot — сначала ./build.sh artifacts"

    log "Жду устройство в режиме fastboot (Vol- + Power)…"
    fastboot getvar product 2>&1 | grep -qi munch || \
        die "Устройство не похоже на munch — прерываюсь (fastboot getvar product)"

    log "Прошиваю boot…"
    fastboot flash boot "$boot"

    if [ -f "$OUT_DIR/vbmeta.img" ]; then
        # Наш vbmeta.img собран avbtool'ом уже с отключённой верификацией
        # (flags зашиты внутрь), поэтому прошиваем как есть. Рантайм-флаги
        # --disable-verity/--disable-verification заставляют fastboot патчить
        # образ и на нашем пустом vbmeta падают с "Failed to find AVB_MAGIC".
        log "Прошиваю наш vbmeta (верификация уже отключена в образе)…"
        fastboot flash vbmeta "$OUT_DIR/vbmeta.img" || \
            fastboot --disable-verity --disable-verification flash vbmeta "$OUT_DIR/vbmeta.img"
    else
        log "vbmeta.img не найден в out/ — отключаю верификацию на стоковом vbmeta"
        fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img 2>/dev/null || \
            log "Пропустил vbmeta: при проблемах загрузки прошейте vbmeta вручную"
    fi
    log "Готово. Теперь: fastboot reboot — первая загрузка может занять несколько минут."
}

flash_rootfs() {
    need adb
    local rootfs="$OUT_DIR/$DROIDIAN_ROOTFS_ZIP"
    local devtools="$OUT_DIR/$DROIDIAN_DEVTOOLS_ZIP"
    [ -f "$rootfs" ] || die "Нет $rootfs — сначала ./build.sh rootfs"

    cat <<'EON'
Действия на телефоне (recovery TWRP/OrangeFox):
  1. Wipe -> Format Data (не просто wipe: нужен formаt, шифрование MIUI должно быть снято)
  2. Advanced -> ADB Sideload -> свайп для запуска
EON
    read -rp "Когда sideload запущен, нажмите Enter… "
    log "Отправляю rootfs (~1.3 ГБ, это долго)…"
    adb sideload "$rootfs"

    if [ -f "$devtools" ]; then
        read -rp "Снова включите ADB Sideload в recovery и нажмите Enter (devtools: ssh/telnet-отладка)… "
        adb sideload "$devtools" || log "devtools не встали — не критично для первой загрузки"
    fi
    log "Rootfs прошит. Теперь перезагрузитесь в fastboot и выполните: ./flash.sh boot"
}

case "${1:-}" in
    boot)   flash_boot ;;
    rootfs) flash_rootfs ;;
    all)    flash_rootfs; flash_boot ;;
    *)      sed -n '2,14p' "$0"; exit 1 ;;
esac
