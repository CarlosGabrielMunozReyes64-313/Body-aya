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
