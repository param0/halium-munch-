#!/usr/bin/env bash
# =============================================================================
# Сборка Halium-ядра и подготовка Droidian для Xiaomi POCO F4 (munch)
#
# Использование:
#   ./build.sh all                # полный цикл: clone -> setup -> build -> artifacts -> rootfs
#   ./build.sh clone              # клонировать исходники ядра
#   ./build.sh setup              # наложить Droidian-пакетирование (debian/, droidian/)
#   ./build.sh build              # собрать deb-пакеты ядра в контейнере
#   ./build.sh artifacts          # извлечь boot.img / vbmeta.img / dtbo.img в out/
#   ./build.sh rootfs             # скачать официальный rootfs Droidian (api32) + devtools
#   ./build.sh shell              # интерактивный shell в контейнере сборки (отладка)
#   ./build.sh clean              # удалить work/ и out/
#
# Настройки: config.env (или переменные окружения поверх него).
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.env
source "$ROOT_DIR/config.env"

log()  { printf '\033[1;32m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# --- Определение контейнерного движка ----------------------------------------
engine() {
    if [ -n "$CONTAINER_ENGINE" ]; then
        command -v "$CONTAINER_ENGINE" >/dev/null || die "$CONTAINER_ENGINE не найден"
        echo "$CONTAINER_ENGINE"
    elif command -v docker >/dev/null; then
        echo docker
    elif command -v podman >/dev/null; then
        echo podman
    else
        die "Нужен docker или podman (см. README.md)"
    fi
}

check_podman_rootless() {
    # rootless podman требует диапазонов subuid/subgid для пользователя
    local user uid
    user="$(id -un)"; uid="$(id -u)"
    [ "$uid" -eq 0 ] && return 0
    if command -v getsubids >/dev/null; then
        getsubids "$user" >/dev/null 2>&1 && return 0
    elif grep -qsE "^($user|$uid):" /etc/subuid && grep -qsE "^($user|$uid):" /etc/subgid; then
        return 0
    fi
    die "Rootless podman не настроен: нет subuid/subgid для '$user'.
Выполните один раз:
    sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $user
    podman system migrate
и перезапустите сборку. Либо используйте docker: CONTAINER_ENGINE=docker $0 …"
}

check_deps() {
    local missing=()
    for tool in git curl; do
        command -v "$tool" >/dev/null || missing+=("$tool")
    done
    [ ${#missing[@]} -eq 0 ] || die "Не хватает утилит: ${missing[*]}"
    local eng; eng="$(engine)"
    [ "$eng" = podman ] && check_podman_rootless
    log "Зависимости на месте (контейнеры: $eng)"
}

# --- Стадия: клонирование ядра ------------------------------------------------
do_clone() {
    if [ -d "$KERNEL_DIR/.git" ]; then
        log "Исходники ядра уже есть: $KERNEL_DIR — пропускаю clone"
        return
    fi
    mkdir -p "$WORK_DIR"
    log "Клонирую $KERNEL_REPO (ветка $KERNEL_BRANCH)…"
    git clone --depth 1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
    git -C "$KERNEL_DIR" checkout -b droidian
    log "Ядро склонировано, создана ветка 'droidian'"
}

# --- Стадия: Droidian-пакетирование -------------------------------------------
kernel_version() {
    # VERSION/PATCHLEVEL/SUBLEVEL из Makefile ядра -> например 4.19.157
    awk '/^VERSION[ \t]*=/{v=$3} /^PATCHLEVEL[ \t]*=/{p=$3} /^SUBLEVEL[ \t]*=/{s=$3} END{print v"."p"."s}' \
        "$KERNEL_DIR/Makefile"
}

do_setup() {
    [ -f "$KERNEL_DIR/Makefile" ] || die "Нет исходников ядра — сначала ./build.sh clone"

    local kver
    kver="$(kernel_version)"
    [[ "$kver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Не смог определить версию ядра (получил '$kver')"
    log "Версия ядра: $kver"

    if [ ! -f "$KERNEL_DIR/arch/arm64/configs/$KERNEL_DEFCONFIG" ] && \
       [ ! -f "$KERNEL_DIR/arch/arm64/configs/vendor/$KERNEL_DEFCONFIG" ]; then
        warn "Defconfig '$KERNEL_DEFCONFIG' не найден в arch/arm64/configs/ — проверьте KERNEL_DEFCONFIG в config.env"
    fi

    # debian/ — скелет пакетирования по официальному гайду Droidian
    mkdir -p "$KERNEL_DIR/debian/source"
    echo 13 > "$KERNEL_DIR/debian/compat"
    echo "3.0 (native)" > "$KERNEL_DIR/debian/source/format"
    install -m 0755 "$ROOT_DIR/templates/rules" "$KERNEL_DIR/debian/rules"
    sed -e "s|@KERNEL_BASE_VERSION@|$kver|g" \
        -e "s|@KERNEL_DEFCONFIG@|$KERNEL_DEFCONFIG|g" \
        "$ROOT_DIR/templates/kernel-info.mk.in" > "$KERNEL_DIR/debian/kernel-info.mk"

    # droidian/ — kconfig-фрагменты: общие (common_fragments) + девайсовый
    mkdir -p "$KERNEL_DIR/droidian"
    if [ ! -d "$KERNEL_DIR/droidian/common_fragments" ]; then
        log "Клонирую общие фрагменты ($FRAGMENTS_BRANCH)…"
        git clone --depth 1 --branch "$FRAGMENTS_BRANCH" "$FRAGMENTS_REPO" \
            "$KERNEL_DIR/droidian/common_fragments"
        rm -rf "$KERNEL_DIR/droidian/common_fragments/.git"
    fi
    cp -v "$ROOT_DIR"/droidian/*.config "$KERNEL_DIR/droidian/"

    log "Пакетирование готово: $KERNEL_DIR/debian, $KERNEL_DIR/droidian"
}

# --- Стадия: сборка в контейнере -----------------------------------------------
container_script() {
    cat > "$PACKAGES_DIR/container-build.sh" <<'EOS'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y linux-packaging-snippets
cd /buildd/sources
rm -f debian/control
debian/rules debian/control
RELENG_HOST_ARCH="arm64" releng-build-package
EOS
    chmod +x "$PACKAGES_DIR/container-build.sh"
}

do_build() {
    [ -f "$KERNEL_DIR/debian/kernel-info.mk" ] || die "Нет debian/kernel-info.mk — сначала ./build.sh setup"
    mkdir -p "$PACKAGES_DIR"
    container_script
    local eng; eng="$(engine)"
    log "Собираю ядро в контейнере $BUILD_IMAGE ($eng)…"
    "$eng" run --rm \
        -v "$PACKAGES_DIR:/buildd" \
        -v "$KERNEL_DIR:/buildd/sources" \
        "$BUILD_IMAGE" bash /buildd/container-build.sh
    log "Готово. Пакеты:"
    ls -1 "$PACKAGES_DIR"/*.deb 2>/dev/null || warn "deb-пакеты не найдены в $PACKAGES_DIR"
}

# --- Стадия: извлечение артефактов ----------------------------------------------
do_artifacts() {
    mkdir -p "$OUT_DIR"
    local eng; eng="$(engine)"
    ls "$PACKAGES_DIR"/linux-bootimage-*.deb >/dev/null 2>&1 || \
        die "Нет linux-bootimage-*.deb в $PACKAGES_DIR — сначала ./build.sh build"
    log "Извлекаю образы из linux-bootimage-*.deb…"
    "$eng" run --rm \
        -v "$PACKAGES_DIR:/buildd:ro" \
        -v "$OUT_DIR:/out" \
        "$BUILD_IMAGE" bash -c '
            set -e
            for d in /buildd/linux-bootimage-*.deb; do
                rm -rf /tmp/x && mkdir /tmp/x
                dpkg-deb -x "$d" /tmp/x
                find /tmp/x -name "*.img" -exec cp -v {} /out/ \;
            done'
    log "Артефакты в $OUT_DIR:"
    ls -lh "$OUT_DIR"
}

# --- Стадия: rootfs Droidian -----------------------------------------------------
fetch() { # url dest
    if [ -f "$2" ]; then
        log "Уже скачан: $(basename "$2")"
    else
        log "Скачиваю $(basename "$2")…"
        curl -fSL --retry 4 --retry-delay 2 -o "$2.part" "$1"
        mv "$2.part" "$2"
    fi
}

do_rootfs() {
    mkdir -p "$OUT_DIR"
    local tag="${DROIDIAN_RELEASE_TAG//\//%2F}"
    fetch "$DROIDIAN_DOWNLOAD_BASE/$tag/$DROIDIAN_ROOTFS_ZIP"   "$OUT_DIR/$DROIDIAN_ROOTFS_ZIP"
    fetch "$DROIDIAN_DOWNLOAD_BASE/$tag/$DROIDIAN_DEVTOOLS_ZIP" "$OUT_DIR/$DROIDIAN_DEVTOOLS_ZIP"
    log "Rootfs и devtools лежат в $OUT_DIR — прошивка: ./flash.sh (см. README.md)"
}

# --- Вспомогательные -------------------------------------------------------------
do_shell() {
    mkdir -p "$PACKAGES_DIR"
    local eng; eng="$(engine)"
    "$eng" run --rm -it \
        -v "$PACKAGES_DIR:/buildd" \
        -v "$KERNEL_DIR:/buildd/sources" \
        "$BUILD_IMAGE" bash
}

do_clean() {
    rm -rf "$WORK_DIR" "$OUT_DIR"
    log "Удалены $WORK_DIR и $OUT_DIR"
}

# --- Точка входа -------------------------------------------------------------------
usage() { sed -n '2,16p' "$0"; }

main() {
    local stage="${1:-}"
    case "$stage" in
        all)       check_deps; do_clone; do_setup; do_build; do_artifacts; do_rootfs ;;
        deps)      check_deps ;;
        clone)     check_deps; do_clone ;;
        setup)     do_setup ;;
        build)     check_deps; do_build ;;
        artifacts) check_deps; do_artifacts ;;
        rootfs)    do_rootfs ;;
        shell)     check_deps; do_shell ;;
        clean)     do_clean ;;
        *)         usage; exit 1 ;;
    esac
}

main "$@"
