#!/usr/bin/env bash
# =============================================================================
#  instalar-mantenimiento-y-monitor.sh
#  Agrega al servidor de IA:
#    - Mantenimiento automático al encender y cada noche (4:30 a.m.):
#      actualiza todo el sistema y Ollama, borra archivos innecesarios y libera RAM
#    - Panel en vivo (ia-monitor) que se abre solo al entrar al sistema, tanto en
#      modo servidor como en modo escritorio: estado del PC, de la IA y las
#      preguntas y respuestas mientras se generan
#    - Comando modo-servidor para pasar de escritorio a servidor sin reiniciar
#
#  Uso:  sudo bash instalar-mantenimiento-y-monitor.sh
#  Requiere haber ejecutado antes preparar-servidor-ia.sh
# =============================================================================
set -Eeuo pipefail

APP_DIR=/opt/ia-servidor
VERDE='\033[1;32m'; AMARILLO='\033[1;33m'; ROJO='\033[1;31m'; AZUL='\033[1;34m'; NORMAL='\033[0m'
paso()  { echo -e "\n${AZUL}━━━ $* ━━━${NORMAL}"; }
ok()    { echo -e "  ${VERDE}✔${NORMAL} $*"; }
aviso() { echo -e "  ${AMARILLO}!${NORMAL} $*"; }
fallo() { echo -e "\n${ROJO}✘ $*${NORMAL}" >&2; exit 1; }
trap 'echo -e "\n${ROJO}✘ Algo falló en la línea $LINENO: $BASH_COMMAND${NORMAL}" >&2' ERR

preguntar() {
  local resp def="${2:-s}" opciones
  [[ $def == s ]] && opciones="S/n" || opciones="s/N"
  while true; do
    read -rp "$(echo -e "  ${AMARILLO}?${NORMAL} $1 [$opciones]: ")" resp || true
    resp="${resp:-$def}"
    case "${resp,,}" in s|si|sí|y|yes) return 0 ;; n|no) return 1 ;; esac
  done
}

[[ $EUID -eq 0 ]] || fallo "Ejecuta el script con sudo:  sudo bash $0"
[[ -f $APP_DIR/app.py ]] || fallo "No encontré el servidor de IA. Ejecuta primero preparar-servidor-ia.sh"

# ============================================================== 1. backend
paso "1/5 Actualizando el backend para mostrar la actividad en vivo"
cp "$APP_DIR/app.py" "$APP_DIR/app.py.anterior"
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

mkdir -p /etc/systemd/system/ia-servidor.service.d
cat > /etc/systemd/system/ia-servidor.service.d/actividad.conf <<'EOF'
# Registro de actividad en vivo (en RAM: se borra al reiniciar el PC)
[Service]
RuntimeDirectory=ia-servidor
RuntimeDirectoryMode=0750
RuntimeDirectoryPreserve=yes
Environment=IA_ACTIVIDAD=/run/ia-servidor/actividad.jsonl
EOF
systemctl daemon-reload
systemctl restart ia-servidor
listo=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 3 http://127.0.0.1:8000/api/salud >/dev/null 2>&1; then listo=1; break; fi
  sleep 1
done
if (( ! listo )); then
  aviso "El backend nuevo no arrancó; vuelvo a la versión anterior."
  cp "$APP_DIR/app.py.anterior" "$APP_DIR/app.py"
  systemctl restart ia-servidor
  fallo "No se pudo actualizar el backend. Revisa: journalctl -u ia-servidor -n 50"
fi
ok "Backend actualizado y funcionando (tus conversaciones siguen intactas)"

# ============================================================== 2. panel
paso "2/5 Panel en vivo (ia-monitor)"
cat > /usr/local/bin/ia-monitor <<'MONEOF'
#!/usr/bin/env python3
"""ia-monitor: panel en vivo del servidor de IA.

Muestra el estado del PC y de la IA, y las preguntas y respuestas mientras se generan.
Teclas:  q salir   ↑ ↓ RePág AvPág desplazar   Fin volver a lo último
"""
import curses
import json
import locale
import os
import shutil
import sqlite3
import subprocess
import textwrap
import threading
import time
import urllib.request
from datetime import datetime, timezone

ACTIVIDAD = os.environ.get("IA_ACTIVIDAD", "/run/ia-servidor/actividad.jsonl")
ESTADO_MANT = "/var/lib/ia-mantenimiento/estado.json"
CONF = "/etc/ia-servidor/config.env"
MAX_LINEAS = 3000
CABECERA = 8  # filas fijas arriba

FASES = {
    "red": "esperando internet", "reparando": "revisando paquetes",
    "actualizando": "actualizando el sistema", "snap": "actualizando snaps",
    "ollama": "actualizando Ollama", "limpiando": "borrando archivos innecesarios",
    "memoria": "liberando memoria RAM", "terminado": "terminado",
}


def leer_config():
    datos = {}
    try:
        with open(CONF, encoding="utf-8") as f:
            for linea in f:
                if "=" in linea and not linea.lstrip().startswith("#"):
                    k, v = linea.strip().split("=", 1)
                    datos[k] = v.strip('"')
    except OSError:
        pass
    return datos


def pedir_json(url, tiempo=1.5):
    with urllib.request.urlopen(url, timeout=tiempo) as r:
        return json.load(r)


def humano_gb(b):
    return f"{b / 1024**3:.1f}"


class Estado(threading.Thread):
    """Recoge el estado del sistema cada 2 segundos sin frenar la pantalla."""

    def __init__(self):
        super().__init__(daemon=True)
        self.datos = {}
        self.conf = leer_config()
        self._cpu_prev = None
        self.url = ""
        try:
            salida = subprocess.run(["tailscale", "status", "--json"], capture_output=True,
                                    text=True, timeout=5).stdout
            dns = json.loads(salida)["Self"]["DNSName"].rstrip(".")
            if dns:
                self.url = "https://" + dns
        except Exception:
            pass

    def cpu(self):
        with open("/proc/stat") as f:
            v = [int(x) for x in f.readline().split()[1:]]
        inactivo, total = v[3] + v[4], sum(v)
        uso = None
        if self._cpu_prev:
            di, dt = inactivo - self._cpu_prev[0], total - self._cpu_prev[1]
            uso = 100 * (1 - di / dt) if dt else 0
        self._cpu_prev = (inactivo, total)
        return uso

    @staticmethod
    def temperatura():
        mejor = None
        base = "/sys/class/thermal"
        try:
            for z in sorted(os.listdir(base)):
                try:
                    tipo = open(f"{base}/{z}/type").read().strip()
                    t = int(open(f"{base}/{z}/temp").read()) / 1000
                except (OSError, ValueError):
                    continue
                if tipo == "x86_pkg_temp":
                    return t
                if mejor is None and 0 < t < 120:
                    mejor = t
        except OSError:
            pass
        return mejor

    @staticmethod
    def memoria():
        m = {}
        with open("/proc/meminfo") as f:
            for linea in f:
                k, v = linea.split(":")
                m[k] = int(v.split()[0]) * 1024
        return m["MemTotal"], m["MemTotal"] - m["MemAvailable"]

    def conversaciones(self):
        db = self.conf.get("IA_DB")
        if not db:
            return None
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=1)
            n = con.execute("SELECT COUNT(*) FROM conversaciones").fetchone()[0]
            hoy = datetime.now().astimezone().replace(hour=0, minute=0, second=0, microsecond=0)
            m = con.execute("SELECT COUNT(*) FROM mensajes WHERE rol='user' AND creado >= ?",
                            (hoy.astimezone(timezone.utc).isoformat(timespec="seconds"),)).fetchone()[0]
            con.close()
            return n, m
        except Exception:
            return None

    def run(self):
        while True:
            d = {}
            try:
                d["servicios"] = {}
                for s in ("ollama", "ia-servidor", "tailscaled"):
                    r = subprocess.run(["systemctl", "is-active", s], capture_output=True, text=True)
                    d["servicios"][s] = r.stdout.strip() == "active"
                d["cpu"] = self.cpu()
                d["nucleos"] = os.cpu_count()
                d["temp"] = self.temperatura()
                d["ram"] = self.memoria()
                d["disco"] = shutil.disk_usage("/")
                datos_dir = os.path.dirname(self.conf.get("IA_DB", "")) or "/"
                try:
                    d["disco_datos"] = shutil.disk_usage(datos_dir)
                except OSError:
                    d["disco_datos"] = None
                with open("/proc/uptime") as f:
                    d["encendido"] = float(f.read().split()[0])
                try:
                    ps = pedir_json("http://127.0.0.1:11434/api/ps").get("models", [])
                    d["modelos"] = ps
                except Exception:
                    d["modelos"] = None
                d["conv"] = self.conversaciones()
                try:
                    with open(ESTADO_MANT, encoding="utf-8") as f:
                        d["mant"] = json.load(f)
                except (OSError, ValueError):
                    d["mant"] = None
                d["reinicio"] = os.path.exists("/run/reboot-required")
            except Exception as e:  # nunca romper el panel por un dato
                d["error"] = str(e)
            self.datos = d
            time.sleep(2)


class Feed:
    """Lee el registro de actividad y lo convierte en líneas con color."""

    def __init__(self, colores):
        self.c = colores
        self.lineas = []  # (texto, atributo)
        self.modo = None
        self.f = None
        self.inodo = None
        self.resto = ""
        self.ultima_velocidad = None
        self.trabajando = False

    def agregar(self, texto, attr):
        self.lineas.append([texto, attr])
        if len(self.lineas) > MAX_LINEAS:
            del self.lineas[: len(self.lineas) - MAX_LINEAS]

    def continuar(self, trozo, attr, sangria="       "):
        partes = trozo.split("\n")
        if self.lineas:
            self.lineas[-1][0] += partes[0]
        for p in partes[1:]:
            self.agregar(sangria + p, attr)

    def evento(self, e):
        tipo, hora = e.get("tipo"), e.get("hora", "")
        c = self.c
        if tipo == "pregunta":
            self.agregar("", 0)
            extra = "  · pensando activado" if e.get("pensar") else ""
            self.agregar(f"── {hora}  {e.get('conversacion', '')[:50]}  ({e.get('modelo', '')}){extra}",
                         c["titulo"])
            lineas = (e.get("texto") or "").split("\n")
            self.agregar("  Tú: " + lineas[0], c["pregunta"])
            for l in lineas[1:]:
                self.agregar("       " + l, c["pregunta"])
            self.modo = None
            self.trabajando = True
        elif tipo == "pensamiento":
            if self.modo != "pensamiento":
                self.agregar("  Pensando: ", c["pensamiento"])
                self.modo = "pensamiento"
                trozo = e.get("texto", "").lstrip()
            else:
                trozo = e.get("texto", "")
            self.continuar(trozo, c["pensamiento"])
        elif tipo == "texto":
            if self.modo != "texto":
                self.agregar("  IA:  ", c["respuesta"])
                self.modo = "texto"
                trozo = e.get("texto", "").lstrip()
            else:
                trozo = e.get("texto", "")
            self.continuar(trozo, c["respuesta"])
        elif tipo == "fin":
            v = e.get("tokens_por_segundo")
            self.ultima_velocidad = v
            detalle = f"{e.get('tokens')} tokens a {v} tokens/s" if v else "listo"
            self.agregar(f"  [OK] {hora}  respuesta terminada · {detalle}", c["ok"])
            self.modo, self.trabajando = None, False
        elif tipo == "error":
            self.agregar(f"  [ERROR] {hora}  {e.get('mensaje', '')}", c["error"])
            self.modo, self.trabajando = None, False
        elif tipo == "cancelado":
            self.agregar(f"  [!] {hora}  la página se cerró antes de terminar (se guardó lo generado)",
                         c["aviso"])
            self.modo, self.trabajando = None, False
        elif tipo == "login":
            if e.get("ok"):
                self.agregar(f"  {hora}  alguien inició sesión en la página", c["info"])
            else:
                self.agregar(f"  [!] {hora}  intento de inicio de sesión con contraseña incorrecta",
                             c["aviso"])
        elif tipo == "sistema":
            self.agregar(f"  {hora}  {e.get('texto', '')}", c["info"])

    def leer(self):
        try:
            st = os.stat(ACTIVIDAD)
        except OSError:
            return
        if self.f is None or st.st_ino != self.inodo or st.st_size < self.f.tell():
            if self.f:
                self.f.close()
            self.f = open(ACTIVIDAD, encoding="utf-8", errors="replace")
            primera_vez = self.inodo is None
            self.inodo = st.st_ino
            self.resto = ""
            if primera_vez and st.st_size > 200_000:  # al abrir, mostrar solo lo más reciente
                self.f.seek(st.st_size - 200_000)
                self.f.readline()
        datos = self.f.read()
        if not datos:
            return
        datos = self.resto + datos
        lineas = datos.split("\n")
        self.resto = lineas.pop()
        for l in lineas:
            try:
                self.evento(json.loads(l))
            except ValueError:
                pass


def barra(fraccion, ancho=10):
    fraccion = max(0.0, min(1.0, fraccion))
    lleno = round(fraccion * ancho)
    return "█" * lleno + "░" * (ancho - lleno)


def duracion(seg):
    seg = int(seg)
    d, h, m = seg // 86400, seg % 86400 // 3600, seg % 3600 // 60
    if d:
        return f"{d} d {h} h"
    if h:
        return f"{h} h {m} min"
    return f"{m} min"


def escribir(pantalla, y, x, texto, attr=0):
    alto, ancho = pantalla.getmaxyx()
    if y < 0 or y >= alto or x >= ancho - 1:
        return x
    texto = texto[: max(0, ancho - 1 - x)]
    try:
        pantalla.addstr(y, x, texto, attr)
    except curses.error:
        pass
    return x + len(texto)


def dibujar_cabecera(p, est, feed, c):
    alto, ancho = p.getmaxyx()
    d = est.datos
    ahora = datetime.now().strftime("%H:%M:%S")
    titulo = f" SERVIDOR DE IA   {ahora}"
    if d.get("encendido"):
        titulo += f"   encendido hace {duracion(d['encendido'])}"
    escribir(p, 0, 0, titulo.ljust(ancho - 1), c["barra"])

    x = 1
    nombres = {"ollama": "Ollama", "ia-servidor": "Backend", "tailscaled": "Túnel"}
    for s, activo in d.get("servicios", {}).items():
        x = escribir(p, 1, x, nombres[s] + " ")
        x = escribir(p, 1, x, "[activo]" if activo else "[DETENIDO]", c["ok"] if activo else c["error"])
        x += 3
    if est.url:
        escribir(p, 1, x, est.url, c["info"])

    cpu = d.get("cpu")
    linea = f" CPU {barra((cpu or 0) / 100)} {cpu or 0:3.0f}%  ({d.get('nucleos', '?')} hilos)"
    if d.get("temp"):
        linea += f"  {d['temp']:.0f}°C"
    if d.get("ram"):
        total, usado = d["ram"]
        linea += f"     RAM {barra(usado / total)} {humano_gb(usado)} de {humano_gb(total)} GB"
    escribir(p, 2, 0, linea)

    modelos = d.get("modelos")
    if modelos is None:
        linea, attr = " IA: Ollama no responde", c["error"]
    elif modelos:
        m = modelos[0]
        linea = f" IA: modelo {m.get('name')} cargado en memoria ({humano_gb(m.get('size', 0))} GB)"
        attr = c["ok"]
    else:
        linea, attr = f" IA: en espera (el modelo {est.conf.get('IA_MODELO', '')} se carga con la primera pregunta)", 0
    if feed.trabajando:
        linea, attr = linea + "   >>> GENERANDO RESPUESTA <<<", c["titulo"]
    elif feed.ultima_velocidad:
        linea += f"   última velocidad: {feed.ultima_velocidad} tokens/s"
    escribir(p, 3, 0, linea, attr)

    partes = []
    if d.get("disco"):
        partes.append(f"SSD {humano_gb(d['disco'].used)}/{humano_gb(d['disco'].total)} GB")
    if d.get("disco_datos"):
        partes.append(f"Datos {humano_gb(d['disco_datos'].used)}/{humano_gb(d['disco_datos'].total)} GB")
    if d.get("conv"):
        partes.append(f"Conversaciones: {d['conv'][0]}   Preguntas hoy: {d['conv'][1]}")
    escribir(p, 4, 0, " " + "    ".join(partes))

    mant = d.get("mant")
    if not mant:
        linea, attr = " Mantenimiento: todavía no se ha ejecutado (corre al encender y a las 4:30 a.m.)", 0
    elif mant.get("estado") == "en_curso":
        linea = f" Mantenimiento EN CURSO: {FASES.get(mant.get('fase'), mant.get('fase', ''))}..."
        attr = c["aviso"]
    else:
        cuando = (mant.get("fin") or "")[:16].replace("T", " ")
        ok = mant.get("estado") == "ok"
        linea = (f" Mantenimiento: {cuando}  {'[OK]' if ok else '[CON ERRORES]'}  "
                 f"{mant.get('paquetes', 0)} paquetes actualizados, {mant.get('liberado_mb', 0)} MB liberados")
        attr = 0 if ok else c["aviso"]
    escribir(p, 5, 0, linea, attr)
    if d.get("reinicio"):
        escribir(p, 6, 0, " ! Hay actualizaciones que necesitan reiniciar (a las 4:30 a.m. se hace solo, si no estás en modo escritorio)",
                 c["aviso"])

    escribir(p, CABECERA - 1, 0, ("─── Actividad en vivo " + "─" * ancho)[: ancho - 1], c["titulo"])


def lineas_visibles(feed, ancho, alto_feed, desplazamiento):
    """Parte las líneas al ancho de la pantalla, empezando por el final."""
    salida = []
    necesarias = alto_feed + desplazamiento
    for texto, attr in reversed(feed.lineas):
        trozos = textwrap.wrap(texto, max(10, ancho - 2), replace_whitespace=False,
                               drop_whitespace=False, subsequent_indent="       ") or [""]
        for t in reversed(trozos):
            salida.append((t, attr))
        if len(salida) >= necesarias:
            break
    salida.reverse()
    desplazamiento = max(0, min(desplazamiento, len(salida) - alto_feed))
    fin = len(salida) - desplazamiento
    return salida[max(0, fin - alto_feed): fin], desplazamiento


def principal(p):
    curses.curs_set(0)
    p.nodelay(True)
    p.keypad(True)
    curses.start_color()
    try:
        curses.use_default_colors()
        fondo = -1
    except curses.error:
        fondo = curses.COLOR_BLACK
    pares = {
        "barra": (curses.COLOR_BLACK, curses.COLOR_CYAN), "titulo": (curses.COLOR_CYAN, fondo),
        "pregunta": (curses.COLOR_YELLOW, fondo), "respuesta": (curses.COLOR_GREEN, fondo),
        "pensamiento": (curses.COLOR_MAGENTA, fondo), "ok": (curses.COLOR_GREEN, fondo),
        "error": (curses.COLOR_RED, fondo), "aviso": (curses.COLOR_YELLOW, fondo),
        "info": (curses.COLOR_BLUE, fondo),
    }
    c = {}
    for i, (nombre, (fg, bg)) in enumerate(pares.items(), start=1):
        curses.init_pair(i, fg, bg)
        c[nombre] = curses.color_pair(i)
    c["titulo"] |= curses.A_BOLD
    c["barra"] |= curses.A_BOLD
    c["pregunta"] |= curses.A_BOLD
    c["info"] |= curses.A_BOLD

    est = Estado()
    est.start()
    feed = Feed(c)
    desplazamiento = 0
    fase_previa = None

    while True:
        feed.leer()
        mant = est.datos.get("mant") or {}
        fase = (mant.get("estado"), mant.get("fase"))
        if fase != fase_previa and fase_previa is not None and mant.get("estado") == "en_curso":
            feed.evento({"tipo": "sistema", "hora": datetime.now().strftime("%H:%M:%S"),
                         "texto": f"Mantenimiento: {FASES.get(mant.get('fase'), mant.get('fase'))}..."})
        elif fase != fase_previa and fase_previa and fase_previa[0] == "en_curso":
            feed.evento({"tipo": "sistema", "hora": datetime.now().strftime("%H:%M:%S"),
                         "texto": "Mantenimiento terminado."})
        fase_previa = fase

        alto, ancho = p.getmaxyx()
        alto_feed = max(1, alto - CABECERA - 1)
        p.erase()
        dibujar_cabecera(p, est, feed, c)
        visibles, desplazamiento = lineas_visibles(feed, ancho, alto_feed, desplazamiento)
        if not feed.lineas:
            escribir(p, CABECERA + 1, 2, "Esperando actividad... Las preguntas que hagas desde la página "
                                         "aparecerán aquí en vivo.")
        for i, (t, attr) in enumerate(visibles):
            escribir(p, CABECERA + i, 1, t, attr)
        pie = " q: salir a la terminal    ↑ ↓ RePág AvPág: desplazar    Fin: volver a lo último "
        if desplazamiento:
            pie += f"   (viendo historial, {desplazamiento} líneas arriba)"
        escribir(p, alto - 1, 0, pie.ljust(ancho - 1), c["barra"])
        p.refresh()

        tecla = p.getch()
        if tecla in (ord("q"), ord("Q"), 27):
            break
        elif tecla == curses.KEY_UP:
            desplazamiento += 1
        elif tecla == curses.KEY_DOWN:
            desplazamiento = max(0, desplazamiento - 1)
        elif tecla == curses.KEY_PPAGE:
            desplazamiento += alto_feed - 1
        elif tecla == curses.KEY_NPAGE:
            desplazamiento = max(0, desplazamiento - (alto_feed - 1))
        elif tecla in (curses.KEY_END, ord("f")):
            desplazamiento = 0
        time.sleep(0.08)


if __name__ == "__main__":
    locale.setlocale(locale.LC_ALL, "")
    os.environ.setdefault("ESCDELAY", "25")
    try:
        curses.wrapper(principal)
    except KeyboardInterrupt:
        pass
MONEOF
chmod 0755 /usr/local/bin/ia-monitor

cat > /etc/profile.d/ia-servidor-modo.sh <<'BIENEOF'
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
BIENEOF
chmod 0644 /etc/profile.d/ia-servidor-modo.sh
ok "Comando 'ia-monitor' instalado"
ok "Se abrirá solo al iniciar sesión en modo servidor (q para salir a la terminal)"

# ============================================================== 3. modo escritorio
paso "3/5 Panel y comandos en modo escritorio"
cat > /usr/local/bin/ia-monitor-ventana <<'EOF'
#!/usr/bin/env bash
# Abre el panel de la IA en una ventana de terminal (modo escritorio).
# Usa Alacritty si está instalado; si no, la terminal que haya disponible.
PANEL=/usr/local/bin/ia-monitor
TITULO="Monitor de la IA"
if command -v alacritty >/dev/null 2>&1; then
  exec alacritty --title "$TITULO" -e "$PANEL"
elif command -v ptyxis >/dev/null 2>&1; then
  exec ptyxis --new-window -- "$PANEL"
elif command -v gnome-terminal >/dev/null 2>&1; then
  exec gnome-terminal --title="$TITULO" -- "$PANEL"
elif command -v xterm >/dev/null 2>&1; then
  exec xterm -T "$TITULO" -e "$PANEL"
fi
echo "No encontré una terminal gráfica. Abre una y escribe: ia-monitor" >&2
exit 1
EOF
chmod 0755 /usr/local/bin/ia-monitor-ventana

# Ícono en el menú de aplicaciones (se puede anclar al dock)
cat > /usr/share/applications/ia-monitor.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Monitor de la IA
Comment=Ver el servidor de IA trabajando en vivo
Exec=/usr/local/bin/ia-monitor-ventana
Icon=utilities-system-monitor
Terminal=false
Categories=System;Monitor;
EOF

# Se abre solo al entrar en modo escritorio
cat > /etc/xdg/autostart/ia-monitor.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Monitor de la IA
Comment=Abre el panel del servidor de IA al entrar en modo escritorio
Exec=/usr/local/bin/ia-monitor-ventana
Icon=utilities-system-monitor
Terminal=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=3
EOF
chmod 0644 /usr/share/applications/ia-monitor.desktop /etc/xdg/autostart/ia-monitor.desktop

cat > /usr/local/bin/modo-servidor <<'EOF'
#!/usr/bin/env bash
# Pasa de modo escritorio a modo servidor sin reiniciar. La IA sigue funcionando.
if ! systemctl is-active --quiet display-manager; then
  echo "Ya estás en modo servidor."
  exit 0
fi
echo "Esto cerrará la interfaz gráfica y TODOS los programas abiertos (guarda tu trabajo)."
read -rp "¿Continuar? [s/N]: " r
case "${r,,}" in
  s|si|sí|y|yes) exec sudo systemctl isolate multi-user.target ;;
  *) echo "Cancelado." ;;
esac
EOF
chmod 0755 /usr/local/bin/modo-servidor
ok "En modo escritorio el panel se abre solo en una ventana (también está en el menú: 'Monitor de la IA')"
ok "Comando 'modo-servidor' instalado (pasa a modo servidor sin reiniciar)"

# ============================================================== 4. mantenimiento
paso "4/5 Mantenimiento automático"
cat > /usr/local/sbin/ia-mantenimiento <<'MANTEOF'
#!/usr/bin/env bash
# =============================================================================
#  ia-mantenimiento: actualiza el sistema, borra archivos innecesarios y libera RAM.
#  Se ejecuta solo al encender el PC (3 min después) y todas las noches a las 4:30 a.m.
#  Para ejecutarlo a mano:  sudo ia-mantenimiento
#  Registro completo:       /var/log/ia-mantenimiento.log
# =============================================================================
set -uo pipefail

MODO="${1:-manual}"            # arranque | nocturno | manual
REINICIO_AUTOMATICO="si"        # reiniciar solo si una actualización lo pide (solo de noche)
ACTUALIZAR_OLLAMA="si"          # instalar versiones nuevas de Ollama cuando salgan
DIAS_REGISTROS=30               # días de registros del sistema que se conservan

ESTADO_DIR=/var/lib/ia-mantenimiento
ESTADO="$ESTADO_DIR/estado.json"
LOG=/var/log/ia-mantenimiento.log
ACTIVIDAD=/run/ia-servidor/actividad.jsonl
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
APT=(apt-get -y -q -o DPkg::Lock::Timeout=1800
     -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

[[ $EUID -eq 0 ]] || { echo "Ejecuta con sudo:  sudo ia-mantenimiento"; exit 1; }
mkdir -p "$ESTADO_DIR"
exec 9>/run/ia-mantenimiento.lock
flock -n 9 || { echo "Ya hay un mantenimiento en curso."; exit 0; }

INICIO=$(date -Iseconds)
ERRORES=0
PAQUETES=0
LIBERADO_MB=0
NOTAS=""

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
correr() {  # ejecuta un comando guardando su salida en el registro
  "$@" >>"$LOG" 2>&1
  local rc=$?
  if (( rc != 0 )); then log "  ! falló ($rc): $*"; ERRORES=$((ERRORES + 1)); fi
  return $rc
}
estado() {  # estado en_curso|ok|error  fase
  ESTADO_TXT="$1" FASE="$2" INICIO="$INICIO" PAQUETES="$PAQUETES" LIBERADO="$LIBERADO_MB" \
  NOTAS="$NOTAS" MODO="$MODO" python3 - "$ESTADO" <<'PY'
import json, os, sys, datetime
d = {"estado": os.environ["ESTADO_TXT"], "fase": os.environ["FASE"], "modo": os.environ["MODO"],
     "inicio": os.environ["INICIO"], "paquetes": int(os.environ["PAQUETES"]),
     "liberado_mb": int(os.environ["LIBERADO"]), "notas": os.environ["NOTAS"].strip(),
     "reinicio_pendiente": os.path.exists("/run/reboot-required")}
if d["estado"] != "en_curso":
    d["fin"] = datetime.datetime.now().astimezone().isoformat(timespec="seconds")
tmp = sys.argv[1] + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f, ensure_ascii=False)
os.chmod(tmp, 0o644)
os.replace(tmp, sys.argv[1])
PY
}
usado_mb() { df -Pm / | awk 'NR==2 {print $3}'; }
hay_escritorio() {  # ¿hay alguien con sesión abierta en la interfaz gráfica?
  local sesion
  for sesion in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
    if [[ $(loginctl show-session "$sesion" -p Type --value 2>/dev/null) =~ ^(x11|wayland)$ ]] \
       && [[ $(loginctl show-session "$sesion" -p Class --value 2>/dev/null) == user ]]; then
      return 0
    fi
  done
  return 1
}
ram_libre_mb() { free -m | awk '/^Mem:/ {print $7}'; }

log "════════ Mantenimiento ($MODO) ════════"

# ------------------------------------------------------------------ 1. internet
estado en_curso red
HAY_RED=0
for _ in $(seq 1 24); do
  if curl -fsS --max-time 5 -o /dev/null http://archive.ubuntu.com/ubuntu/; then HAY_RED=1; break; fi
  sleep 5
done
if (( HAY_RED )); then log "Internet: disponible"; else log "Internet: NO disponible, se omiten las actualizaciones"; NOTAS+="sin internet; "; fi

if (( HAY_RED )); then
  # ---------------------------------------------------------------- 2. actualizar
  estado en_curso reparando
  log "Revisando que no haya instalaciones a medias (por ejemplo tras un corte de luz)..."
  correr dpkg --configure -a
  correr "${APT[@]}" -f install

  estado en_curso actualizando
  log "Actualizando la lista de paquetes..."
  correr "${APT[@]}" update
  PAQUETES=$(apt-get -s full-upgrade 2>/dev/null | grep -c '^Inst ' || true)
  log "Paquetes por actualizar: $PAQUETES"
  if (( PAQUETES > 0 )); then
    correr nice -n 10 "${APT[@]}" full-upgrade && log "Sistema actualizado"
  fi

  if command -v snap >/dev/null 2>&1; then
    estado en_curso snap
    log "Actualizando aplicaciones snap..."
    correr snap refresh
  fi

  # ---------------------------------------------------------------- 3. ollama
  if [[ $ACTUALIZAR_OLLAMA == si ]] && command -v ollama >/dev/null 2>&1; then
    ACTUAL=$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -n1)
    ULTIMA=$(curl -fsSL --max-time 15 https://api.github.com/repos/ollama/ollama/releases/latest 2>/dev/null \
             | python3 -c 'import sys,json; print(json.load(sys.stdin)["tag_name"].lstrip("v"))' 2>/dev/null)
    if [[ -n $ACTUAL && -n $ULTIMA && $ACTUAL != "$ULTIMA" ]] \
       && [[ $(printf '%s\n%s\n' "$ACTUAL" "$ULTIMA" | sort -V | tail -n1) == "$ULTIMA" ]]; then
      estado en_curso ollama
      log "Actualizando Ollama $ACTUAL → $ULTIMA..."
      if correr sh -c 'curl -fsSL https://ollama.com/install.sh | sh'; then
        systemctl daemon-reload
        systemctl restart ollama ia-servidor
        NOTAS+="Ollama actualizado a $ULTIMA; "
        log "Ollama actualizado"
      fi
    else
      log "Ollama ya está en la última versión (${ACTUAL:-?})"
    fi
  fi
fi

# ------------------------------------------------------------------ 4. limpiar
estado en_curso limpiando
log "Borrando archivos innecesarios..."
ANTES_MB=$(usado_mb)
correr "${APT[@]}" autoremove --purge
correr "${APT[@]}" autoclean
correr apt-get clean
correr journalctl --vacuum-time="${DIAS_REGISTROS}d" --vacuum-size=300M
if command -v snap >/dev/null 2>&1; then
  snap set system refresh.retain=2 >>"$LOG" 2>&1 || true
  snap list --all 2>/dev/null | awk '/disabled/ {print $1, $3}' | while read -r nombre revision; do
    correr snap remove "$nombre" --revision="$revision"
  done
fi
find /var/crash -type f -mtime +7 -delete 2>/dev/null || true
rm -rf /root/.cache/pip 2>/dev/null || true
for h in /home/*; do
  [[ -d $h/.cache/thumbnails ]] && find "$h/.cache/thumbnails" -type f -atime +30 -delete 2>/dev/null
done
systemd-tmpfiles --clean >>"$LOG" 2>&1 || true
LIBERADO_MB=$(( ANTES_MB - $(usado_mb) ))
(( LIBERADO_MB < 0 )) && LIBERADO_MB=0
log "Espacio liberado en el SSD: ${LIBERADO_MB} MB"

# ------------------------------------------------------------------ 5. memoria
estado en_curso memoria
RAM_ANTES=$(ram_libre_mb)
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
[[ -w /proc/sys/vm/compact_memory ]] && echo 1 > /proc/sys/vm/compact_memory 2>/dev/null
SWAP_USADA=$(free -m | awk '/^Swap:/ {print $3}')
if (( SWAP_USADA > 0 )) && (( $(ram_libre_mb) > SWAP_USADA + 1024 )); then
  log "Devolviendo ${SWAP_USADA} MB de swap a la RAM..."
  swapoff -a && swapon -a
fi
log "RAM disponible: ${RAM_ANTES} MB → $(ram_libre_mb) MB"

# ------------------------------------------------------------------ 6. reinicio
if [[ -f /run/reboot-required ]]; then
  if [[ $MODO == nocturno && $REINICIO_AUTOMATICO == si ]] && hay_escritorio; then
    log "Una actualización necesita reiniciar, pero el modo escritorio está en uso: no reinicio"
    log "para no cerrar tus programas. Reinicia cuando puedas o se intentará mañana a las 4:30 a.m."
    NOTAS+="pendiente reiniciar (modo escritorio en uso); "
  elif [[ $MODO == nocturno && $REINICIO_AUTOMATICO == si ]]; then
    # Si alguien está usando la IA, esperar hasta 30 min a que termine
    for _ in $(seq 1 30); do
      [[ -f $ACTIVIDAD ]] && (( $(date +%s) - $(stat -c %Y "$ACTIVIDAD") < 300 )) || break
      sleep 60
    done
    log "Una actualización necesita reiniciar: el PC se reiniciará en 2 minutos."
    NOTAS+="reinicio programado; "
    estado ok terminado
    shutdown -r +2 "Reinicio automático por actualizaciones del servidor de IA" >/dev/null 2>&1
    exit 0
  else
    log "Una actualización necesita reiniciar; se hará en el mantenimiento de las 4:30 a.m."
    NOTAS+="pendiente reiniciar; "
  fi
fi

if (( ERRORES > 0 )); then
  estado error terminado
  log "Terminado con $ERRORES problema(s). Revisa este registro."
else
  estado ok terminado
  log "Terminado correctamente."
fi
MANTEOF
chmod 0755 /usr/local/sbin/ia-mantenimiento

cat > /etc/systemd/system/ia-mantenimiento@.service <<'EOF'
[Unit]
Description=Mantenimiento automático del servidor de IA (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ia-mantenimiento %i
# Prioridad baja para no frenar a la IA mientras actualiza
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
TimeoutStartSec=3h
EOF

cat > /etc/systemd/system/ia-mantenimiento-arranque.timer <<'EOF'
[Unit]
Description=Mantenimiento del servidor de IA al encender

[Timer]
OnBootSec=3min
Unit=ia-mantenimiento@arranque.service

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/ia-mantenimiento-nocturno.timer <<'EOF'
[Unit]
Description=Mantenimiento nocturno del servidor de IA

[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=5min
Unit=ia-mantenimiento@nocturno.service

[Install]
WantedBy=timers.target
EOF

cat > /etc/logrotate.d/ia-mantenimiento <<'EOF'
/var/log/ia-mantenimiento.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
EOF

systemctl daemon-reload
systemctl enable ia-mantenimiento-arranque.timer ia-mantenimiento-nocturno.timer >/dev/null 2>&1
systemctl start ia-mantenimiento-nocturno.timer
ok "Mantenimiento programado: 3 minutos después de encender y todas las noches a las 4:30 a.m."
ok "Comando manual: sudo ia-mantenimiento    Registro: /var/log/ia-mantenimiento.log"

# ============================================================== 5. primera ejecución
paso "5/5 Primera ejecución"
if preguntar "¿Ejecutar el mantenimiento ahora? (instala las actualizaciones pendientes, puede tardar)" s; then
  /usr/local/sbin/ia-mantenimiento manual || aviso "El mantenimiento terminó con avisos; revisa el registro."
else
  aviso "Se ejecutará solo la próxima vez que enciendas el PC."
fi

echo -e "\n${VERDE}══════════════════════════════════════════════════════════════${NORMAL}"
echo -e "${VERDE}  ¡Listo!${NORMAL}"
echo -e "${VERDE}══════════════════════════════════════════════════════════════${NORMAL}"
echo "  Pruébalo ahora escribiendo:   ia-monitor"
echo "  y haz una pregunta a la IA desde la página o el celular para verla en vivo."
echo
echo "  El panel se abre solo al entrar al sistema, en modo servidor y en modo escritorio."
echo "  Para pasar de escritorio a servidor sin reiniciar:  modo-servidor"
if [[ -f /run/reboot-required ]]; then
  echo
  aviso "Alguna actualización pide reiniciar. Hazlo cuando puedas:  sudo reboot"
fi
echo
