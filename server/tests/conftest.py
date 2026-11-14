import json
import os
from pathlib import Path

import psycopg

import pytest
from fastapi.testclient import TestClient

from helpert_server import db, ia
from helpert_server.app import crear_app

RAIZ = Path(__file__).resolve().parents[2]
# Base de pruebas en el PostgreSQL de desarrollo (ver dev.sh). Cada prueba borra y recrea el esquema helpert.
DSN = os.environ.get("HELPERT_TEST_DSN", f"postgresql://helpert@/helpert_test?host={RAIZ}/.dev/pgsock")


@pytest.fixture
def dsn():
    # Cada prueba borra el esquema: solo se permite contra una base llamada helpert_test.
    assert psycopg.conninfo.conninfo_to_dict(DSN).get("dbname") == "helpert_test", "HELPERT_TEST_DSN debe ser helpert_test"
    with psycopg.connect(DSN.replace("/helpert_test?", "/postgres?"), autocommit=True) as c:
        if not c.execute("SELECT 1 FROM pg_database WHERE datname = 'helpert_test'").fetchone():
            c.execute("CREATE DATABASE helpert_test")
    with psycopg.connect(DSN, autocommit=True) as c:
        c.execute("DROP SCHEMA IF EXISTS helpert CASCADE")
    return DSN


def contrato(**k):
    base = {"tipo": "Incidente", "categoria": "Archivos y carpetas", "subcategoria": "prueba", "confianza": 0.9,
            "respuesta": "Voy a revisar.", "pregunta": None, "playbook": None, "escalar": False}
    return json.dumps({**base, **k})


@pytest.fixture
def falso(monkeypatch):
    """Proveedores falsos: cada uno devuelve, en orden, los textos (o lanza las excepciones) de su lista."""
    colas = {"a": [], "b": []}

    def hacer(nombre):
        def llamar(cfg, mensajes):
            r = colas[nombre].pop(0)
            if isinstance(r, Exception):
                raise r
            return r
        return llamar

    monkeypatch.setitem(ia.PROVEEDORES, "falso-a", hacer("a"))
    monkeypatch.setitem(ia.PROVEEDORES, "falso-b", hacer("b"))
    return colas


def sesion(dsn, equipo, usuario_so, email, empresa="Mi organización"):
    """Persona con sesión abierta en la bandeja de un equipo (se crea la empresa si no existe)."""
    with db.conexion(dsn) as c:
        emp = c.execute("INSERT INTO empresas (nombre) VALUES (%s) ON CONFLICT (nombre) DO UPDATE SET nombre = excluded.nombre "
                        "RETURNING id", (empresa,)).fetchone()["id"]
        per = c.execute("INSERT INTO personas (empresa_id, email) VALUES (%s, %s) ON CONFLICT (email) DO UPDATE "
                        "SET email = excluded.email RETURNING id", (emp, email)).fetchone()["id"]
        eid = c.execute("SELECT id FROM equipos WHERE nombre = %s", (equipo,)).fetchone()["id"]
        db.abrir_sesion_persona(c, eid, usuario_so, per)
    return emp, per


@pytest.fixture
def servidor(dsn):
    def crear(playbooks=RAIZ / "pruebas" / "playbooks", ia_cfg=None):
        cfg = {"base_datos": dsn, "playbooks": str(playbooks),
               "ia": ia_cfg if ia_cfg is not None else [{"proveedor": "falso-a", "modelo": "a"},
                                                         {"proveedor": "falso-b", "modelo": "b"}]}
        cliente = TestClient(crear_app(cfg))
        token = db.equipo_nuevo(cfg["base_datos"], "pc-1")
        cliente.headers["Authorization"] = f"Bearer {token}"
        cliente.ruta_db = cfg["base_datos"]
        sesion(cfg["base_datos"], "pc-1", "ana", "ana@empresa.pe")  # «ana» ya inició sesión en la bandeja de pc-1
        return cliente
    return crear
