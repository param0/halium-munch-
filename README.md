# Halium → Droidian для Xiaomi POCO F4 / Redmi K40S (munch)

Набор скриптов, автоматизирующий [официальный гайд портирования Droidian](https://github.com/droidian/porting-guide) для **munch** (Snapdragon 870 / SM8250-AC, ядро msm-4.19, заводской Android 12).

Схема соответствует текущему процессу Droidian: Halium-совместимое ядро собирается **deb-пакетами** через `linux-packaging-snippets` в контейнере `build-essential`, kconfig-требования Halium/Droidian накладываются **фрагментами** (`droidian/common_fragments`, ветка `4.19-android`), а rootfs берётся **официальный generic api32** (правило Droidian: api28 = Android 9, api29 = A10, api30 = A11, **api32 = A12/12.1** — munch именно такой).

```
./build.sh all
        │
        ├─ clone      Xiaomi_Kernel_OpenSource, ветка munch-s-oss (4.19.157)
        ├─ setup      debian/ (rules, compat, kernel-info.mk под munch)
        │             droidian/ (common_fragments 4.19-android + munch.config)
        ├─ build      quay.io/droidian/build-essential → releng-build-package
        │             → linux-image-*, linux-headers-*, linux-bootimage-*.deb
        ├─ artifacts  out/boot.img, out/vbmeta.img (+ dtbo.img, если собран)
        └─ rootfs     out/droidian-...rootfs-api32-arm64...zip + devtools api32
```

## Требования

- Linux x86_64, ~30 ГБ свободного места;
- `git`, `curl`, `docker` **или** `podman`;
- `adb`/`fastboot` для прошивки;
- сам телефон: **разблокированный загрузчик**, прошитая **стоковая MIUI на Android 12/12.1** (Droidian использует стоковые `/vendor` и firmware!), кастомное recovery (TWRP/OrangeFox для munch).

## Быстрый старт

```bash
./build.sh all        # полный цикл сборки и скачивания
./flash.sh rootfs     # телефон в recovery: format data + sideload rootfs/devtools
./flash.sh boot       # телефон в fastboot: boot.img + vbmeta (verity off)
```

Стадии можно запускать по отдельности (`clone`, `setup`, `build`, `artifacts`, `rootfs`), `./build.sh shell` даёт интерактивный shell в контейнере сборки, `./build.sh clean` всё удаляет.

## Что где настраивается

| Файл | Назначение |
|---|---|
| `config.env` | репозиторий/ветка ядра, defconfig, образ контейнера, версия rootfs |
| `templates/kernel-info.mk.in` | параметры boot.img (header v3, cmdline, SPL), тулчейн (clang 12.0-r416183b) |
| `droidian/munch.config` | девайсовый kconfig-фрагмент (LVM/device-mapper, systemd и т.п.) |

Версия ядра (`KERNEL_BASE_VERSION`) определяется автоматически из `Makefile` ядра на стадии `setup`.

По умолчанию берётся официальный дамп Xiaomi (`MiCode/Xiaomi_Kernel_OpenSource`, ветка `munch-s-oss`, defconfig `munch_user_defconfig`). Дампы MiCode бывают «сырыми» — если сборка падает, разумная альтернатива — общее ядро LineageOS `xiaomi-sm8250-devs/android_kernel_xiaomi_sm8250` (тогда поправьте `KERNEL_REPO`, `KERNEL_BRANCH` и `KERNEL_DEFCONFIG` в `config.env`).

## Особенности munch, учтённые в конфигурации

- **Boot header v3**: DTB загрузчик берёт из **стокового `vendor_boot`**, dtbo — из стокового раздела `dtbo`; поэтому в `boot.img` кладутся только ядро (`Image.gz`) и initramfs Droidian (`KERNEL_IMAGE_WITH_DTB = 0`). Стоковые `vendor_boot`/`dtbo` не трогаем.
- **SPL / anti-rollback**: `KERNEL_BOOTIMAGE_PATCH_LEVEL` в `kernel-info.mk` должен быть не ниже security patch level прошитой MIUI.
- **vbmeta**: пакет собирает пустой `vbmeta.img`; `flash.sh` шьёт его с `--disable-verity --disable-verification`.
- **cmdline**: базовый стоковый cmdline платформы kona + `androidboot.selinux=permissive buildvariant=userdebug droidian.lvm.prefer`. Сверьте со своим стоковым `boot.img` (`unpackbootimg`).

## Первая загрузка и отладка

Первый порт почти никогда не загружается с первого раза — это нормально. План действий:

1. Телефон поднимает USB-сеть (RNDIS). Если процесс дошёл только до initramfs — доступен `telnet 192.168.2.15`.
2. Если система загрузилась — `ssh droidian@10.15.19.82` (пароль `1234`; сеть поверх того же USB) или `adb shell`.
3. Логи: `journalctl`, `dmesg`, `/var/lib/lxc/android` (Android-контейнер), логи `logcat` изнутри контейнера.
4. Итерации по kconfig: правьте `droidian/munch.config`, затем `./build.sh setup build artifacts` и перепрошейте boot (`./flash.sh boot`).

Подробнее: [debugging-tips](https://github.com/droidian/porting-guide/blob/master/debugging-tips.md) официального гайда.

## Что дальше (после первой успешной загрузки)

- Собрать **adaptation-пакеты** устройства (udev-правила из `/vendor/etc/ueventd*.rc`, настройки сенсоров, аудио и т.д.) и, при желании, собственный fastboot-flashable rootfs через [droidian-build-tools](https://github.com/droidian-releng/droidian-build-tools) — см. [rootfs-creation](https://github.com/droidian/porting-guide/blob/master/rootfs-creation.md).
- Закоммитить каталоги `debian/` и `droidian/` в ветку `droidian` дерева ядра (`work/kernel`) — так делают все официальные устройства Droidian.

## Известные проблемы окружения

**Podman: `no subuid ranges found for user … in /etc/subuid`** — на машине не настроен rootless-режим podman. Однократно выполните:

```bash
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER
podman system migrate
```

и перезапустите сборку. Альтернатива — использовать docker: `CONTAINER_ENGINE=docker ./build.sh all`.

## Полезные ссылки

- Порт-гайд: https://github.com/droidian/porting-guide (зеркало: https://docs.droidian.org)
- Релизы rootfs/devtools: https://github.com/droidian-images/droidian/releases
- Общие kconfig-фрагменты: https://github.com/droidian-devices/common_fragments (ветка `4.19-android`)
- Исходники ядра munch: https://github.com/MiCode/Xiaomi_Kernel_OpenSource/tree/munch-s-oss
- Telegram/Matrix сообщества Droidian — ищите ответ поиском, прежде чем спрашивать :)
