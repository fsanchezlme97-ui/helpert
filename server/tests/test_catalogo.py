import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.exceptions import InvalidSignature

from helpert_server import catalogo as cat
from conftest import RAIZ


def test_carga_los_playbooks_reales():
    c = cat.cargar(RAIZ / "playbooks")
    assert set(c) == {"print.clear-queue", "print.set-default", "disk.free-space", "net.no-internet", "net.wifi", "net.vpn",
                      "net.network-drive", "files.find", "files.restore-trash", "audio.output", "audio.mic",
                      "bluetooth.restart", "time.sync", "browser.cache", "app.close-hung", "system.slow", "usb.storage",
                      "camera.check"}
    assert all("linux" in pb.sistemas for pb in c.values())
    for pb in c.values():  # el modelo pregunta por el dato que falta con la pregunta del manifiesto
        assert all(r.get("pregunta") for r in pb.parametros.values() if r.get("requerido")), pb.id


def test_scripts_de_los_playbooks():
    import subprocess
    for pb in cat.cargar(RAIZ / "playbooks").values():
        script = RAIZ / "playbooks" / pb.id / pb.sistemas["linux"]
        assert subprocess.run(["bash", "-n", script]).returncode == 0, pb.id
        r = subprocess.run(["bash", script, "paso-inventado"], capture_output=True, env={"PATH": "/usr/bin:/bin"})
        assert r.returncode == 2, pb.id  # un paso que no existe nunca hace nada


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
