#!/usr/bin/env python3
"""Prueba de los scripts de Linux y macOS de los playbooks, para la CI (ubuntu-latest y macos-latest). No es un playbook.

    python3 playbooks/probar-unix.py [--root] [--aplicar]

1. Cada manifiesto que declara el script de este sistema (linux.sh o macos.sh) lo tiene, y pasa `bash -n`.
2. El paso «diagnosticar» corre como lo lanza el agente (agente/src/lib.rs, comando()): /bin/bash -c con el script, entorno
   vacío salvo PATH fijo, LANG, HP_PASO, HP_USUARIO y los parámetros requeridos con un valor de ejemplo del manifiesto.
   Debe salir con 0, 1, 3 o 10, escribir algo, en UTF-8, y sin errores de bash (orden no encontrada, variable sin valor…).
3. Con --aplicar (solo en máquinas desechables), si diagnosticar dice que hay algo que hacer, corren comprobar → aplicar →
   verificar, salvo los que dejarían a la máquina sin red o la reiniciarían (NO_APLICAR).
--root: cada script corre con sudo, como el agente (root). Sin él, como el usuario que prueba.
Nunca correr --aplicar en un equipo de verdad.
"""
import platform
import re
import subprocess
import sys
import time
import tomllib
from pathlib import Path

RAIZ = Path(__file__).resolve().parent
SO = {"Linux": "linux", "Darwin": "macos"}[platform.system()]
PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"  # el del agente
NO_APLICAR = re.compile(r"^(net\.(no-internet|wifi|vpn|network-drive|ip-renew|winsock-reset)|system\.restart|system\.update|app\.update|security\.firewall|time\.sync|domain\.|"
                        r"bluetooth\.|disk\.boot-space)")
ERRORES_BASH = re.compile(r"command not found|orden no encontrada|unbound variable|syntax error|bad substitution|"
                          r"invalid option|illegal option|unary operator expected|integer expression expected")


def ejemplo(m: dict, regla: dict) -> str:
    if regla.get("tipo") == "entero":
        return str(regla.get("min", 1))
    if regla.get("tipo") == "booleano":
        return "1"
    for t in (regla.get("pregunta", ""), m.get("descripcion", "")):
        if x := re.search(r"por ejemplo\s+([A-Za-z0-9._-]+)", t):
            return x.group(1)[: regla.get("max", 100)]
    return "prueba"


def correr(script: str, pb_id: str, paso: str, variables: dict, root: bool, limite: int) -> tuple[int, str, str]:
    entorno = [f"PATH={PATH}", "LANG=C.UTF-8", f"HP_PASO={paso}"] + [f"{k}={v}" for k, v in variables.items()]
    orden = (["sudo", "-n"] if root else []) + ["env", "-i", *entorno, "/bin/bash", "-c", script, f"helpert-{pb_id}", paso]
    try:
        r = subprocess.run(orden, capture_output=True, timeout=limite, cwd="/")
    except subprocess.TimeoutExpired:
        return 124, "", "se pasó del tiempo límite"
    return r.returncode, r.stdout.decode("utf-8", "replace"), r.stderr.decode("utf-8", "replace")


def main() -> int:
    root, aplicar = "--root" in sys.argv, "--aplicar" in sys.argv
    usuario = subprocess.run(["id", "-un"], capture_output=True, text=True).stdout.strip()
    fallos, probados = [], 0

    def falla(texto):
        fallos.append(texto)
        print(f"FALLA  {texto}", flush=True)

    for manifiesto in sorted(RAIZ.glob("*/manifest.toml")):
        m = tomllib.loads(manifiesto.read_text())
        pb_id, archivo = m["id"], m.get("sistemas", {}).get(SO)
        if not archivo:
            print(f"--     {pb_id}: sin script de {SO}")
            continue
        ruta = manifiesto.parent / archivo
        if not ruta.is_file():
            falla(f"{pb_id}: el manifiesto declara {archivo}, pero no existe")
            continue
        if subprocess.run(["/bin/bash", "-n", str(ruta)], capture_output=True).returncode:
            falla(f"{pb_id}: {archivo} tiene errores de sintaxis para /bin/bash")
            continue
        script = ruta.read_text()
        variables = {"HP_USUARIO": usuario}
        for nombre, regla in m.get("parametros", {}).items():
            if regla.get("requerido"):
                variables[f"HP_{nombre.upper()}"] = ejemplo(m, regla)
        limite = min(int(m.get("timeout", 120)) + 30, 900)
        inicio = time.monotonic()
        codigo, salida, error = correr(script, pb_id, "diagnosticar", variables, root, limite)
        probados += 1
        seg = int(time.monotonic() - inicio)
        if codigo not in (0, 1, 3, 10):
            falla(f"{pb_id}: diagnosticar salió con {codigo} en {seg} s. Salida: {salida.strip()} Error: {error.strip()}")
            continue
        if not salida.strip():
            falla(f"{pb_id}: diagnosticar no escribió nada (código {codigo}). Error: {error.strip()}")
            continue
        if ERRORES_BASH.search(error) or "�" in salida:
            falla(f"{pb_id}: diagnosticar con errores: {error.strip()} | {salida.strip()}")
            continue
        print(f"ok     {pb_id}: código {codigo} en {seg} s: {salida.strip().splitlines()[0]}", flush=True)
        if not aplicar or codigo != 0 or NO_APLICAR.search(pb_id):
            continue
        for paso in ("comprobar", "aplicar", "verificar"):
            codigo, salida, error = correr(script, pb_id, paso, variables, root, limite)
            if codigo not in (0, 1, 3) or ERRORES_BASH.search(error) or "�" in salida:
                falla(f"{pb_id}: {paso} salió con {codigo}. Salida: {salida.strip()} Error: {error.strip()}")
                break
            print(f"         {paso} → {codigo}: {(salida.strip().splitlines() or [''])[0]}", flush=True)
            if codigo != 0:
                break

    print()
    if fallos:
        print(f"{len(fallos)} falla(s).")
        return 1
    print(f"Todo bien: {probados} script(s) de {SO} probados.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
