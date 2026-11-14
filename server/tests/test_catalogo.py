import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.exceptions import InvalidSignature

from helpert_server import catalogo as cat
from conftest import RAIZ


ORIGINALES = {"print.clear-queue", "print.set-default", "disk.free-space", "net.no-internet", "net.wifi", "net.vpn",
              "net.network-drive", "files.find", "files.restore-trash", "audio.output", "audio.mic", "bluetooth.restart",
              "time.sync", "browser.cache", "app.close-hung", "system.slow", "usb.storage", "camera.check"}
SISTEMAS = {"linux": ".sh", "windows": ".ps1", "macos": ".sh"}


def test_carga_los_playbooks_reales():
    c = cat.cargar(RAIZ / "playbooks")
    assert ORIGINALES <= set(c)
    for pb in c.values():
        carpeta = RAIZ / "playbooks" / pb.id
        assert pb.sistemas and set(pb.sistemas) <= set(SISTEMAS), pb.id
        assert pb.riesgo in ("bajo", "medio", "alto") and 10 <= pb.timeout <= 3600, pb.id
        assert len(pb.nombre) <= 60 and 40 <= len(pb.descripcion) <= 450, pb.id
        for so, archivo in pb.sistemas.items():  # cada sistema con su script, y ningún script sin declarar
            assert archivo == f"{so}{SISTEMAS[so]}" and (carpeta / archivo).is_file(), (pb.id, so)
        sueltos = {f.name for f in carpeta.iterdir() if f.suffix in (".sh", ".ps1")} - set(pb.sistemas.values())
        assert not sueltos, (pb.id, sueltos)
        if "windows" in pb.sistemas:  # el agente lo pasa por -EncodedCommand: UTF-8 sin BOM y como mucho 10 000 caracteres
            datos = (carpeta / "windows.ps1").read_bytes()
            assert not datos.startswith(b"\xef\xbb\xbf") and len(datos.decode()) <= 10_000, pb.id
        # el modelo pregunta por el dato que falta con la pregunta del manifiesto
        assert all(r.get("pregunta") for r in pb.parametros.values() if r.get("requerido")), pb.id


def test_ids_y_nombres_sin_repetir():
    c = cat.cargar(RAIZ / "playbooks").values()
    assert len({pb.nombre.lower() for pb in c}) == len(c)


@pytest.mark.parametrize("so", list(SISTEMAS))
def test_catalogo_cabe_en_el_contexto(so):
    # las instrucciones llevan el catálogo entero del sistema: si pasan de CATALOGO_MAX, Ollama (CONTEXTO) las corta
    from helpert_server import ia
    assert len(ia.instrucciones(cat.cargar(RAIZ / "playbooks"), so)) <= ia.CATALOGO_MAX


def test_scripts_de_los_playbooks():
    # Solo sintaxis y un paso inventado, que debe salir con 2 sin hacer nada (los scripts no hacen nada fuera del case).
    import subprocess
    for pb in cat.cargar(RAIZ / "playbooks").values():
        for so in ("linux", "macos"):
            if so not in pb.sistemas:
                continue
            script = RAIZ / "playbooks" / pb.id / pb.sistemas[so]
            assert subprocess.run(["bash", "-n", script]).returncode == 0, (pb.id, so)
            r = subprocess.run(["bash", script, "paso-inventado"], capture_output=True, env={"PATH": "/usr/bin:/bin"})
            assert r.returncode == 2, (pb.id, so)


@pytest.mark.parametrize("valor", ["HP; rm -rf /", "$(reboot)", "a b", "x" * 101, "`id`"])
def test_rechaza_parametros_peligrosos(valor):
    pb = cat.cargar(RAIZ / "playbooks")["print.clear-queue"]
    with pytest.raises(cat.ErrorCatalogo):
        cat.validar_parametros(pb, {"impresora": valor})


def test_parametros_que_no_declara_el_manifiesto():
    pb = cat.cargar(RAIZ / "playbooks")["print.clear-queue"]
    with pytest.raises(cat.ErrorCatalogo):
        cat.validar_parametros(pb, {"comando": "x"})
    assert cat.validar_parametros(pb, {"impresora": "HP-Piso3"}) == {"impresora": "HP-Piso3"}
    assert cat.validar_parametros(pb, {}) == {}


def test_firma_y_alteracion(tmp_path):
    import shutil
    shutil.copytree(RAIZ / "pruebas" / "playbooks", tmp_path / "pb")
    priv, pub = cat.generar_claves(tmp_path / "claves")
    cat.firmar(tmp_path / "pb", priv)
    paquete = tmp_path / "pb" / "demo.archivo"
    clave = Ed25519PublicKey.from_public_bytes(bytes.fromhex(pub.read_text().strip()))
    firma = bytes.fromhex((paquete / cat.FIRMA).read_text().strip())
    clave.verify(firma, cat.mensaje_paquete(paquete))
    (paquete / "linux.sh").write_text((paquete / "linux.sh").read_text() + "\nreboot\n")
    with pytest.raises(InvalidSignature):
        clave.verify(firma, cat.mensaje_paquete(paquete))
