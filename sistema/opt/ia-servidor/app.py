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
