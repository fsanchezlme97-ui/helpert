import shutil

from fastapi.testclient import TestClient

from helpert_server import catalogo as cat, db
from helpert_server.app import crear_app
from helpert_server.cli import revisar

from conftest import RAIZ


def estados(lista):
    return {texto.split(":")[0]: estado for estado, texto in lista}


def test_revisar_marca_lo_que_falta_y_lo_que_esta_bien(dsn, tmp_path, monkeypatch):
    monkeypatch.delenv("HELPERT_CLAVE_MAESTRA", raising=False)
    shutil.copytree(RAIZ / "pruebas" / "playbooks", tmp_path / "pb")
    priv, pub = cat.generar_claves(tmp_path / "claves")
    cfg = {"base_datos": dsn, "playbooks": str(tmp_path / "pb"), "clave_publica": str(pub),
           "ia": [{"proveedor": "gemini", "modelo": "g", "clave_env": "SIN_ESTA_VARIABLE"}]}
    e = estados(revisar(cfg))
    assert e["Base de datos"] == "bien"
    assert e["No hay ninguna cuenta admin"] == "falta"
    assert e["HELPERT_CLAVE_MAESTRA no está"] == "falta"
    assert e["Playbooks sin firma válida para esta clave pública"] == "falta"  # copiados sin firmar
    assert e["IA"] == "falta"

    cat.firmar(tmp_path / "pb", priv)
    monkeypatch.setenv("HELPERT_CLAVE_MAESTRA", "x" * 43 + "=")
    monkeypatch.setenv("SIN_ESTA_VARIABLE", "clave")
    db.usuario_consola(dsn, "admin@empresa.pe", "admin", "una clave larga", None, None)
    lista = revisar(cfg)
    e = estados(lista)
    assert e.get("Playbooks") == "bien", lista
    assert e["Cuentas de administración"] == "bien" and e["Playbooks"] == "bien" and e["IA"] == "bien"
    assert e["HELPERT_CLAVE_MAESTRA"] == "bien"
    assert "falta" not in {v for k, v in e.items() if not k.startswith("Inscripción")}


def test_revisar_sin_base(tmp_path):
    lista = revisar({"base_datos": "postgresql://nadie@/no_existe?host=/no/existe", "playbooks": str(tmp_path)})
    assert lista[0][0] == "falta" and len(lista) == 1


def test_salud(dsn):
    assert TestClient(crear_app({"base_datos": dsn, "playbooks": str(RAIZ / "pruebas" / "playbooks"), "ia": []})).get("/salud").json() == {"ok": True}
