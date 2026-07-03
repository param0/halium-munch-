#!/usr/bin/env bash
# =============================================================================
# Прошивка Droidian на Xiaomi POCO F4 (munch)
#
#   ./flash.sh recovery <img>  # временно загрузить кастомное recovery (fastboot boot)
#   ./flash.sh boot            # прошить boot.img + vbmeta (телефон в fastboot)
#   ./flash.sh rootfs          # sideload rootfs- и devtools-zip (телефон в recovery)
#   ./flash.sh all             # rootfs, затем boot
#
# ВАЖНО про munch: это A/B-устройство БЕЗ раздела recovery — recovery встроен
# в ramdisk раздела boot. Кастомное recovery не прошивают (нет раздела
# 'recovery'!), а временно загружают: fastboot boot orangefox.img.
#
# Предварительно (однократно):
#   1. Разблокированный загрузчик (Mi Unlock).
#   2. Прошитая стоковая MIUI на базе Android 12/12.1 (Droidian использует
#      стоковый /vendor и firmware!).
#   3. Образ кастомного recovery для munch (TWRP / OrangeFox) — файл .img,
#      прошивать его никуда не нужно.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/config.env"

log() { printf '\033[1;32m[flash]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || die "Не найден $1 (пакет android-tools / platform-tools)"; }

# munch не имеет раздела recovery — временно грузим образ через fastboot boot
boot_recovery() {
    need fastboot
    local img="${1:-}"
    [ -n "$img" ] || die "Укажите образ recovery: ./flash.sh recovery /путь/orangefox.img"
    [ -f "$img" ] || die "Файл не найден: $img"
    log "Временно загружаю recovery (телефон в fastboot: Vol- + Power)…"
    if ! fastboot boot "$img"; then
        die "fastboot boot отклонён прошивкой. Запасной путь: прошейте образ в boot
временно (fastboot flash boot '$img'), загрузитесь в него, сделайте sideload,
затем верните наш Droidian boot: ./flash.sh boot"
    fi
    log "Телефон грузится в recovery. Дальше: ./flash.sh rootfs"
}

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
    recovery) boot_recovery "${2:-}" ;;
    boot)     flash_boot ;;
    rootfs)   flash_rootfs ;;
    all)      flash_rootfs; flash_boot ;;
    *)        sed -n '2,20p' "$0"; exit 1 ;;
esac
