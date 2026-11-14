"""Almacenamiento en PostgreSQL (local en desarrollo, Supabase en la nube).

Todo vive en el esquema `helpert`: en Supabase ese esquema no queda expuesto por la API pública (PostgREST),
así que solo este servidor lee y escribe. Los trabajos y confirmaciones nunca se borran: son la auditoría.
"""
import hashlib
import hmac
import secrets
from contextlib import contextmanager
from datetime import datetime, timezone

import psycopg
from psycopg.rows import dict_row

ESQUEMA = """
CREATE SCHEMA IF NOT EXISTS helpert;
SET search_path = helpert;
CREATE TABLE IF NOT EXISTS equipos (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, nombre text UNIQUE NOT NULL, token_sha text UNIQUE NOT NULL,
  creado timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS casos (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, equipo_id bigint NOT NULL REFERENCES equipos(id),
  usuario text, so text, estado text NOT NULL, tipo text, categoria text, subcategoria text, playbook text,
  parametros text, modelo text, confianza real, nota text, creado timestamptz NOT NULL DEFAULT now(),
  cerrado timestamptz, resuelto boolean, calificacion smallint, comentario text);
CREATE INDEX IF NOT EXISTS casos_creado ON casos (creado);
CREATE TABLE IF NOT EXISTS mensajes (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, caso_id bigint NOT NULL REFERENCES casos(id),
  rol text NOT NULL, texto text NOT NULL, ts timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS trabajos (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, caso_id bigint NOT NULL REFERENCES casos(id),
  playbook text NOT NULL, version text NOT NULL, paso text NOT NULL, parametros text NOT NULL, estado text NOT NULL,
  codigo integer, salida text, error text, creado timestamptz NOT NULL DEFAULT now(), terminado timestamptz);
CREATE TABLE IF NOT EXISTS confirmaciones (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, caso_id bigint NOT NULL REFERENCES casos(id),
  playbook text NOT NULL, parametros text NOT NULL, usuario text, ts timestamptz NOT NULL DEFAULT now());
-- Personas de la consola. Hoy entran con contraseña (clave). Con Supabase Auth, auth_id enlaza con auth.users
-- y clave queda vacía: el rol y los permisos siguen viviendo aquí.
CREATE TABLE IF NOT EXISTS usuarios_consola (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, email text UNIQUE NOT NULL, nombre text,
  rol text NOT NULL CHECK (rol IN ('analista', 'tecnico', 'gerencia')), clave text, auth_id uuid UNIQUE,
  creado timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS sesiones (
  token_sha text PRIMARY KEY, usuario_id bigint NOT NULL REFERENCES usuarios_consola(id) ON DELETE CASCADE,
  expira timestamptz NOT NULL);
-- Consola de administración (migraciones idempotentes sobre bases ya creadas).
-- La regla de roles vive una sola vez (más abajo, con todos): el esquema corre en cada arranque y una regla vieja
-- aquí rechazaría las cuentas con roles nuevos.
ALTER TABLE usuarios_consola ADD COLUMN IF NOT EXISTS activo boolean NOT NULL DEFAULT true;
ALTER TABLE usuarios_consola ADD COLUMN IF NOT EXISTS ultimo_acceso timestamptz;
ALTER TABLE equipos ADD COLUMN IF NOT EXISTS revocado timestamptz;
ALTER TABLE equipos ADD COLUMN IF NOT EXISTS visto timestamptz;
-- Quién hizo qué en la administración. Nunca se borra.
CREATE TABLE IF NOT EXISTS auditoria (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, ts timestamptz NOT NULL DEFAULT now(),
  persona text NOT NULL, accion text NOT NULL, detalle text);
-- Ajustes que se cambian desde la consola (ver ajustes.py); el TOML solo da los valores iniciales.
-- Uso de la IA por caso (tokens y costo con los precios configurados) y datos del equipo para la atención física.
ALTER TABLE casos ADD COLUMN IF NOT EXISTS tokens_entrada integer NOT NULL DEFAULT 0;
ALTER TABLE casos ADD COLUMN IF NOT EXISTS tokens_salida integer NOT NULL DEFAULT 0;
ALTER TABLE casos ADD COLUMN IF NOT EXISTS costo_usd numeric(12, 6) NOT NULL DEFAULT 0;
-- Llamadas a la guía en pantalla (también las fallidas): tope de costo por caso.
ALTER TABLE casos ADD COLUMN IF NOT EXISTS pantalla_intentos integer NOT NULL DEFAULT 0;
ALTER TABLE equipos ADD COLUMN IF NOT EXISTS area text;
ALTER TABLE equipos ADD COLUMN IF NOT EXISTS sede text;
ALTER TABLE equipos ADD COLUMN IF NOT EXISTS piso text;
ALTER TABLE equipos ADD COLUMN IF NOT EXISTS notas text;
ALTER TABLE equipos ADD COLUMN IF NOT EXISTS version text;
ALTER TABLE equipos ADD COLUMN IF NOT EXISTS so text;
CREATE TABLE IF NOT EXISTS ajustes (
  clave text PRIMARY KEY, valor jsonb NOT NULL, persona text, actualizado timestamptz NOT NULL DEFAULT now());
-- Capturas con permiso: la fila queda como registro del permiso (acepta) aunque los datos se borren al vencer.
CREATE TABLE IF NOT EXISTS capturas (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, caso_id bigint NOT NULL REFERENCES casos(id),
  ts timestamptz NOT NULL DEFAULT now(), acepta boolean NOT NULL, tipo text, datos bytea, tamano integer,
  descripcion text, modelo text, borrada timestamptz);
CREATE INDEX IF NOT EXISTS capturas_caso ON capturas (caso_id);
-- Atención física: una visita por caso, asignada a un técnico de la consola.
CREATE TABLE IF NOT EXISTS visitas (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, caso_id bigint UNIQUE NOT NULL REFERENCES casos(id),
  estado text NOT NULL CHECK (estado IN ('pendiente', 'asignada', 'atendida', 'cancelada')),
  prioridad text NOT NULL DEFAULT 'media' CHECK (prioridad IN ('baja', 'media', 'alta')),
  tecnico_id bigint REFERENCES usuarios_consola(id), eta timestamptz, creado timestamptz NOT NULL DEFAULT now(),
  asignada timestamptz, atendida timestamptz, notas text, insumos text, persona text);
-- Avisos para el usuario del equipo (visita asignada, visita atendida): viajan en la respuesta al latido y se
-- reenvían hasta que el agente confirma que la bandeja los mostró.
CREATE TABLE IF NOT EXISTS avisos (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, equipo_id bigint NOT NULL REFERENCES equipos(id),
  caso_id bigint REFERENCES casos(id), texto text NOT NULL, cierre boolean NOT NULL DEFAULT false,
  creado timestamptz NOT NULL DEFAULT now(), visto timestamptz);
CREATE INDEX IF NOT EXISTS avisos_pendientes ON avisos (equipo_id) WHERE visto IS NULL;
-- Versiones del agente publicadas (firmadas fuera del servidor) y huella del binario que corre cada equipo.
CREATE TABLE IF NOT EXISTS versiones_agente (
  sha256 text PRIMARY KEY, version text NOT NULL, so text NOT NULL, firma text NOT NULL, datos bytea NOT NULL,
  tamano integer NOT NULL, subida timestamptz NOT NULL DEFAULT now(), persona text);
ALTER TABLE equipos ADD COLUMN IF NOT EXISTS binario_sha text;
ALTER TABLE equipos ADD COLUMN IF NOT EXISTS piloto boolean NOT NULL DEFAULT false;
-- Multiempresa. Un independiente es una empresa de una sola persona. La primera empresa recibe los datos que
-- había antes (ver iniciar). Un equipo nuevo queda sin empresa hasta que alguien inicia sesión en él.
CREATE TABLE IF NOT EXISTS empresas (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, nombre text UNIQUE NOT NULL,
  tipo text NOT NULL DEFAULT 'empresa' CHECK (tipo IN ('empresa', 'independiente')),
  activa boolean NOT NULL DEFAULT true,
  dominios text[] NOT NULL DEFAULT '{}',  -- correos de estos dominios entran solos (sin que los den de alta)
  telefono text, whatsapp text, correo text, horario text,
  remoto text CHECK (remoto IN ('rustdesk', 'anydesk')),
  fondo_activo boolean NOT NULL DEFAULT false, alerta_usd numeric(12, 2) NOT NULL DEFAULT 5,
  tope_persona_usd numeric(12, 2),  -- gasto de IA por persona al mes; sin valor, sin tope
  sla_n2_min integer NOT NULL DEFAULT 240, sla_n3_min integer NOT NULL DEFAULT 1440,
  plan text, notas text, creado timestamptz NOT NULL DEFAULT now());
INSERT INTO empresas (nombre) SELECT 'Mi organización' WHERE NOT EXISTS (SELECT 1 FROM empresas);
CREATE TABLE IF NOT EXISTS sedes (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, empresa_id bigint NOT NULL REFERENCES empresas(id) ON DELETE CASCADE,
  nombre text NOT NULL, region text, direccion text, UNIQUE (empresa_id, nombre));
-- Personas que piden ayuda desde la bandeja (no entran a la consola).
CREATE TABLE IF NOT EXISTS personas (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, empresa_id bigint NOT NULL REFERENCES empresas(id),
  email text UNIQUE NOT NULL, nombre text, telefono text, area text, sede text, activo boolean NOT NULL DEFAULT true,
  creado timestamptz NOT NULL DEFAULT now(), ultimo_acceso timestamptz);
-- Sesión de la bandeja: la persona que usa ese usuario del sistema en ese equipo (lo dice el núcleo vía el agente).
CREATE TABLE IF NOT EXISTS sesiones_persona (
  equipo_id bigint NOT NULL REFERENCES equipos(id) ON DELETE CASCADE, usuario_so text NOT NULL,
  persona_id bigint NOT NULL REFERENCES personas(id) ON DELETE CASCADE, creado timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (equipo_id, usuario_so));
-- Códigos de acceso de un solo uso (por correo o generados en la consola). Solo se guarda su huella.
CREATE TABLE IF NOT EXISTS codigos (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, email text NOT NULL, codigo_sha text NOT NULL,
  expira timestamptz NOT NULL, intentos integer NOT NULL DEFAULT 0, usado timestamptz,
  creado timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS codigos_email ON codigos (email);
-- Fondo de IA por empresa: saldo = recargas − costo de sus casos.
CREATE TABLE IF NOT EXISTS recargas (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, empresa_id bigint NOT NULL REFERENCES empresas(id),
  monto_usd numeric(12, 2) NOT NULL, nota text, persona text, ts timestamptz NOT NULL DEFAULT now());
-- Ajustes propios de una empresa (privacidad): pisan a los de la plataforma.
CREATE TABLE IF NOT EXISTS ajustes_empresa (
  empresa_id bigint NOT NULL REFERENCES empresas(id) ON DELETE CASCADE, clave text NOT NULL, valor jsonb NOT NULL,
  persona text, actualizado timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (empresa_id, clave));
ALTER TABLE equipos ADD COLUMN IF NOT EXISTS empresa_id bigint REFERENCES empresas(id);
ALTER TABLE equipos ADD COLUMN IF NOT EXISTS remoto text;  -- «rustdesk:123456789», lo informa el agente
ALTER TABLE casos ADD COLUMN IF NOT EXISTS empresa_id bigint REFERENCES empresas(id);
ALTER TABLE casos ADD COLUMN IF NOT EXISTS persona_id bigint REFERENCES personas(id);
ALTER TABLE casos ADD COLUMN IF NOT EXISTS nivel smallint NOT NULL DEFAULT 1;
ALTER TABLE casos ADD COLUMN IF NOT EXISTS escalado timestamptz;
ALTER TABLE casos ADD COLUMN IF NOT EXISTS asignado_id bigint REFERENCES usuarios_consola(id);
CREATE INDEX IF NOT EXISTS casos_empresa ON casos (empresa_id, creado);
ALTER TABLE usuarios_consola ADD COLUMN IF NOT EXISTS empresa_id bigint REFERENCES empresas(id);
ALTER TABLE usuarios_consola DROP CONSTRAINT IF EXISTS usuarios_consola_rol_check;
ALTER TABLE usuarios_consola ADD CONSTRAINT usuarios_consola_rol_check
  CHECK (rol IN ('admin', 'admin_empresa', 'analista', 'tecnico', 'gerencia'));
-- admin = plataforma (sin empresa); admin_empresa = administra solo la suya
ALTER TABLE usuarios_consola DROP CONSTRAINT IF EXISTS usuarios_consola_empresa_check;
ALTER TABLE usuarios_consola ADD CONSTRAINT usuarios_consola_empresa_check
  CHECK ((rol = 'admin' AND empresa_id IS NULL) OR (rol = 'admin_empresa' AND empresa_id IS NOT NULL)
         OR rol NOT IN ('admin', 'admin_empresa'));
"""
# Una sola vez, al llegar la multiempresa: lo que existía pasa a la primera empresa. No se repite en cada arranque
# porque un equipo nuevo debe quedar sin empresa hasta que alguien inicie sesión en él.
MIGRAR_MULTIEMPRESA = """
UPDATE equipos SET empresa_id = (SELECT min(id) FROM empresas) WHERE empresa_id IS NULL;
UPDATE casos k SET empresa_id = q.empresa_id FROM equipos q WHERE q.id = k.equipo_id AND k.empresa_id IS NULL;
UPDATE casos k SET nivel = 2, escalado = coalesce((SELECT max(ts) FROM mensajes m WHERE m.caso_id = k.id), k.creado)
  WHERE estado = 'escalado';
INSERT INTO sedes (empresa_id, nombre) SELECT DISTINCT empresa_id, sede FROM equipos WHERE sede IS NOT NULL AND sede <> ''
  ON CONFLICT DO NOTHING;
"""
# Defensa adicional en Supabase: RLS activado y sin políticas, por si alguien expone el esquema por error.
TABLAS = ("equipos", "casos", "mensajes", "trabajos", "confirmaciones", "usuarios_consola", "sesiones", "auditoria", "ajustes",
          "capturas", "visitas", "avisos", "versiones_agente", "empresas", "sedes", "personas", "sesiones_persona", "codigos",
          "recargas", "ajustes_empresa")

SCRYPT = {"n": 2**14, "r": 8, "p": 1}
ROLES = ("admin", "admin_empresa", "analista", "tecnico", "gerencia")


def ahora() -> datetime:
    return datetime.now(timezone.utc)


def sha(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


@contextmanager
def conexion(dsn: str):
    # shortcut: una conexión por petición; con más de ~50 equipos, usar psycopg_pool o el pooler de Supabase.
    with psycopg.connect(dsn, row_factory=dict_row, options="-c search_path=helpert", connect_timeout=10) as c:
        yield c  # al salir: commit, o rollback si hubo excepción


def iniciar(dsn: str) -> None:
    with conexion(dsn) as c:
        nueva = c.execute("SELECT 1 FROM information_schema.tables WHERE table_schema = 'helpert' AND table_name = 'equipos'").fetchone()
        migrar = nueva and not c.execute("SELECT 1 FROM information_schema.tables WHERE table_schema = 'helpert' "
                                         "AND table_name = 'empresas'").fetchone()
        c.execute(ESQUEMA)
        if migrar:
            c.execute(MIGRAR_MULTIEMPRESA)
        for t in TABLAS:
            c.execute(f"ALTER TABLE helpert.{t} ENABLE ROW LEVEL SECURITY")


def _scrypt(clave: str, sal: bytes) -> bytes:
    return hashlib.scrypt(clave.encode(), salt=sal, dklen=32, **SCRYPT)


def usuario_consola(dsn: str, email: str, rol: str, clave: str, nombre: str | None = None, empresa_id: int | None = None) -> None:
    """Crea una persona de la consola o le cambia rol y contraseña. Solo se guarda el hash scrypt."""
    if rol not in ROLES:
        raise ValueError(f"Rol no válido: {rol}")
    if len(clave) < 12:
        raise ValueError("La contraseña debe tener al menos 12 caracteres")
    sal = secrets.token_bytes(16)
    guardado = f"scrypt${sal.hex()}${_scrypt(clave, sal).hex()}"
    with conexion(dsn) as c:
        c.execute("INSERT INTO usuarios_consola (email, nombre, rol, clave, empresa_id) VALUES (%s, %s, %s, %s, %s) "
                  "ON CONFLICT (email) DO UPDATE SET rol = excluded.rol, clave = excluded.clave, empresa_id = excluded.empresa_id, "
                  "nombre = coalesce(excluded.nombre, usuarios_consola.nombre)", (email.lower(), nombre, rol, guardado, empresa_id))
        c.execute("DELETE FROM sesiones WHERE usuario_id = (SELECT id FROM usuarios_consola WHERE email = %s)",
                  (email.lower(),))


def verificar_clave(dsn: str, email: str, clave: str) -> int | None:
    with conexion(dsn) as c:
        fila = c.execute("SELECT id, clave FROM usuarios_consola WHERE email = %s AND activo", (email.lower(),)).fetchone()
    guardado = fila["clave"] if fila and fila["clave"] else "scrypt$00$00"
    _, sal, h = guardado.split("$")
    calculado = _scrypt(clave, bytes.fromhex(sal))  # se calcula aunque no exista: mismo tiempo de respuesta
    return fila["id"] if fila and fila["clave"] and hmac.compare_digest(calculado, bytes.fromhex(h)) else None


def equipo_nuevo(dsn: str, nombre: str) -> str:
    """Registra un equipo y devuelve su token (solo se muestra una vez; se guarda su hash)."""
    token = secrets.token_urlsafe(32)
    with conexion(dsn) as c:
        c.execute("INSERT INTO equipos (nombre, token_sha) VALUES (%s, %s)", (nombre, sha(token)))
    return token


def rotar_token(dsn: str, equipo_id: int) -> str:
    """Nuevo token para un equipo (el anterior deja de servir) y lo reactiva si estaba revocado."""
    token = secrets.token_urlsafe(32)
    with conexion(dsn) as c:
        c.execute("UPDATE equipos SET token_sha = %s, revocado = NULL WHERE id = %s", (sha(token), equipo_id))
    return token


def auditar(c, persona: str, accion: str, detalle: str = "") -> None:
    c.execute("INSERT INTO auditoria (persona, accion, detalle) VALUES (%s, %s, %s)", (persona, accion, detalle))


def persona_nueva(dsn: str, empresa_id: int, email: str, nombre: str | None = None) -> int:
    with conexion(dsn) as c:
        return c.execute("INSERT INTO personas (empresa_id, email, nombre) VALUES (%s, %s, %s) RETURNING id",
                         (empresa_id, email.strip().lower(), nombre)).fetchone()["id"]


def abrir_sesion_persona(c, equipo_id: int, usuario_so: str, persona_id: int) -> None:
    """La persona queda como dueña de ese usuario del sistema en ese equipo; el equipo pasa a su empresa si no tenía."""
    c.execute("UPDATE equipos SET empresa_id = (SELECT empresa_id FROM personas WHERE id = %s) WHERE id = %s AND empresa_id IS NULL",
              (persona_id, equipo_id))
    c.execute("INSERT INTO sesiones_persona (equipo_id, usuario_so, persona_id) VALUES (%s, %s, %s) "
              "ON CONFLICT (equipo_id, usuario_so) DO UPDATE SET persona_id = excluded.persona_id, creado = now()",
              (equipo_id, usuario_so, persona_id))
    c.execute("UPDATE personas SET ultimo_acceso = now() WHERE id = %s", (persona_id,))


ALFABETO = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # sin 0/O ni 1/I: se dicta por teléfono


def norma_codigo(codigo: str) -> str:
    return "".join(ch for ch in str(codigo).upper() if ch.isalnum())


def codigo_nuevo(c, email: str, minutos: int = 10, largo: int = 6, digitos: bool = True) -> str:
    """Código de acceso de un solo uso para un correo. Se devuelve una vez; se guarda su huella."""
    codigo = ("".join(secrets.choice("0123456789") for _ in range(largo)) if digitos
              else "".join(secrets.choice(ALFABETO) for _ in range(largo)))
    c.execute("INSERT INTO codigos (email, codigo_sha, expira) VALUES (%s, %s, now() + make_interval(mins => %s))",
              (email.lower(), sha(f"{email.lower()}:{codigo}"), minutos))
    return codigo


def saldo(c, empresa_id: int) -> float:
    """Fondo de IA de la empresa: recargas menos el costo de sus casos (USD)."""
    return float(c.execute("SELECT (SELECT coalesce(sum(monto_usd), 0) FROM recargas WHERE empresa_id = %(e)s) - "
                           "(SELECT coalesce(sum(costo_usd), 0) FROM casos WHERE empresa_id = %(e)s) AS s",
                           {"e": empresa_id}).fetchone()["s"])
