#!/usr/bin/env bash
# =============================================================================
#  subir-a-github.sh
#  Reúne todo lo instalado en este PC servidor (backend, panel, mantenimiento,
#  menú de arranque, servicios y configuración) y lo sube al repositorio Body-aya.
#
#  NUNCA sube: el hash de tu contraseña, tus conversaciones, los respaldos ni las
#  llaves de Tailscale.
#
#  Uso (SIN sudo, desde la carpeta donde está este archivo):
#      bash subir-a-github.sh             reúne todo y lo sube
#      bash subir-a-github.sh --revisar   solo prepara la carpeta para revisarla
#  Se puede volver a ejecutar cuando quieras para actualizar la copia en GitHub.
# =============================================================================
set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/CarlosGabrielMunozReyes64-313/Body-aya.git}"
DESTINO="${DESTINO:-$HOME/Body-aya}"
RAIZ="${RAIZ:-}"                  # solo para pruebas: carpeta que hace de "/"
SIN_GH="${SIN_GH:-0}"             # solo para pruebas: no usar GitHub CLI
REVISAR=0
[[ ${1:-} == "--revisar" ]] && REVISAR=1

ORIGEN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERDE='\033[1;32m'; AMARILLO='\033[1;33m'; ROJO='\033[1;31m'; AZUL='\033[1;34m'; NORMAL='\033[0m'
paso()  { echo -e "\n${AZUL}━━━ $* ━━━${NORMAL}"; }
ok()    { echo -e "  ${VERDE}✔${NORMAL} $*"; }
aviso() { echo -e "  ${AMARILLO}!${NORMAL} $*"; }
fallo() { echo -e "\n${ROJO}✘ $*${NORMAL}" >&2; exit 1; }
trap 'echo -e "\n${ROJO}✘ Algo falló en la línea $LINENO: $BASH_COMMAND${NORMAL}" >&2' ERR

[[ $EUID -ne 0 ]] || fallo "Ejecútalo SIN sudo:  bash subir-a-github.sh  (te pedirá la contraseña cuando haga falta)"
[[ -d $ORIGEN/instaladores ]] || fallo "Ejecuta este script desde la carpeta Body-aya que descomprimiste."

# Archivos del sistema que forman el servidor (ruta dentro de "/")
ARCHIVOS=(
  opt/ia-servidor/app.py
  usr/local/bin/ia-servidor
  usr/local/bin/ia-monitor
  usr/local/bin/ia-monitor-ventana
  usr/local/bin/escritorio
  usr/local/bin/modo-servidor
  usr/local/sbin/ia-mantenimiento
  etc/systemd/system/ia-servidor.service
  etc/systemd/system/ia-servidor-respaldo.service
  etc/systemd/system/ia-servidor-respaldo.timer
  etc/systemd/system/ia-mantenimiento@.service
  etc/systemd/system/ia-mantenimiento-arranque.timer
  etc/systemd/system/ia-mantenimiento-nocturno.timer
  etc/grub.d/09_modos_ia
  etc/default/grub.d/99-modos-ia.cfg
  etc/profile.d/ia-servidor-modo.sh
  etc/issue.d/ia-servidor.issue
  etc/xdg/autostart/ia-monitor.desktop
  usr/share/applications/ia-monitor.desktop
  etc/logrotate.d/ia-mantenimiento
)
# Carpetas de ajustes extra de servicios (se copian todos sus .conf)
CARPETAS_CONF=(
  etc/systemd/system/ia-servidor.service.d
  etc/systemd/system/ollama.service.d
)

copiar() {  # copiar ruta_en_sistema destino  (usa sudo solo si el archivo no se puede leer)
  local origen="$RAIZ/$1" destino="$2"
  mkdir -p "$(dirname "$destino")"
  if [[ -r $origen ]]; then
    cp "$origen" "$destino"
  else
    # Se lee como administrador y se guarda como tu usuario, para que los archivos sean tuyos
    # shellcheck disable=SC2024
    sudo cat "$origen" > "$destino"
  fi
}

existe() { [[ -e "$RAIZ/$1" ]] || sudo test -e "$RAIZ/$1" 2>/dev/null; }

# ============================================================== 1. herramientas
paso "1/5 Herramientas"
if (( ! SIN_GH )); then
  faltan=()
  command -v git >/dev/null 2>&1 || faltan+=(git)
  command -v gh >/dev/null 2>&1 || faltan+=(gh)
  if (( ${#faltan[@]} )); then
    echo "  Instalando: ${faltan[*]} (te pedirá tu contraseña de Ubuntu)"
    sudo apt-get install -y -q -o DPkg::Lock::Timeout=600 "${faltan[@]}" >/dev/null
  fi
  ok "git y GitHub CLI listos"
else
  command -v git >/dev/null 2>&1 || fallo "Falta git."
  ok "git listo (modo de prueba, sin GitHub CLI)"
fi

# ============================================================== 2. cuenta de GitHub
paso "2/5 Cuenta de GitHub"
if (( SIN_GH )); then
  ok "omitido (modo de prueba)"
elif gh auth status --hostname github.com >/dev/null 2>&1; then
  ok "Ya iniciaste sesión en GitHub como $(gh api user -q .login)"
else
  echo
  echo "  Ahora aparecerá un código de 8 letras (por ejemplo ABCD-1234)."
  echo "  1. Abre en cualquier navegador, puede ser tu celular:  https://github.com/login/device"
  echo "  2. Escribe el código y autoriza."
  echo "  Si te pregunta si quieres abrir el navegador, solo presiona Enter."
  echo
  gh auth login --hostname github.com --git-protocol https --web
  ok "Sesión iniciada como $(gh api user -q .login)"
fi
(( SIN_GH )) || gh auth setup-git --hostname github.com

# ============================================================== 3. repositorio
paso "3/5 Repositorio"
if [[ -d $DESTINO/.git ]]; then
  git -C "$DESTINO" remote get-url origin | grep -q "Body-aya\|$REPO_URL" \
    || fallo "$DESTINO ya existe y es de otro repositorio. Muévelo o bórralo y vuelve a intentar."
  if git -C "$DESTINO" rev-parse --verify -q HEAD >/dev/null; then
    git -C "$DESTINO" pull -q --rebase || aviso "No se pudo actualizar desde GitHub; se continúa con la copia local."
  fi
  ok "Usando la copia en $DESTINO"
else
  [[ ! -e $DESTINO ]] || fallo "$DESTINO ya existe y no es un repositorio. Muévelo o bórralo y vuelve a intentar."
  git clone -q "$REPO_URL" "$DESTINO" 2>/dev/null || fallo "No pude descargar $REPO_URL. ¿Existe y tienes acceso?"
  ok "Repositorio descargado en $DESTINO"
fi

# ============================================================== 4. reunir archivos
paso "4/5 Reuniendo lo instalado en este PC"
if [[ $ORIGEN -ef $DESTINO ]]; then
  ok "Instaladores (ya están en el repositorio)"
else
  cp "$ORIGEN/README.md" "$ORIGEN/.gitignore" "$ORIGEN/subir-a-github.sh" "$DESTINO/"
  rm -rf "$DESTINO/instaladores"
  cp -r "$ORIGEN/instaladores" "$DESTINO/instaladores"
  ok "Instaladores"
fi
rm -rf "$DESTINO/sistema"

SISTEMA="$DESTINO/sistema"
mkdir -p "$SISTEMA"
copiados=0
for ruta in "${ARCHIVOS[@]}"; do
  if existe "$ruta"; then
    copiar "$ruta" "$SISTEMA/$ruta"
    copiados=$((copiados + 1))
  else
    aviso "No está en este PC (se omite): /$ruta"
  fi
done
for carpeta in "${CARPETAS_CONF[@]}"; do
  for conf in "$RAIZ/$carpeta"/*.conf; do
    [[ -e $conf ]] || continue
    copiar "$carpeta/$(basename "$conf")" "$SISTEMA/$carpeta/$(basename "$conf")"
    copiados=$((copiados + 1))
  done
done
ok "$copiados archivos del sistema copiados en sistema/ (con la misma ruta que tienen en el PC)"

# Configuración SIN el hash de la contraseña
CONF=etc/ia-servidor/config.env
if existe "$CONF"; then
  mkdir -p "$SISTEMA/etc/ia-servidor"
  copiar "$CONF" "$SISTEMA/etc/ia-servidor/config.env.tmp"
  sed -e 's|^IA_PASSWORD_HASH=.*|IA_PASSWORD_HASH=""   # se crea al instalar; nunca se sube a GitHub|' \
    "$SISTEMA/etc/ia-servidor/config.env.tmp" > "$SISTEMA/etc/ia-servidor/config.env.ejemplo"
  rm -f "$SISTEMA/etc/ia-servidor/config.env.tmp"
  ok "Configuración copiada como config.env.ejemplo, sin la contraseña"
fi

# Versiones de las librerías del backend
if [[ -x $RAIZ/opt/ia-servidor/venv/bin/pip ]]; then
  "$RAIZ/opt/ia-servidor/venv/bin/pip" freeze 2>/dev/null > "$SISTEMA/opt/ia-servidor/requirements.txt" || true
  ok "Librerías de Python del backend (requirements.txt)"
fi

# Resumen del equipo
{
  echo "Copia tomada: $(date '+%Y-%m-%d %H:%M')"
  echo "Sistema: $( (. "$RAIZ/etc/os-release" 2>/dev/null && echo "$PRETTY_NAME") || echo desconocido)"
  echo "Kernel: $(uname -r)"
  if command -v ollama >/dev/null 2>&1 && [[ -z $RAIZ ]]; then
    echo "Ollama: $(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -n1)"
    echo
    echo "Modelos instalados:"
    ollama list 2>/dev/null | sed 's/^/  /'
  fi
} > "$SISTEMA/INFO.txt"
ok "Resumen del equipo (sistema/INFO.txt)"

# Revisión de seguridad: nada privado puede quedar en la carpeta
privados=$(grep -rlE 'scrypt:[0-9]+:[0-9]+:[0-9]+:[0-9a-f]{16,}' "$DESTINO" --exclude-dir=.git || true)
[[ -z $privados ]] || fallo "Se encontró el hash de una contraseña en: $privados. No se subió nada."
datos=$(find "$DESTINO" -path "$DESTINO/.git" -prune -o \( -name '*.db' -o -name '*.db-journal' -o -name '*.jsonl' -o -name 'tailscaled.state' \) -print)
[[ -z $datos ]] || fallo "Se encontraron datos privados: $datos. No se subió nada."
ok "Revisión de seguridad: sin contraseñas, conversaciones ni llaves"

if (( REVISAR )); then
  echo -e "\n${VERDE}Carpeta lista para revisar en: $DESTINO${NORMAL}"
  echo "  No se subió nada. Cuando quieras subirla:  bash subir-a-github.sh"
  exit 0
fi

# ============================================================== 5. subir
paso "5/5 Subiendo a GitHub"
cd "$DESTINO"
if ! git config user.name >/dev/null; then
  if (( SIN_GH )); then
    git config user.name "Prueba"; git config user.email "prueba@ejemplo.com"
  else
    usuario=$(gh api user -q .login)
    git config user.name "$usuario"
    git config user.email "$(gh api user -q .id)+$usuario@users.noreply.github.com"
  fi
fi
git add -A
if git diff --cached --quiet; then
  ok "No hay cambios desde la última vez: GitHub ya tiene la versión actual"
  exit 0
fi
git commit -q -m "Copia del servidor de Aya ($(date '+%Y-%m-%d %H:%M'))"
git branch -M main
git push -q -u origin main
ok "Subido"

echo -e "\n${VERDE}══════════════════════════════════════════════════════════════${NORMAL}"
echo -e "${VERDE}  ¡Listo! El servidor de Aya está en GitHub:${NORMAL}"
echo    "  ${REPO_URL%.git}"
echo -e "${VERDE}══════════════════════════════════════════════════════════════${NORMAL}"
echo "  Para actualizar la copia más adelante, vuelve a ejecutar:  bash ~/Body-aya/subir-a-github.sh"
