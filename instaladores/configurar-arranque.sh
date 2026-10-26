#!/usr/bin/env bash
# =============================================================================
#  configurar-arranque.sh
#  Al encender el PC aparece un menú de texto:
#     1  Modo servidor    → solo terminal, sin interfaz gráfica (la IA funciona)
#     2  Modo escritorio  → Ubuntu normal con interfaz gráfica
#  Si nadie toca el teclado, arranca solo en modo servidor (útil tras un corte de luz).
#
#  Uso:   sudo bash configurar-arranque.sh            instala el menú
#         sudo bash configurar-arranque.sh --quitar   vuelve al arranque normal
# =============================================================================
set -Eeuo pipefail

# ------------------------------------------------------------------ ajustes
ESPERA=10                 # segundos que espera el menú antes de elegir solo
OPCION_POR_DEFECTO=1      # 1 = modo servidor, 2 = modo escritorio

GRUB_GENERADOR=/etc/grub.d/09_modos_ia
GRUB_AJUSTES=/etc/default/grub.d/99-modos-ia.cfg
ISSUE=/etc/issue.d/ia-servidor.issue
BIENVENIDA=/etc/profile.d/ia-servidor-modo.sh
CMD_ESCRITORIO=/usr/local/bin/escritorio
GRUB_CFG=/boot/grub/grub.cfg

# ------------------------------------------------------------------ utilidades
VERDE='\033[1;32m'; AMARILLO='\033[1;33m'; ROJO='\033[1;31m'; AZUL='\033[1;34m'; NORMAL='\033[0m'
paso()  { echo -e "\n${AZUL}━━━ $* ━━━${NORMAL}"; }
ok()    { echo -e "  ${VERDE}✔${NORMAL} $*"; }
aviso() { echo -e "  ${AMARILLO}!${NORMAL} $*"; }
fallo() { echo -e "\n${ROJO}✘ $*${NORMAL}" >&2; exit 1; }
trap 'echo -e "\n${ROJO}✘ Algo falló en la línea $LINENO: $BASH_COMMAND${NORMAL}" >&2' ERR

[[ $EUID -eq 0 ]] || fallo "Ejecuta el script con sudo:  sudo bash $0"
command -v update-grub >/dev/null 2>&1 || fallo "No encontré update-grub. ¿Este Ubuntu usa GRUB?"
[[ -f $GRUB_CFG ]] || fallo "No encontré $GRUB_CFG."

# ------------------------------------------------------------------ quitar
if [[ ${1:-} == "--quitar" ]]; then
  paso "Quitando el menú de modos"
  rm -f "$GRUB_GENERADOR" "$GRUB_AJUSTES" "$ISSUE" "$BIENVENIDA" "$CMD_ESCRITORIO"
  update-grub 2>&1 | sed 's/^/    /'
  ok "Listo: el PC vuelve a arrancar como antes, directo a Ubuntu con interfaz gráfica."
  exit 0
fi

case "$OPCION_POR_DEFECTO" in
  1) ID_DEFECTO="modo-servidor" ;;
  2) ID_DEFECTO="modo-escritorio" ;;
  *) fallo "OPCION_POR_DEFECTO debe ser 1 o 2." ;;
esac

# ------------------------------------------------------------------ 1. opciones del menú
paso "1/4 Opciones del menú de arranque"
cp "$GRUB_CFG" "$GRUB_CFG.antes-modos-ia"

# Este generador se ejecuta cada vez que Ubuntu actualiza el menú (por ejemplo al
# instalar un kernel nuevo), así que las opciones siempre apuntan al kernel actual.
cat > "$GRUB_GENERADOR" <<'GEN'
#!/bin/sh
# Opciones "Modo servidor" y "Modo escritorio" del menú de arranque.
# Creado por configurar-arranque.sh  (para quitarlo: sudo bash configurar-arranque.sh --quitar)
set -e

prefix="/usr"
exec_prefix="/usr"
datarootdir="/usr/share"
. "${datarootdir}/grub/grub-mkconfig_lib"

# Kernel más reciente (Ubuntu mantiene los enlaces /boot/vmlinuz y /boot/initrd.img)
if [ -e /boot/vmlinuz ] && [ -e /boot/initrd.img ]; then
  KERNEL="vmlinuz"
  INITRD="initrd.img"
else
  KERNEL="$(cd /boot && ls -1 vmlinuz-* 2>/dev/null | sort -V | tail -n1)"
  [ -n "$KERNEL" ] || exit 0
  INITRD="initrd.img-${KERNEL#vmlinuz-}"
fi

RUTA_BOOT="$(make_system_path_relative_to_its_root /boot)"
if [ "x${GRUB_DEVICE_UUID}" != "x" ] && [ "x${GRUB_DISABLE_LINUX_UUID}" != "xtrue" ]; then
  RAIZ="UUID=${GRUB_DEVICE_UUID}"
else
  RAIZ="${GRUB_DEVICE}"
fi
ACCESO="$(prepare_grub_to_access_device ${GRUB_DEVICE_BOOT} | grub_add_tab)"

echo "Agregando opciones de modo servidor y modo escritorio" >&2

cat << EOF
menuentry '1    Modo servidor     (solo terminal, la IA queda funcionando)' --hotkey=1 --class ubuntu --class gnu-linux --class os \$menuentry_id_option 'modo-servidor' {
	load_video
	insmod gzio
${ACCESO}
	echo	'Iniciando en modo servidor...'
	linux	${RUTA_BOOT}/${KERNEL} root=${RAIZ} ro ${GRUB_CMDLINE_LINUX} quiet systemd.unit=multi-user.target
	initrd	${RUTA_BOOT}/${INITRD}
}
menuentry '2    Modo escritorio   (Ubuntu con interfaz grafica)' --hotkey=2 --class ubuntu --class gnu-linux --class os \$menuentry_id_option 'modo-escritorio' {
	load_video
	set gfxpayload=keep
	insmod gzio
${ACCESO}
	linux	${RUTA_BOOT}/${KERNEL} root=${RAIZ} ro ${GRUB_CMDLINE_LINUX} ${GRUB_CMDLINE_LINUX_DEFAULT} vt.handoff=7
	initrd	${RUTA_BOOT}/${INITRD}
}
EOF
GEN
chmod 0755 "$GRUB_GENERADOR"

mkdir -p /etc/default/grub.d
cat > "$GRUB_AJUSTES" <<EOF
# Menú de arranque del servidor de IA (creado por configurar-arranque.sh)
# Opción que se elige sola si nadie toca el teclado
GRUB_DEFAULT="$ID_DEFECTO"
GRUB_SAVEDEFAULT=false
# Mostrar siempre el menú y esperar $ESPERA segundos
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=$ESPERA
# Después de un corte de luz, esperar lo mismo en vez de 30 segundos
GRUB_RECORDFAIL_TIMEOUT=$ESPERA
EOF
ok "Opciones creadas (por defecto: opción $OPCION_POR_DEFECTO, tras $ESPERA segundos)"

# ------------------------------------------------------------------ 2. regenerar y verificar
paso "2/4 Actualizando el menú de arranque"
deshacer() {
  aviso "Deshaciendo los cambios para no arriesgar el arranque..."
  rm -f "$GRUB_GENERADOR" "$GRUB_AJUSTES"
  update-grub >/dev/null 2>&1 || cp "$GRUB_CFG.antes-modos-ia" "$GRUB_CFG"
  fallo "$1  El arranque quedó como estaba antes."
}
if ! update-grub 2>&1 | sed 's/^/    /'; then
  deshacer "update-grub falló."
fi
if command -v grub-script-check >/dev/null 2>&1 && ! grub-script-check "$GRUB_CFG"; then
  deshacer "El menú generado tiene errores."
fi
grep -q "'modo-servidor'" "$GRUB_CFG" || deshacer "No aparecieron las opciones nuevas en el menú."
grep -q "'modo-escritorio'" "$GRUB_CFG" || deshacer "No aparecieron las opciones nuevas en el menú."
ok "Menú actualizado y verificado"

# ------------------------------------------------------------------ 3. pantalla del modo servidor
paso "3/4 Pantalla de bienvenida del modo servidor"
mkdir -p /etc/issue.d
cat > "$ISSUE" <<'EOF'

  ==============================================================
     SERVIDOR DE IA  -  Modo servidor (la IA está funcionando)
  ==============================================================
     Inicia sesión con tu usuario de Ubuntu para ver la IA en vivo.
     Para abrir la interfaz gráfica, después escribe:  escritorio

EOF

cat > "$BIENVENIDA" <<'EOF'
# Al iniciar sesión en la terminal de texto (modo servidor) muestra el panel de la IA en vivo.
# Creado por los scripts del servidor de IA.
case "$(tty 2>/dev/null)" in
  /dev/tty[0-9]*)
    case "$-" in
      *i*)
        if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
          if [ -x /usr/local/bin/ia-monitor ]; then
            /usr/local/bin/ia-monitor
            clear
          elif [ -x /usr/local/bin/ia-servidor ]; then
            /usr/local/bin/ia-servidor estado 2>/dev/null || true
          fi
          echo
          echo "  ── Modo servidor ──────────────────────────────────────────────"
          echo "  Comandos:   ia-monitor              ver la IA trabajando en vivo"
          echo "              escritorio              abrir la interfaz gráfica"
          echo "              ia-servidor             opciones del servidor de IA"
          echo "              sudo ia-mantenimiento   actualizar y limpiar ahora"
          echo "              sudo reboot             reiniciar (vuelve a salir el menú)"
          echo "              sudo poweroff           apagar el PC"
          echo
        fi
        ;;
    esac
    ;;
esac
EOF
chmod 0644 "$ISSUE" "$BIENVENIDA"
ok "Mensaje de bienvenida listo"

# ------------------------------------------------------------------ 4. comando escritorio
paso "4/4 Comando para pasar de modo servidor a escritorio"
cat > "$CMD_ESCRITORIO" <<'EOF'
#!/usr/bin/env bash
# Abre la interfaz gráfica desde el modo servidor, sin reiniciar. La IA sigue funcionando.
if systemctl is-active --quiet display-manager; then
  echo "La interfaz gráfica ya está activa."
  exit 0
fi
echo "Abriendo la interfaz gráfica... (la IA sigue funcionando)"
exec sudo systemctl start graphical.target
EOF
chmod 0755 "$CMD_ESCRITORIO"
ok "Comando 'escritorio' instalado"

# ------------------------------------------------------------------ resumen
echo -e "\n${VERDE}══════════════════════════════════════════════════════════════${NORMAL}"
echo -e "${VERDE}  ¡Menú de arranque listo!${NORMAL}"
echo -e "${VERDE}══════════════════════════════════════════════════════════════${NORMAL}"
echo "  Al encender el PC verás un menú. Presiona:"
echo "     1  → Modo servidor   (solo terminal, más RAM libre para la IA)"
echo "     2  → Modo escritorio (Ubuntu normal)"
echo "  Si no presionas nada, en $ESPERA segundos entra solo en la opción $OPCION_POR_DEFECTO."
echo
echo "  En el menú también siguen las opciones normales de Ubuntu, por si"
echo "  alguna vez las necesitas."
echo
echo "  Para deshacer todo:  sudo bash $0 --quitar"
echo
