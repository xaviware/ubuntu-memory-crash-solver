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
#   2) Opcionalmente amplia el swapfile activo (--swap SIZE).
#   3) Activa zswap con zstd (compresion de memoria, recomendado por Ubuntu
#      para equipos de 2-8 GB con disco lento/HDD).
#
# Uso:
#   sudo bash fix-memory.sh               # oomd + zswap
#   sudo bash fix-memory.sh --swap 8G     # ademas amplia el swapfile a 8G
#   sudo bash fix-memory.sh --help
#
# El cambio de swap es opcional, solo amplia (nunca reduce) y requiere espacio
# libre en el disco. swapoff devuelve las paginas a RAM: cierra apps pesadas.
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo bash fix-memory.sh [--swap SIZE]

  (sin opciones)  Ajusta systemd-oomd y activa zswap (zstd).
  --swap SIZE     Ademas amplia el swapfile activo a SIZE (p.ej. 8G, 8192M).
                  Solo amplia, nunca reduce. Necesita espacio libre y RAM
                  suficiente para hacer swapoff temporalmente.
  -h, --help      Muestra esta ayuda.
EOF
}

SWAP_SIZE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --swap)
      if [[ $# -lt 2 ]]; then
        echo "Falta el tamano para --swap (ej: --swap 8G)" >&2
        exit 1
      fi
      SWAP_SIZE="$2"
      shift 2
      ;;
    --swap=*)
      SWAP_SIZE="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Opcion desconocida: $1 (usa --help)" >&2
      exit 1
      ;;
  esac
done

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

size_to_bytes() {
  local s="${1^^}"
  s="${s%B}"
  if [[ ! "$s" =~ ^[0-9]+[KMGT]?$ ]]; then
    return 1
  fi
  numfmt --from=iec "$s"
}

find_swapfile() {
  local name type
  while read -r name type _; do
    if [[ "$type" == "file" ]]; then
      echo "$name"
      return 0
    fi
  done < <(swapon --show=NAME,TYPE --noheadings 2>/dev/null)
  return 1
}

grow_swap() {
  local want="$1" want_bytes swapfile cur_bytes mb

  if ! want_bytes="$(size_to_bytes "$want")"; then
    echo "  tamano invalido: '$want' (usa p.ej. 4G, 8G, 8192M)" >&2
    return 1
  fi
  if ! swapfile="$(find_swapfile)"; then
    echo "  no hay swapfile activo; nada que ampliar (esto no crea swap desde cero)" >&2
    return 1
  fi

  cur_bytes="$(stat -c %s "$swapfile")"
  if (( want_bytes <= cur_bytes )); then
    echo "  swap actual ($(numfmt --to=iec "$cur_bytes")) >= pedido ($want); sin cambios."
    return 0
  fi

  echo "  ampliando $swapfile de $(numfmt --to=iec "$cur_bytes") a $want ..."
  if ! swapoff "$swapfile"; then
    echo "  no se pudo desactivar el swap. Cierra apps y reintenta." >&2
    return 1
  fi

  if ! fallocate -l "$want" "$swapfile" 2>/dev/null; then
    echo "  fallocate no disponible/fallo; usando dd (puede tardar en HDD)..."
    mb=$(( (want_bytes + 1048575) / 1048576 ))
    if ! dd if=/dev/zero of="$swapfile" bs=1M count="$mb" status=progress; then
      echo "  dd fallo; reactivando el swap como estaba..." >&2
      mkswap "$swapfile" >/dev/null 2>&1 || true
      swapon "$swapfile" 2>/dev/null || true
      return 1
    fi
  fi

  chmod 600 "$swapfile"
  mkswap "$swapfile" >/dev/null
  swapon "$swapfile"
  echo "  swap ampliado: $(swapon --show --noheadings | awk -v f="$swapfile" '$1==f{print $3}')"
}

echo "==> 1/5  Ajustando systemd-oomd (de 50%/20s a 85%/60s)"

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

echo "==> 2/5  Swap (opcional)"
if [[ -n "$SWAP_SIZE" ]]; then
  grow_swap "$SWAP_SIZE" || echo "  (swap sin cambios; continuando con el resto)"
else
  echo "  omitido (usa --swap 8G si quieres ampliar el swapfile)"
fi

echo "==> 3/5  Activando zswap (zstd, max 40% de RAM) de forma persistente"

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

echo "==> 4/5  Regenerando initramfs y GRUB"
update-initramfs -u
update-grub

echo "==> 5/5  Recargando systemd y aplicando zswap en caliente (si es posible)"
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
echo "--- swap ---"
swapon --show || true
free -h || true
echo
echo "--- zswap ---"
for f in enabled compressor max_pool_percent; do
  printf '  %s = ' "$f"; cat "/sys/module/zswap/parameters/$f" 2>/dev/null || echo "n/a"
done
printf '  Zswap en memoria: '; awk '/^Zswap:/{print $2" "$3}' /proc/meminfo
echo
echo "Listo. Reinicia para que zswap arranque desde el kernel:"
echo "  sudo reboot"
echo "Despues del reinicio verifica con:  grep -E 'Zswap|Zswapped' /proc/meminfo; oomctl"
