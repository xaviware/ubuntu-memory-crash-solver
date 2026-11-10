#!/usr/bin/env bash
#
# Solucion de crashes por presion de memoria en Ubuntu (iMac18,1 / 8 GB / HDD).
#
# Causa raiz: systemd-oomd mata apps cuando la presion de memoria del cgroup
# user@1000.service supera 50% durante 20s. En un equipo de 8 GB con swap en
# un HDD lento, eso ocurre constantemente y mata Cursor/Code/Chromium/Firefox.
#
# Este script:
#   1) Vuelve systemd-oomd mucho menos agresivo (85% / 60s, swap 95%).
#   2) Activa zswap con zstd (compresion de memoria, recomendado por Ubuntu
#      para equipos de 2-8 GB con disco lento/HDD).
#
# Uso:
#   sudo bash fix-memory.sh
#   sudo reboot        # necesario para que zswap arranque desde el kernel
#
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Ejecuta este script con sudo:  sudo bash $0" >&2
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
backup() {
  local f="$1"
  if [[ -f "$f" ]] && [[ ! -f "${f}.bak.${STAMP}" ]]; then
    cp -a "$f" "${f}.bak.${STAMP}"
    echo "  backup: ${f}.bak.${STAMP}"
  fi
}

echo "==> 1/4  Ajustando systemd-oomd (de 50%/20s a 85%/60s)"

install -d /etc/systemd/oomd.conf.d
OOMD_CONF=/etc/systemd/oomd.conf.d/99-memory-crash-solver.conf
backup "$OOMD_CONF"
cat > "$OOMD_CONF" <<'EOF'
# Evita que systemd-oomd mate apps de escritorio prematuramente.
# El kernel OOM killer sigue actuando ante agotamiento real.
[OOM]
DefaultMemoryPressureLimit=90%
DefaultMemoryPressureDurationSec=60s
SwapUsedLimit=95%
EOF

install -d /etc/systemd/system/user@.service.d
USER_OOMD=/etc/systemd/system/user@.service.d/99-memory-crash-solver.conf
backup "$USER_OOMD"
cat > "$USER_OOMD" <<'EOF'
# Ubuntu por defecto fija 50% en user@.service. Lo subimos a 85%.
# La duracion (60s) viene de DefaultMemoryPressureDurationSec en oomd.conf.d.
[Service]
ManagedOOMMemoryPressureLimit=85%
EOF

echo "==> 2/4  Activando zswap (zstd, max 40% de RAM) de forma persistente"

# Modulos de compresion disponibles en el arranque temprano
for mod in zstd lz4; do
  if ! grep -qxF "$mod" /etc/initramfs-tools/modules 2>/dev/null; then
    echo "$mod" >> /etc/initramfs-tools/modules
    echo "  modulo anadido a initramfs: $mod"
  fi
done

# Parametros del kernel en GRUB (idempotente)
backup /etc/default/grub
if ! grep -q 'zswap\.enabled=1' /etc/default/grub; then
  sed -i 's|^\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"|\1 zswap.enabled=1 zswap.compressor=zstd zswap.max_pool_percent=40"|' /etc/default/grub
  echo "  parametros zswap agregados a GRUB"
else
  echo "  GRUB ya tenia zswap.enabled=1 (sin cambios)"
fi

echo "==> 3/4  Regenerando initramfs y GRUB"
update-initramfs -u
update-grub

echo "==> 4/4  Recargando systemd y aplicando zswap en caliente (si es posible)"
systemctl daemon-reload
systemctl restart systemd-oomd

# zswap en caliente: el compresor solo se puede cambiar si el pool esta vacio.
if [[ "$(cat /sys/module/zswap/parameters/enabled 2>/dev/null)" != "Y" ]]; then
  echo zstd > /sys/module/zswap/parameters/compressor 2>/dev/null || true
  echo 40   > /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || true
  if echo 1 > /sys/module/zswap/parameters/enabled 2>/dev/null; then
    echo "  zswap habilitado en caliente"
  else
    echo "  (zswap se habilitara al reiniciar)"
  fi
fi

echo
echo "===== Verificacion ====="
echo "--- oomd ---"
oomctl 2>/dev/null | sed -n '1,20p' || true
echo
echo "--- zswap ---"
for f in enabled compressor max_pool_percent; do
  printf '  %s = ' "$f"; cat "/sys/module/zswap/parameters/$f" 2>/dev/null || echo "n/a"
done
printf '  Zswap en memoria: '; awk '/^Zswap:/{print $2" "$3}' /proc/meminfo
echo
echo "Listo. Reinicia para que zswap arranque desde el kernel:"
echo "  sudo reboot"
echo "Despues del reinicio verifica con:  zswap_ok(){ :; }; grep -E 'zswap|Zswap' /proc/meminfo; oomctl"
