"""Catálogo de playbooks: lee los manifiestos, valida parámetros y firma los paquetes.

Un paquete es una carpeta `<id>/` con `manifest.toml`, un script por sistema y `firma.ed25519`.
La firma cubre todos los archivos del paquete (menos la propia firma); el agente la verifica
igual (ver agente/src/paquete.rs) antes de ejecutar nada.
"""
import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

FIRMA = "firma.ed25519"
ID_VALIDO = re.compile(r"^[a-z0-9][a-z0-9.-]{0,63}$")
# Texto de parámetros: solo caracteres que no significan nada para un shell. El agente aplica la misma regla.
TEXTO_VALIDO = re.compile(r"^[A-Za-z0-9._-]*$")
PASOS = ("diagnosticar", "comprobar", "aplicar", "verificar", "deshacer")


class ErrorCatalogo(Exception):
    pass


@dataclass
class Playbook:
    id: str
    version: str
    nombre: str
    descripcion: str
    riesgo: str
    deshacer: bool
    sistemas: dict[str, str]
    parametros: dict[str, dict] = field(default_factory=dict)
    timeout: int = 120


def cargar(carpeta: Path) -> dict[str, Playbook]:
    catalogo = {}
    for m in sorted(Path(carpeta).glob("*/manifest.toml")):
        d = tomllib.loads(m.read_text())
        pb = Playbook(id=d["id"], version=d["version"], nombre=d["nombre"], descripcion=d["descripcion"],
                      riesgo=d["riesgo"], deshacer=bool(d.get("deshacer", False)), sistemas=d["sistemas"],
                      parametros=d.get("parametros", {}), timeout=int(d.get("timeout", 120)))
        if not ID_VALIDO.match(pb.id) or m.parent.name != pb.id:
            raise ErrorCatalogo(f"{m}: el id debe coincidir con la carpeta y usar a-z, 0-9, punto o guion")
        catalogo[pb.id] = pb
    return catalogo


def validar_parametros(pb: Playbook, params: dict) -> dict:
    """Devuelve los parámetros limpios o lanza ErrorCatalogo. Nada que no esté en el manifiesto pasa."""
    params = params or {}
    sobran = set(params) - set(pb.parametros)
    if sobran:
        raise ErrorCatalogo(f"parámetros no permitidos: {', '.join(sorted(sobran))}")
    limpio = {}
    for nombre, regla in pb.parametros.items():
        v = params.get(nombre)
        if v in (None, ""):
            if regla.get("requerido"):
                raise ErrorCatalogo(f"falta el parámetro {nombre}")
            continue
        tipo = regla.get("tipo", "texto")
        if tipo == "texto":
            v = str(v)
            if len(v) > int(regla.get("max", 100)) or not TEXTO_VALIDO.match(v):
                raise ErrorCatalogo(f"{nombre}: solo letras, números, punto, guion o guion bajo")
        elif tipo == "entero":
            if isinstance(v, bool) or not isinstance(v, int):
                raise ErrorCatalogo(f"{nombre}: debe ser un número entero")
            if not regla.get("min", v) <= v <= regla.get("max", v):
                raise ErrorCatalogo(f"{nombre}: fuera de rango")
        elif tipo == "booleano":
            if not isinstance(v, bool):
                raise ErrorCatalogo(f"{nombre}: debe ser sí o no")
        else:
            raise ErrorCatalogo(f"{nombre}: tipo desconocido {tipo}")
        limpio[nombre] = v
    return limpio


def mensaje_paquete(carpeta: Path) -> bytes:
    """Lo que se firma: por cada archivo, en orden de ruta, `ruta\\nlargo\\n` + contenido."""
    carpeta = Path(carpeta)
    partes = []
    archivos = {p.relative_to(carpeta).as_posix(): p for p in carpeta.rglob("*") if p.name != FIRMA and not p.is_dir()}
    for ruta in sorted(archivos):  # orden por texto de la ruta, igual que el BTreeMap del agente
        f = archivos[ruta]
        if f.is_symlink() or not f.is_file():
            raise ErrorCatalogo(f"{f}: solo se permiten archivos normales")
        datos = f.read_bytes()
        partes.append(f"{ruta}\n{len(datos)}\n".encode() + datos)
    return b"".join(partes)


def generar_claves(destino: Path) -> tuple[Path, Path]:
    destino = Path(destino)
    destino.mkdir(parents=True, exist_ok=True)
    clave = Ed25519PrivateKey.generate()
    priv = destino / "playbooks.key"
    pub = destino / "playbooks.pub"
    crudo = clave.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                serialization.NoEncryption())
    priv.touch(mode=0o600, exist_ok=False)
    priv.write_text(crudo.hex() + "\n")
    pub.write_text(clave.public_key().public_bytes(serialization.Encoding.Raw,
                                                    serialization.PublicFormat.Raw).hex() + "\n")
    return priv, pub


def firma_valida(paquete: Path, clave_publica: Path) -> bool:
    """¿La firma del paquete es de la clave privada que va con esta pública? (lo mismo que comprueba el agente)"""
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    try:
        pub = Ed25519PublicKey.from_public_bytes(bytes.fromhex(Path(clave_publica).read_text().strip()))
        pub.verify(bytes.fromhex((Path(paquete) / FIRMA).read_text().strip()), mensaje_paquete(paquete))
        return True
    except (InvalidSignature, ValueError, OSError, ErrorCatalogo):
        return False


def firmar(carpeta: Path, clave_privada: Path) -> None:
    clave = Ed25519PrivateKey.from_private_bytes(bytes.fromhex(Path(clave_privada).read_text().strip()))
    for m in sorted(Path(carpeta).glob("*/manifest.toml")):
        paquete = m.parent
        (paquete / FIRMA).write_text(clave.sign(mensaje_paquete(paquete)).hex() + "\n")


def mensaje_actualizacion(version: str, so: str, sha256: str) -> bytes:
    """Lo que se firma para publicar un binario del agente: el mismo formato de paquete, con un único archivo
    «actualizacion» que nombra versión, sistema y huella. No puede confundirse con un playbook (no tiene manifest.toml)."""
    meta = f"helpert-agente\n{version}\n{so}\n{sha256}\n".encode()
    return f"actualizacion\n{len(meta)}\n".encode() + meta


def firmar_actualizacion(binario: Path, version: str, so: str, clave_privada: Path) -> tuple[str, str]:
    import hashlib
    clave = Ed25519PrivateKey.from_private_bytes(bytes.fromhex(Path(clave_privada).read_text().strip()))
    sha = hashlib.sha256(Path(binario).read_bytes()).hexdigest()
    return sha, clave.sign(mensaje_actualizacion(version, so, sha)).hex()


def verificar_actualizacion(clave_publica: Path, version: str, so: str, sha256: str, firma_hex: str) -> bool:
    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
    try:
        pub = Ed25519PublicKey.from_public_bytes(bytes.fromhex(Path(clave_publica).read_text().strip()))
        pub.verify(bytes.fromhex(firma_hex), mensaje_actualizacion(version, so, sha256))
        return True
    except (InvalidSignature, ValueError):
        return False
