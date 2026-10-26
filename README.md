# Body-aya

El "cuerpo" de **Aya**: todo lo que convierte un PC con Ubuntu en el servidor donde vive la IA.
La página para chatear con ella está en otro repositorio
([IA-PC](https://github.com/CarlosGabrielMunozReyes64-313/IA-PC)).

## Cómo funciona

```
Celular u otro PC ──► página en Vercel (solo entrega la interfaz)
        │
        └─────────────► túnel de Tailscale ──► PC servidor
                                                 ├─ backend (contraseña, conversaciones, respuestas en vivo)
                                                 ├─ Ollama + modelo qwen3:4b (la IA, en el procesador)
                                                 └─ disco de 1 TB (conversaciones)
```

- **Backend** (`/opt/ia-servidor/app.py`): Python con FastAPI. Pide contraseña, guarda las
  conversaciones en SQLite y entrega las respuestas palabra por palabra.
- **Ollama**: ejecuta el modelo. Solo escucha dentro del PC; a internet solo sale el backend.
- **Tailscale Funnel**: da una dirección pública fija y segura sin abrir puertos del router.
- **Panel en vivo** (`ia-monitor`): muestra el estado del PC y las preguntas y respuestas
  mientras se generan. Se abre solo al iniciar sesión.
- **Mantenimiento** (`ia-mantenimiento`): al encender y cada noche a las 4:30 a.m. actualiza el
  sistema y Ollama, borra archivos innecesarios y libera memoria.
- **Menú de arranque**: al encender, `1` = modo servidor (solo terminal) y `2` = modo escritorio.
- **Respaldo diario** de las conversaciones en el SSD (se guardan 14 días).

## Contenido del repositorio

| Carpeta | Qué hay |
|---|---|
| `instaladores/` | Los tres scripts que montan el servidor desde cero |
| `sistema/` | Copia de los archivos instalados en el PC, con la misma ruta que tienen allí (por ejemplo, `sistema/opt/ia-servidor/app.py` es `/opt/ia-servidor/app.py`) |
| `sistema/INFO.txt` | Versión de Ubuntu, de Ollama y modelos instalados cuando se tomó la copia |
| `subir-a-github.sh` | Actualiza este repositorio con lo que hay en el PC |

**No se incluye nada privado:** ni el hash de la contraseña (la configuración aparece como
`config.env.ejemplo`, sin ella), ni las conversaciones, ni los respaldos, ni las llaves de Tailscale.

## Montar el servidor en un PC nuevo

En Ubuntu, ejecuta los instaladores en este orden:

```bash
sudo bash instaladores/preparar-servidor-ia.sh            # Ollama, backend, disco, túnel
sudo bash instaladores/instalar-mantenimiento-y-monitor.sh # panel en vivo y mantenimiento
sudo bash instaladores/configurar-arranque.sh              # menú de modos al encender
```

Cada uno explica lo que hace y pregunta antes de tomar decisiones importantes, como formatear un disco.

## Comandos en el servidor

| Comando | Para qué |
|---|---|
| `ia-servidor estado` | Ver si todo funciona y la dirección pública |
| `ia-monitor` | Ver a Aya trabajando en vivo |
| `sudo ia-servidor clave` | Cambiar la contraseña de la página |
| `sudo ia-servidor modelo X` | Cambiar el modelo principal |
| `sudo ia-mantenimiento` | Actualizar y limpiar ahora |
| `escritorio` / `modo-servidor` | Cambiar de modo sin reiniciar |

## Actualizar este repositorio

Cuando cambies algo en el PC servidor, vuelve a ejecutar:

```bash
bash ~/Body-aya/subir-a-github.sh
```

Reúne de nuevo los archivos instalados y sube solo lo que cambió.
