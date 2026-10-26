#!/usr/bin/env bash
# =============================================================================
#  preparar-servidor-ia.sh
#  Convierte este PC en un servidor de IA al que se conecta una página en Vercel.
#
#  Qué hace:
#    1. Instala los paquetes necesarios
#    2. Crea un usuario del sistema exclusivo para el servidor
#    3. Prepara el disco de 1 TB para guardar las conversaciones
#    4. Configura Ollama y descarga un modelo
#    5. Instala el backend (login con contraseña, conversaciones, respuestas en vivo)
#    6. Programa un respaldo diario de las conversaciones en el SSD
#    7. Pone el PC en modo servidor (sin suspensión) y activa el firewall
#    8. Crea el túnel seguro con Tailscale Funnel (dirección pública fija)
#    9. Verifica que todo funcione
#
#  Uso:   sudo bash preparar-servidor-ia.sh
#  Se puede volver a ejecutar sin problema: lo que ya está hecho se respeta.
# =============================================================================
set -Eeuo pipefail

# ------------------------------------------------------------------ ajustes
APP_USUARIO="ia-servidor"
APP_DIR="/opt/ia-servidor"
CONF_DIR="/etc/ia-servidor"
CONF_FILE="$CONF_DIR/config.env"
PUNTO_MONTAJE="/mnt/datos"
DATOS_SSD="/var/lib/ia-servidor"
PUERTO=8000
MODELO_POR_DEFECTO="qwen3:4b"
CONTEXTO_POR_DEFECTO=8192
MODELO_DISCO_DATOS="ST1000DM014"      # el disco Seagate de 1 TB
NOMBRE_TAILSCALE="servidor-ia"         # la dirección será https://servidor-ia.<tu-red>.ts.net
SISTEMA_POR_DEFECTO="Eres un asistente útil y amable. Responde siempre en español, de forma clara."

# ------------------------------------------------------------------ utilidades
VERDE='\033[1;32m'; AMARILLO='\033[1;33m'; ROJO='\033[1;31m'; AZUL='\033[1;34m'; NORMAL='\033[0m'
paso()   { echo -e "\n${AZUL}━━━ [$1] $2 ━━━${NORMAL}"; }
info()   { echo -e "  $*"; }
ok()     { echo -e "  ${VERDE}✔${NORMAL} $*"; }
aviso()  { echo -e "  ${AMARILLO}!${NORMAL} $*"; }
fallo()  { echo -e "\n${ROJO}✘ $*${NORMAL}" >&2; exit 1; }
trap 'echo -e "\n${ROJO}✘ Algo falló en la línea $LINENO: $BASH_COMMAND${NORMAL}\n  Copia este mensaje para revisarlo. Puedes volver a ejecutar el script cuando se solucione." >&2' ERR

preguntar() {  # preguntar "texto" [s|n]  -> 0 = sí, 1 = no
  local resp def="${2:-s}" opciones
  [[ $def == s ]] && opciones="S/n" || opciones="s/N"
  while true; do
    read -rp "$(echo -e "  ${AMARILLO}?${NORMAL} $1 [$opciones]: ")" resp || true
    resp="${resp:-$def}"
    case "${resp,,}" in
      s|si|sí|y|yes) return 0 ;;
      n|no) return 1 ;;
    esac
  done
}

leer_config() {  # leer_config CLAVE VALOR_POR_DEFECTO
  local v=""
  if [[ -f $CONF_FILE ]]; then
    v=$(grep -E "^$1=" "$CONF_FILE" | tail -n1 | cut -d= -f2- || true)
  fi
  v="${v%\"}"; v="${v#\"}"
  echo "${v:-$2}"
}

hash_clave() {  # lee la contraseña por stdin y escribe el hash scrypt
  python3 -c 'import sys,os,hashlib
p=sys.stdin.buffer.read(); s=os.urandom(16); n,r,q=16384,8,1
h=hashlib.scrypt(p,salt=s,n=n,r=r,p=q,dklen=32)
print("scrypt:%d:%d:%d:%s:%s"%(n,r,q,s.hex(),h.hex()))'
}

pedir_clave() {  # pide la contraseña dos veces y escribe su hash
  local c1 c2
  while true; do
    read -rsp "  Contraseña para entrar a la página (mínimo 8 caracteres): " c1; echo >&2
    if (( ${#c1} < 8 )); then echo "  Muy corta, intenta de nuevo." >&2; continue; fi
    read -rsp "  Repítela: " c2; echo >&2
    [[ "$c1" == "$c2" ]] && break
    echo "  No coinciden, intenta de nuevo." >&2
  done
  printf '%s' "$c1" | hash_clave
}

esperar_url() {  # esperar_url URL SEGUNDOS
  local i
  for ((i = 0; i < $2; i++)); do
    curl -fsS --max-time 5 "$1" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# ------------------------------------------------------------------ comprobaciones
[[ $EUID -eq 0 ]] || fallo "Ejecuta el script con sudo:  sudo bash $0"
USUARIO_REAL="${SUDO_USER:-}"
if [[ $USUARIO_REAL == root ]]; then USUARIO_REAL=""; fi
source /etc/os-release
[[ ${ID:-} == ubuntu ]] || aviso "Este script está pensado para Ubuntu; detecté: ${PRETTY_NAME:-desconocido}"
curl -fsSL --max-time 15 https://ollama.com >/dev/null 2>&1 || fallo "No hay conexión a internet (no pude abrir ollama.com)."

echo -e "${VERDE}"
echo "  ┌──────────────────────────────────────────────────┐"
echo "  │      Preparando este PC como servidor de IA      │"
echo "  └──────────────────────────────────────────────────┘"
echo -e "${NORMAL}  Equipo: $(hostname)   Sistema: ${PRETTY_NAME:-?}   Usuario: ${USUARIO_REAL:-root}"
preguntar "¿Empezamos?" s || exit 0

# ============================================================== 1. paquetes
paso "1/9" "Paquetes del sistema"
APT_OPTS=(-y -q -o DPkg::Lock::Timeout=900)
info "Si Ubuntu está actualizando en segundo plano, esto espera a que termine..."
apt-get "${APT_OPTS[@]}" update >/dev/null
DEBIAN_FRONTEND=noninteractive apt-get "${APT_OPTS[@]}" install \
  curl ca-certificates python3 python3-venv sqlite3 ntfs-3g parted ufw >/dev/null
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
  || fallo "Se necesita Python 3.10 o superior."
ok "Paquetes instalados ($(python3 --version))"

# ============================================================== 2. usuario
paso "2/9" "Usuario del servicio"
if id "$APP_USUARIO" >/dev/null 2>&1; then
  ok "El usuario '$APP_USUARIO' ya existe"
else
  useradd --system --home-dir "$APP_DIR" --no-create-home --shell /usr/sbin/nologin "$APP_USUARIO"
  ok "Usuario '$APP_USUARIO' creado (sin contraseña ni acceso interactivo)"
fi
if [[ -n $USUARIO_REAL ]]; then
  usermod -aG "$APP_USUARIO" "$USUARIO_REAL"
  ok "'$USUARIO_REAL' agregado al grupo '$APP_USUARIO' (para que puedas ver los datos)"
fi
APP_GID=$(getent group "$APP_USUARIO" | cut -d: -f3)

# ============================================================== 3. disco
paso "3/9" "Disco para guardar las conversaciones"
USA_DISCO=0
DATOS_DIR="$DATOS_SSD"

desmontar_particiones() {
  local p
  for p in $(lsblk -nrpo NAME "$1" | tail -n +2); do
    if findmnt -rn -S "$p" >/dev/null 2>&1; then umount "$p"; fi
  done
}

escribir_fstab() {
  cp /etc/fstab "/etc/fstab.respaldo-$(date +%Y%m%d-%H%M%S)"
  sed -i "\|[[:space:]]${PUNTO_MONTAJE}[[:space:]]|d" /etc/fstab
  echo "$1" >> /etc/fstab
  mkdir -p "$PUNTO_MONTAJE"
  systemctl daemon-reload
}

configurar_disco() {
  if mountpoint -q "$PUNTO_MONTAJE"; then
    ok "Ya hay un disco montado en $PUNTO_MONTAJE ($(findmnt -no FSTYPE "$PUNTO_MONTAJE"))"
    USA_DISCO=1; return 0
  fi

  local disco="" d modelo disco_raiz
  for d in /sys/block/sd*; do
    if [[ ! -e $d ]]; then continue; fi
    modelo=$(tr -d '[:space:]' < "$d/device/model" 2>/dev/null || true)
    if [[ $modelo == *"$MODELO_DISCO_DATOS"* ]]; then disco="/dev/$(basename "$d")"; fi
  done
  disco_raiz="/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -n1)"

  if [[ -z $disco ]]; then
    aviso "No encontré el disco $MODELO_DISCO_DATOS. Discos disponibles:"
    lsblk -dpo NAME,MODEL,SIZE,TYPE | grep -E 'disk|NAME' | sed 's/^/    /'
    read -rp "  Escribe el disco a usar (ej: /dev/sda) o Enter para guardar en el SSD: " disco || true
    if [[ -z $disco ]]; then return 0; fi
  fi
  if [[ ! -b $disco ]]; then aviso "$disco no es un disco válido. Se usará el SSD."; return 0; fi
  if [[ $disco == "$disco_raiz" ]]; then aviso "$disco es el disco del sistema; no lo toco. Se usará el SSD."; return 0; fi

  info "Disco encontrado:"
  lsblk -po NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$disco" | sed 's/^/    /'
  echo
  echo "  ¿Qué hago con este disco?"
  echo "    1) Conservar sus archivos (lo dejo en formato Windows/NTFS)"
  echo "    2) Formatearlo en ext4 — recomendado para el servidor, pero BORRA TODO"
  echo "    3) No usarlo por ahora (las conversaciones se guardan en el SSD)"

  local op conf part uuid uid
  while true; do
    read -rp "  Elige 1, 2 o 3: " op || true
    case "$op" in
      1)
        part=$(lsblk -nrpo NAME,FSTYPE "$disco" | awk '$2=="ntfs"{print $1; exit}')
        if [[ -z $part ]]; then aviso "No encontré una partición NTFS en $disco. Elige otra opción."; continue; fi
        desmontar_particiones "$disco"
        uuid=$(blkid -s UUID -o value "$part")
        uid=$(id -u "${USUARIO_REAL:-root}")
        escribir_fstab "UUID=$uuid $PUNTO_MONTAJE ntfs3 uid=$uid,gid=$APP_GID,dmask=007,fmask=117,noatime,nofail,x-systemd.device-timeout=10s 0 0"
        if ! mount "$PUNTO_MONTAJE" 2>/dev/null; then
          aviso "Windows dejó el disco marcado como 'en uso' (hibernación o inicio rápido)."
          if preguntar "¿Lo reparo con ntfsfix? No borra tus archivos." s; then
            ntfsfix -d "$part" >/dev/null
            mount "$PUNTO_MONTAJE"
          else
            sed -i "\|[[:space:]]${PUNTO_MONTAJE}[[:space:]]|d" /etc/fstab
            systemctl daemon-reload
            aviso "Disco no montado. Se usará el SSD."; return 0
          fi
        fi
        ok "Disco montado en $PUNTO_MONTAJE con tus archivos intactos"
        USA_DISCO=1; return 0
        ;;
      2)
        echo -e "  ${ROJO}Esto BORRARÁ TODO el contenido de $disco ($(lsblk -dno SIZE "$disco")).${NORMAL}"
        read -rp "  Para confirmar escribe BORRAR (en mayúsculas): " conf || true
        if [[ $conf != BORRAR ]]; then info "Cancelado. Elige otra opción."; continue; fi
        desmontar_particiones "$disco"
        wipefs -aq "$disco"
        parted -s "$disco" mklabel gpt mkpart datos ext4 0% 100%
        partprobe "$disco" 2>/dev/null || true
        udevadm settle
        part=$(lsblk -nrpo NAME,TYPE "$disco" | awk '$2=="part"{print $1; exit}')
        [[ -n $part ]] || fallo "No se creó la partición en $disco."
        info "Formateando $part (puede tardar un minuto)..."
        mkfs.ext4 -q -F -L datos "$part"
        uuid=$(blkid -s UUID -o value "$part")
        escribir_fstab "UUID=$uuid $PUNTO_MONTAJE ext4 defaults,noatime,nofail,x-systemd.device-timeout=10s 0 2"
        mount "$PUNTO_MONTAJE"
        if [[ -n $USUARIO_REAL ]]; then
          install -d -o "$USUARIO_REAL" -g "$USUARIO_REAL" "$PUNTO_MONTAJE/$USUARIO_REAL"
          ok "Carpeta $PUNTO_MONTAJE/$USUARIO_REAL creada para tus propios archivos"
        fi
        ok "Disco formateado en ext4 y montado en $PUNTO_MONTAJE"
        USA_DISCO=1; return 0
        ;;
      3) info "Se usará el SSD."; return 0 ;;
    esac
  done
}

configurar_disco
if (( USA_DISCO )); then DATOS_DIR="$PUNTO_MONTAJE/ia-servidor"; fi

mkdir -p "$DATOS_DIR"
chown "$APP_USUARIO:$APP_USUARIO" "$DATOS_DIR" 2>/dev/null || true   # en NTFS los permisos los da el montaje
chmod 0770 "$DATOS_DIR" 2>/dev/null || true
if sudo -u "$APP_USUARIO" touch "$DATOS_DIR/.prueba-escritura" 2>/dev/null; then
  rm -f "$DATOS_DIR/.prueba-escritura"
  ok "Las conversaciones se guardarán en: $DATOS_DIR"
else
  fallo "El servicio no puede escribir en $DATOS_DIR."
fi

# ============================================================== 4. ollama
paso "4/9" "Ollama"
if command -v ollama >/dev/null 2>&1; then
  ok "Ollama ya está instalado ($(ollama --version 2>/dev/null | tail -n1))"
else
  info "Instalando Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
fi
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/servidor-ia.conf <<EOF
# Ajustes para usar este PC como servidor de IA (creado por preparar-servidor-ia.sh)
[Service]
# Ollama solo escucha dentro del PC: a internet solo se expone el backend con contraseña
Environment="OLLAMA_HOST=127.0.0.1:11434"
# Mantiene el modelo cargado 30 min para que las respuestas empiecen más rápido
Environment="OLLAMA_KEEP_ALIVE=30m"
# Una respuesta a la vez y un solo modelo en memoria: toda la RAM y CPU para esa respuesta
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
EOF
systemctl daemon-reload
systemctl enable ollama >/dev/null 2>&1
systemctl restart ollama
esperar_url "http://127.0.0.1:11434/api/version" 30 || fallo "Ollama no arrancó. Revisa: journalctl -u ollama -n 50"
ok "Ollama configurado y funcionando"

MODELO_ACTUAL=$(leer_config IA_MODELO "$MODELO_POR_DEFECTO")
read -rp "  Modelo principal para la página [$MODELO_ACTUAL]: " MODELO || true
MODELO="${MODELO:-$MODELO_ACTUAL}"
[[ $MODELO =~ ^[A-Za-z0-9._:/-]+$ ]] || fallo "Nombre de modelo no válido: $MODELO"
info "Descargando/verificando $MODELO (la primera vez puede tardar varios minutos)..."
ollama pull "$MODELO"
ok "Modelo $MODELO listo"

# ============================================================== 5. backend
paso "5/9" "Backend (puente entre la página y la IA)"
install -d -m 0755 "$APP_DIR"
cat > "$APP_DIR/app.py" <<'PYEOF'
"""
Servidor de IA casero: puente entre la página web (Vercel) y Ollama.

Rutas (todas bajo /api, las marcadas con * piden "Authorization: Bearer <token>"):
  GET    /api/salud                          Comprueba que el servidor y Ollama respondan
  POST   /api/login           {clave}        Devuelve {token, expira}
  POST   /api/logout                       * Cierra la sesión actual
  GET    /api/modelos                      * Modelos instalados en Ollama
  GET    /api/conversaciones               * Lista de conversaciones
  POST   /api/conversaciones  {titulo?}    * Crea una conversación
  GET    /api/conversaciones/{id}          * Conversación con todos sus mensajes
  PATCH  /api/conversaciones/{id} {titulo} * Cambia el título
  DELETE /api/conversaciones/{id}          * Borra la conversación
  POST   /api/conversaciones/{id}/mensajes * {contenido, modelo?, pensar?}
         Responde en streaming (NDJSON, un objeto JSON por línea):
           {"tipo":"pensamiento","texto":"..."}   razonamiento del modelo (si pensar=true)
           {"tipo":"texto","texto":"..."}         pedazo de la respuesta
           {"tipo":"fin","mensaje_id":N,"tokens_por_segundo":X}
           {"tipo":"error","mensaje":"..."}

Además, cada pregunta y respuesta se escribe en vivo en IA_ACTIVIDAD (por defecto
/run/ia-servidor/actividad.jsonl, que está en RAM y se borra al reiniciar) para que
el comando ia-monitor muestre en la pantalla del servidor lo que la IA está haciendo.
"""

import asyncio
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import time
import uuid
from contextlib import asynccontextmanager, contextmanager
from datetime import datetime, timedelta, timezone

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

# ---------------------------------------------------------------- configuración
OLLAMA_URL = os.environ.get("IA_OLLAMA_URL", "http://127.0.0.1:11434").rstrip("/")
DB_PATH = os.environ.get("IA_DB", "/var/lib/ia-servidor/conversaciones.db")
MODELO_DEFECTO = os.environ.get("IA_MODELO", "qwen3:4b")
CONTEXTO = int(os.environ.get("IA_CONTEXTO", "8192"))
SESION_DIAS = int(os.environ.get("IA_SESION_DIAS", "30"))
PASSWORD_HASH = os.environ.get("IA_PASSWORD_HASH", "")
ORIGENES = os.environ.get("IA_ORIGENES", "*.vercel.app")
SISTEMA = os.environ.get(
    "IA_SISTEMA",
    "Eres un asistente útil y amable. Responde siempre en español, de forma clara.",
)
TITULO_DEFECTO = "Nueva conversación"
ACTIVIDAD = os.environ.get("IA_ACTIVIDAD", "/run/ia-servidor/actividad.jsonl")
MAX_ACTIVIDAD = 2_000_000  # bytes; al pasar este tamaño se rota el archivo


def ahora() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def registrar(tipo: str, **datos) -> None:
    """Agrega un evento al registro de actividad en vivo. Nunca interrumpe al servidor si falla."""
    try:
        if os.path.exists(ACTIVIDAD) and os.path.getsize(ACTIVIDAD) > MAX_ACTIVIDAD:
            os.replace(ACTIVIDAD, ACTIVIDAD + ".1")
        linea = json.dumps({"hora": time.strftime("%H:%M:%S"), "tipo": tipo, **datos}, ensure_ascii=False)
        with open(ACTIVIDAD, "a", encoding="utf-8") as f:
            f.write(linea + "\n")
    except OSError:
        pass


def regex_origenes(texto: str) -> str:
    """Convierte 'mi-ia.vercel.app,*.vercel.app' en una expresión regular para CORS."""
    partes = []
    for item in (x.strip() for x in texto.split(",")):
        if not item:
            continue
        if item == "*":
            return ".*"
        if "://" not in item:
            item = "https://" + item
        partes.append(re.escape(item.rstrip("/")).replace(r"\*", "[a-z0-9-]+"))
    return "^(" + "|".join(partes) + ")$" if partes else "^$"


# ---------------------------------------------------------------- base de datos
@contextmanager
def conexion():
    con = sqlite3.connect(DB_PATH, timeout=15)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys = ON")
    try:
        yield con
        con.commit()
    except Exception:
        con.rollback()
        raise
    finally:
        con.close()


def crear_tablas() -> None:
    with conexion() as con:
        con.executescript(
            """
            CREATE TABLE IF NOT EXISTS conversaciones (
                id          TEXT PRIMARY KEY,
                titulo      TEXT NOT NULL,
                creada      TEXT NOT NULL,
                actualizada TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS mensajes (
                id                 INTEGER PRIMARY KEY AUTOINCREMENT,
                conversacion_id    TEXT NOT NULL REFERENCES conversaciones(id) ON DELETE CASCADE,
                rol                TEXT NOT NULL CHECK (rol IN ('user', 'assistant')),
                contenido          TEXT NOT NULL,
                pensamiento        TEXT,
                modelo             TEXT,
                tokens_por_segundo REAL,
                creado             TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_mensajes_conv ON mensajes(conversacion_id, id);
            CREATE TABLE IF NOT EXISTS sesiones (
                token_hash TEXT PRIMARY KEY,
                creada     TEXT NOT NULL,
                expira     TEXT NOT NULL
            );
            """
        )


# ---------------------------------------------------------------- seguridad
def verificar_clave(clave: str) -> bool:
    try:
        algoritmo, n, r, p, sal, esperado = PASSWORD_HASH.split(":")
        if algoritmo != "scrypt":
            return False
        calculado = hashlib.scrypt(
            clave.encode(), salt=bytes.fromhex(sal),
            n=int(n), r=int(r), p=int(p), dklen=len(esperado) // 2,
        )
        return hmac.compare_digest(calculado.hex(), esperado)
    except Exception:
        return False


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def sesion_actual(authorization: str | None = Header(default=None)) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "Falta iniciar sesión.")
    h = hash_token(authorization[7:].strip())
    with conexion() as con:
        fila = con.execute("SELECT expira FROM sesiones WHERE token_hash = ?", (h,)).fetchone()
    if not fila or fila["expira"] < ahora():
        raise HTTPException(401, "La sesión venció. Vuelve a iniciar sesión.")
    return h


_fallos: dict[str, list[float]] = {}
MAX_FALLOS, VENTANA_FALLOS = 5, 15 * 60


# ---------------------------------------------------------------- aplicación
@asynccontextmanager
async def ciclo_de_vida(_app: FastAPI):
    crear_tablas()
    if not PASSWORD_HASH:
        print("AVISO: IA_PASSWORD_HASH está vacío; nadie podrá iniciar sesión.", flush=True)
    yield


app = FastAPI(title="Servidor de IA", lifespan=ciclo_de_vida,
              docs_url=None, redoc_url=None, openapi_url=None)
app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=regex_origenes(ORIGENES),
    allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
    allow_credentials=False,
    max_age=3600,
)


class Login(BaseModel):
    clave: str = Field(min_length=1, max_length=200)


class NuevaConversacion(BaseModel):
    titulo: str | None = Field(default=None, max_length=200)


class CambioTitulo(BaseModel):
    titulo: str = Field(min_length=1, max_length=200)


class NuevoMensaje(BaseModel):
    contenido: str = Field(min_length=1, max_length=20000)
    modelo: str | None = Field(default=None, max_length=100)
    pensar: bool = False


@app.get("/")
async def raiz():
    return {"servicio": "servidor de IA", "ok": True}


@app.get("/api/salud")
async def salud():
    ollama_ok = False
    try:
        async with httpx.AsyncClient(timeout=3) as cliente:
            r = await cliente.get(f"{OLLAMA_URL}/api/version")
            ollama_ok = r.status_code == 200
    except httpx.HTTPError:
        pass
    return {"ok": True, "ollama": ollama_ok}


@app.post("/api/login")
async def login(datos: Login, request: Request):
    ip = request.client.host if request.client else "desconocida"
    t = time.monotonic()
    recientes = [x for x in _fallos.get(ip, []) if t - x < VENTANA_FALLOS]
    _fallos[ip] = recientes
    if len(recientes) >= MAX_FALLOS:
        raise HTTPException(429, "Demasiados intentos fallidos. Espera 15 minutos.")
    if not await asyncio.to_thread(verificar_clave, datos.clave):
        recientes.append(t)
        registrar("login", ok=False, ip=ip)
        await asyncio.sleep(1)
        raise HTTPException(401, "Contraseña incorrecta.")
    _fallos.pop(ip, None)
    registrar("login", ok=True, ip=ip)
    token = secrets.token_urlsafe(32)
    expira = (datetime.now(timezone.utc) + timedelta(days=SESION_DIAS)).isoformat(timespec="seconds")
    with conexion() as con:
        con.execute("DELETE FROM sesiones WHERE expira < ?", (ahora(),))
        con.execute("INSERT INTO sesiones VALUES (?, ?, ?)", (hash_token(token), ahora(), expira))
    return {"token": token, "expira": expira}


@app.post("/api/logout")
def logout(sesion: str = Depends(sesion_actual)):
    with conexion() as con:
        con.execute("DELETE FROM sesiones WHERE token_hash = ?", (sesion,))
    return {"ok": True}


@app.get("/api/modelos")
async def modelos(_: str = Depends(sesion_actual)):
    try:
        async with httpx.AsyncClient(timeout=10) as cliente:
            r = await cliente.get(f"{OLLAMA_URL}/api/tags")
            r.raise_for_status()
    except httpx.HTTPError:
        raise HTTPException(503, "No pude comunicarme con Ollama.")
    lista = [
        {"nombre": m["name"], "tamano_gb": round(m.get("size", 0) / 1e9, 1)}
        for m in r.json().get("models", [])
    ]
    return {"defecto": MODELO_DEFECTO, "modelos": lista}


def _conversacion_o_404(con: sqlite3.Connection, cid: str) -> sqlite3.Row:
    fila = con.execute("SELECT * FROM conversaciones WHERE id = ?", (cid,)).fetchone()
    if not fila:
        raise HTTPException(404, "Esa conversación no existe.")
    return fila


@app.get("/api/conversaciones")
def listar_conversaciones(_: str = Depends(sesion_actual)):
    with conexion() as con:
        filas = con.execute(
            "SELECT id, titulo, creada, actualizada FROM conversaciones ORDER BY actualizada DESC"
        ).fetchall()
    return [dict(f) for f in filas]


@app.post("/api/conversaciones", status_code=201)
def crear_conversacion(datos: NuevaConversacion | None = None, _: str = Depends(sesion_actual)):
    titulo = (datos.titulo if datos and datos.titulo else TITULO_DEFECTO).strip() or TITULO_DEFECTO
    conv = {"id": uuid.uuid4().hex, "titulo": titulo, "creada": ahora(), "actualizada": ahora()}
    with conexion() as con:
        con.execute("INSERT INTO conversaciones VALUES (:id, :titulo, :creada, :actualizada)", conv)
    return conv


@app.get("/api/conversaciones/{cid}")
def ver_conversacion(cid: str, _: str = Depends(sesion_actual)):
    with conexion() as con:
        conv = dict(_conversacion_o_404(con, cid))
        conv["mensajes"] = [
            dict(m) for m in con.execute(
                "SELECT id, rol, contenido, pensamiento, modelo, tokens_por_segundo, creado "
                "FROM mensajes WHERE conversacion_id = ? ORDER BY id", (cid,)
            )
        ]
    return conv


@app.patch("/api/conversaciones/{cid}")
def renombrar_conversacion(cid: str, datos: CambioTitulo, _: str = Depends(sesion_actual)):
    with conexion() as con:
        _conversacion_o_404(con, cid)
        con.execute("UPDATE conversaciones SET titulo = ? WHERE id = ?", (datos.titulo.strip(), cid))
    return {"ok": True}


@app.delete("/api/conversaciones/{cid}")
def borrar_conversacion(cid: str, _: str = Depends(sesion_actual)):
    with conexion() as con:
        _conversacion_o_404(con, cid)
        con.execute("DELETE FROM conversaciones WHERE id = ?", (cid,))
    return {"ok": True}


def _recortar_historial(mensajes: list[dict]) -> list[dict]:
    """Deja solo los mensajes más recientes que caben en la memoria del modelo (aprox.)."""
    limite = CONTEXTO * 3  # ~3 caracteres por token, con margen
    total, elegidos = 0, []
    for m in reversed(mensajes):
        total += len(m["content"])
        if elegidos and total > limite:
            break
        elegidos.append(m)
    return list(reversed(elegidos))


def _evento(tipo: str, **datos) -> str:
    return json.dumps({"tipo": tipo, **datos}, ensure_ascii=False) + "\n"


@app.post("/api/conversaciones/{cid}/mensajes")
def enviar_mensaje(cid: str, datos: NuevoMensaje, _: str = Depends(sesion_actual)):
    modelo = datos.modelo or MODELO_DEFECTO
    with conexion() as con:
        conv = _conversacion_o_404(con, cid)
        momento = ahora()
        con.execute(
            "INSERT INTO mensajes (conversacion_id, rol, contenido, creado) VALUES (?, 'user', ?, ?)",
            (cid, datos.contenido, momento),
        )
        if conv["titulo"] == TITULO_DEFECTO:
            titulo = " ".join(datos.contenido.split())[:60] or TITULO_DEFECTO
            con.execute("UPDATE conversaciones SET titulo = ? WHERE id = ?", (titulo, cid))
        con.execute("UPDATE conversaciones SET actualizada = ? WHERE id = ?", (momento, cid))
        anteriores = [
            {"role": f["rol"], "content": f["contenido"]}
            for f in con.execute(
                "SELECT rol, contenido FROM mensajes WHERE conversacion_id = ? ORDER BY id", (cid,)
            )
        ]
    historial = [{"role": "system", "content": SISTEMA}] + _recortar_historial(anteriores)
    with conexion() as con:
        titulo_conv = con.execute("SELECT titulo FROM conversaciones WHERE id = ?", (cid,)).fetchone()["titulo"]

    async def generar():
        texto: list[str] = []
        pensamiento: list[str] = []
        velocidad = None
        n_tokens = None
        error = None
        mensaje_id = None
        completado = False
        registrar("pregunta", conversacion=titulo_conv, modelo=modelo, texto=datos.contenido,
                  pensar=datos.pensar)
        cuerpo = {
            "model": modelo,
            "messages": historial,
            "stream": True,
            "think": datos.pensar,
            "options": {"num_ctx": CONTEXTO},
        }
        tiempo = httpx.Timeout(connect=10, read=600, write=30, pool=10)
        try:
            async with httpx.AsyncClient(timeout=tiempo) as cliente:
                for intento in range(2):
                    async with cliente.stream("POST", f"{OLLAMA_URL}/api/chat", json=cuerpo) as resp:
                        if resp.status_code != 200:
                            detalle = (await resp.aread()).decode(errors="replace")
                            # Modelos sin modo de pensamiento rechazan el parámetro "think"
                            if intento == 0 and "think" in detalle.lower():
                                cuerpo.pop("think", None)
                                continue
                            raise RuntimeError(f"Ollama respondió {resp.status_code}: {detalle[:300]}")
                        async for linea in resp.aiter_lines():
                            if not linea.strip():
                                continue
                            dato = json.loads(linea)
                            if "error" in dato:
                                raise RuntimeError(str(dato["error"]))
                            msg = dato.get("message") or {}
                            if msg.get("thinking"):
                                pensamiento.append(msg["thinking"])
                                registrar("pensamiento", texto=msg["thinking"])
                                yield _evento("pensamiento", texto=msg["thinking"])
                            if msg.get("content"):
                                texto.append(msg["content"])
                                registrar("texto", texto=msg["content"])
                                yield _evento("texto", texto=msg["content"])
                            if dato.get("done"):
                                n_tokens, dur = dato.get("eval_count"), dato.get("eval_duration")
                                if n_tokens and dur:
                                    velocidad = round(n_tokens / (dur / 1e9), 2)
                        break
                completado = True
        except (httpx.HTTPError, RuntimeError, json.JSONDecodeError) as e:
            error = str(e) or e.__class__.__name__
        finally:
            # Se guarda lo generado aunque la página se cierre a mitad de la respuesta
            if texto or pensamiento:
                with conexion() as con:
                    cur = con.execute(
                        "INSERT INTO mensajes (conversacion_id, rol, contenido, pensamiento, modelo, "
                        "tokens_por_segundo, creado) VALUES (?, 'assistant', ?, ?, ?, ?, ?)",
                        (cid, "".join(texto), "".join(pensamiento) or None, modelo, velocidad, ahora()),
                    )
                    mensaje_id = cur.lastrowid
                    con.execute("UPDATE conversaciones SET actualizada = ? WHERE id = ?", (ahora(), cid))
            if error:
                registrar("error", mensaje=error)
            elif completado:
                registrar("fin", tokens=n_tokens, tokens_por_segundo=velocidad)
            else:
                registrar("cancelado")
        if error:
            yield _evento("error", mensaje=f"No se pudo generar la respuesta: {error}")
        else:
            yield _evento("fin", mensaje_id=mensaje_id, tokens_por_segundo=velocidad)

    return StreamingResponse(
        generar(),
        media_type="application/x-ndjson",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
PYEOF
chmod 0644 "$APP_DIR/app.py"

if [[ ! -x $APP_DIR/venv/bin/python ]]; then
  python3 -m venv "$APP_DIR/venv"
fi
info "Instalando librerías de Python..."
"$APP_DIR/venv/bin/pip" install -q --upgrade pip
"$APP_DIR/venv/bin/pip" install -q --upgrade "fastapi>=0.110,<1" "uvicorn>=0.29" "httpx>=0.27,<1"
ok "Backend instalado en $APP_DIR"

install -d -m 0750 -o root -g "$APP_USUARIO" "$CONF_DIR"
HASH_ACTUAL=$(leer_config IA_PASSWORD_HASH "")
if [[ -n $HASH_ACTUAL ]] && ! preguntar "Ya hay una contraseña configurada. ¿Quieres cambiarla?" n; then
  IA_HASH="$HASH_ACTUAL"
else
  IA_HASH=$(pedir_clave)
fi
ORIGENES=$(leer_config IA_ORIGENES "*.vercel.app,http://localhost:3000")
SISTEMA=$(leer_config IA_SISTEMA "$SISTEMA_POR_DEFECTO")
CONTEXTO=$(leer_config IA_CONTEXTO "$CONTEXTO_POR_DEFECTO")

cat > "$CONF_FILE" <<EOF
# Configuración del servidor de IA (creada por preparar-servidor-ia.sh)
# Después de cambiar algo:  sudo systemctl restart ia-servidor
IA_PASSWORD_HASH="$IA_HASH"
IA_DB="$DATOS_DIR/conversaciones.db"
IA_OLLAMA_URL="http://127.0.0.1:11434"
IA_MODELO="$MODELO"
# Memoria de la conversación en tokens (más = recuerda más, pero usa más RAM)
IA_CONTEXTO="$CONTEXTO"
IA_SESION_DIAS="30"
# Páginas que pueden conectarse, separadas por comas. Cuando tengas la dirección
# exacta de tu página en Vercel, deja solo esa. Ej: https://mi-ia.vercel.app
IA_ORIGENES="$ORIGENES"
# Instrucciones que la IA recibe al inicio de cada conversación
IA_SISTEMA="$SISTEMA"
EOF
chown root:"$APP_USUARIO" "$CONF_FILE"
chmod 0640 "$CONF_FILE"
ok "Configuración guardada en $CONF_FILE"

MONTAJE_REQUERIDO=""
if (( USA_DISCO )); then MONTAJE_REQUERIDO="RequiresMountsFor=$PUNTO_MONTAJE"; fi
cat > /etc/systemd/system/ia-servidor.service <<EOF
[Unit]
Description=Servidor de IA (backend para la página web)
After=network-online.target ollama.service
Wants=network-online.target ollama.service
$MONTAJE_REQUERIDO

[Service]
Type=simple
User=$APP_USUARIO
Group=$APP_USUARIO
EnvironmentFile=$CONF_FILE
Environment=PYTHONDONTWRITEBYTECODE=1
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/uvicorn app:app --host 127.0.0.1 --port $PUERTO --proxy-headers --forwarded-allow-ips=127.0.0.1
Restart=always
RestartSec=5
# Protecciones: el servicio solo puede escribir en la carpeta de conversaciones
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$DATOS_DIR

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/systemd/system/ia-servidor.service.d
cat > /etc/systemd/system/ia-servidor.service.d/actividad.conf <<'EOF'
# Registro de actividad en vivo para ia-monitor (en RAM: se borra al reiniciar el PC)
[Service]
RuntimeDirectory=ia-servidor
RuntimeDirectoryMode=0750
RuntimeDirectoryPreserve=yes
Environment=IA_ACTIVIDAD=/run/ia-servidor/actividad.jsonl
EOF
systemctl daemon-reload
systemctl enable ia-servidor >/dev/null 2>&1
systemctl restart ia-servidor
esperar_url "http://127.0.0.1:$PUERTO/api/salud" 30 \
  || fallo "El backend no arrancó. Revisa: journalctl -u ia-servidor -n 50"
ok "Backend funcionando en el puerto $PUERTO (solo accesible dentro del PC)"

# ============================================================== 6. comando y respaldos
paso "6/9" "Comando de administración y respaldo diario"
cat > /usr/local/bin/ia-servidor <<'HELPEOF'
#!/usr/bin/env bash
# ia-servidor: comandos rápidos para administrar el servidor de IA
set -euo pipefail
CONF="/etc/ia-servidor/config.env"
leer() { local v; v=$(grep -E "^$1=" "$CONF" 2>/dev/null | tail -n1 | cut -d= -f2- || true); v="${v%\"}"; echo "${v#\"}"; }
root() { [[ $EUID -eq 0 ]] || { echo "Este comando necesita sudo:  sudo ia-servidor $1"; exit 1; }; }

case "${1:-ayuda}" in
  estado)
    for s in ollama ia-servidor tailscaled; do
      printf "  %-12s %s\n" "$s" "$(systemctl is-active "$s" 2>/dev/null || true)"
    done
    echo; echo -n "  Backend: "; curl -fsS --max-time 5 http://127.0.0.1:8000/api/salud || echo "no responde"
    echo; echo "  Modelo: $(leer IA_MODELO)    Datos: $(leer IA_DB)"
    if command -v tailscale >/dev/null 2>&1; then echo; tailscale funnel status 2>/dev/null || true; fi
    ;;
  url)
    tailscale funnel status
    ;;
  logs)
    journalctl -u ia-servidor -u ollama -f
    ;;
  reiniciar)
    root reiniciar; systemctl restart ollama ia-servidor; echo "Listo."
    ;;
  modelo)
    root modelo
    [[ -n ${2:-} ]] || { echo "Uso: sudo ia-servidor modelo <nombre>   (ej: llama3.1:8b)"; exit 1; }
    ollama pull "$2"
    sed -i "s|^IA_MODELO=.*|IA_MODELO=\"$2\"|" "$CONF"
    systemctl restart ia-servidor
    echo "Modelo principal cambiado a $2."
    ;;
  clave)
    root clave
    read -rsp "Nueva contraseña (mínimo 8 caracteres): " c1; echo
    (( ${#c1} >= 8 )) || { echo "Muy corta."; exit 1; }
    read -rsp "Repítela: " c2; echo
    [[ $c1 == "$c2" ]] || { echo "No coinciden."; exit 1; }
    h=$(printf '%s' "$c1" | python3 -c 'import sys,os,hashlib
p=sys.stdin.buffer.read(); s=os.urandom(16); n,r,q=16384,8,1
h=hashlib.scrypt(p,salt=s,n=n,r=r,p=q,dklen=32)
print("scrypt:%d:%d:%d:%s:%s"%(n,r,q,s.hex(),h.hex()))')
    sed -i "s|^IA_PASSWORD_HASH=.*|IA_PASSWORD_HASH=\"$h\"|" "$CONF"
    db=$(leer IA_DB)
    if [[ -f $db ]]; then sqlite3 "$db" "DELETE FROM sesiones;"; fi
    systemctl restart ia-servidor
    echo "Contraseña cambiada. Todas las sesiones abiertas se cerraron."
    ;;
  respaldo)
    root respaldo
    db=$(leer IA_DB); dest=/var/backups/ia-servidor
    [[ -f $db ]] || { echo "Todavía no hay conversaciones para respaldar."; exit 0; }
    mkdir -p "$dest"; chmod 700 "$dest"
    archivo="$dest/conversaciones-$(date +%Y-%m-%d).db"
    sqlite3 "$db" ".backup '$archivo'"
    find "$dest" -name 'conversaciones-*.db' -mtime +14 -delete
    echo "Respaldo guardado en $archivo"
    ;;
  *)
    cat <<'AYUDA'
Uso: ia-servidor <comando>
  estado              Muestra si todo está funcionando y la dirección pública
  url                 Muestra la dirección pública del servidor
  logs                Muestra la actividad en vivo (Ctrl+C para salir)
  sudo ... reiniciar  Reinicia Ollama y el backend
  sudo ... modelo X   Descarga el modelo X y lo pone como principal
  sudo ... clave      Cambia la contraseña de la página
  sudo ... respaldo   Hace un respaldo de las conversaciones ahora mismo
AYUDA
    ;;
esac
HELPEOF
chmod 0755 /usr/local/bin/ia-servidor

cat > /etc/systemd/system/ia-servidor-respaldo.service <<'EOF'
[Unit]
Description=Respaldo de las conversaciones del servidor de IA

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ia-servidor respaldo
EOF
cat > /etc/systemd/system/ia-servidor-respaldo.timer <<'EOF'
[Unit]
Description=Respaldo diario de las conversaciones del servidor de IA

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now ia-servidor-respaldo.timer >/dev/null 2>&1
ok "Comando 'ia-servidor' instalado (escribe: ia-servidor estado)"
ok "Respaldo diario a las 3:00 a.m. en el SSD (/var/backups/ia-servidor, se guardan 14 días)"

# ============================================================== 7. modo servidor
paso "7/9" "Modo servidor y firewall"
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1
if [[ -n $USUARIO_REAL ]]; then
  UID_REAL=$(id -u "$USUARIO_REAL")
  if [[ -S /run/user/$UID_REAL/bus ]]; then
    sudo -u "$USUARIO_REAL" env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_REAL/bus" \
      gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null || true
  fi
fi
ok "Suspensión desactivada: el PC no se dormirá (la pantalla sí puede apagarse)"

if preguntar "¿Activar el firewall (bloquea conexiones entrantes no autorizadas)?" s; then
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow in on tailscale0 >/dev/null
  ufw --force enable >/dev/null
  ok "Firewall activo"
fi

# ============================================================== 8. túnel
paso "8/9" "Túnel seguro con Tailscale Funnel"
URL_PUBLICA=""
if preguntar "¿Configurar ahora el túnel? (necesitas una cuenta gratis de Tailscale)" s; then
  if ! command -v tailscale >/dev/null 2>&1; then
    info "Instalando Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  systemctl enable --now tailscaled >/dev/null 2>&1
  if ! tailscale status >/dev/null 2>&1; then
    echo
    info "Ahora aparecerá un enlace. Ábrelo en cualquier navegador (puede ser tu celular),"
    info "crea tu cuenta o inicia sesión y autoriza este PC. El script continúa solo después."
    echo
    tailscale up --hostname="$NOMBRE_TAILSCALE"
  fi
  ok "PC conectado a Tailscale"
  echo
  info "Activando Funnel. Si aparece otro enlace, ábrelo para permitir Funnel en tu cuenta"
  info "y vuelve aquí; el script seguirá cuando lo autorices."
  echo
  FUNNEL_OK=0
  while true; do
    if tailscale funnel --bg "$PUERTO"; then FUNNEL_OK=1; break; fi
    aviso "No se pudo activar Funnel. Si apareció un enlace arriba, ábrelo y autoriza Funnel."
    preguntar "¿Reintentar?" s || break
  done
  if (( FUNNEL_OK )); then
    DNS=$(tailscale status --json | python3 -c 'import sys,json; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')
    URL_PUBLICA="https://$DNS"
    ok "Túnel activo: $URL_PUBLICA"
  else
    aviso "Funnel quedó sin activar. Vuelve a ejecutar el script cuando quieras intentarlo de nuevo."
  fi
else
  aviso "Túnel omitido. Vuelve a ejecutar el script cuando quieras configurarlo."
fi

# ============================================================== 9. verificación
paso "9/9" "Verificación final"
for s in ollama ia-servidor; do
  if systemctl is-active --quiet "$s"; then ok "$s: activo"; else aviso "$s: NO está activo"; fi
done
if [[ -n $URL_PUBLICA ]]; then
  info "Probando la dirección pública (la primera vez tarda mientras se genera el certificado)..."
  if esperar_url "$URL_PUBLICA/api/salud" 60; then
    ok "Responde desde internet: $URL_PUBLICA/api/salud"
  else
    aviso "Todavía no responde. Espera un par de minutos y abre $URL_PUBLICA/api/salud en el celular."
  fi
fi

echo -e "\n${VERDE}══════════════════════════════════════════════════════════════${NORMAL}"
echo -e "${VERDE}  ¡Servidor listo!${NORMAL}"
echo -e "${VERDE}══════════════════════════════════════════════════════════════${NORMAL}"
if [[ -n $URL_PUBLICA ]]; then
  echo -e "  Dirección del servidor (la necesitarás para la página):"
  echo -e "      ${AMARILLO}$URL_PUBLICA${NORMAL}"
  echo    "  Prueba desde el celular abriendo: $URL_PUBLICA/api/salud"
fi
echo    "  Conversaciones guardadas en:  $DATOS_DIR"
echo    "  Modelo principal:             $MODELO"
echo
echo    "  Comandos útiles:"
echo    "      ia-servidor estado        ver si todo funciona"
echo    "      ia-servidor logs          ver la actividad en vivo"
echo    "      sudo ia-servidor clave    cambiar la contraseña"
echo    "      sudo ia-servidor modelo X cambiar el modelo principal"
echo
echo    "  Recomendado: en la BIOS del PC activa la opción de encender automáticamente"
echo    "  al volver la luz (suele llamarse 'After Power Loss' o 'AC Power Recovery')."
if [[ -n $USUARIO_REAL ]]; then
  echo
  echo    "  Cierra sesión y vuelve a entrar para poder leer la carpeta de datos con tu usuario."
fi
echo
