//! Firma en Python (la herramienta real del servidor), verificación en Rust, y ejecución del playbook de prueba.
use agente::*;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::process::Command;

const SO: &str = std::env::consts::OS;

fn copiar(de: &Path, a: &Path) {
    std::fs::create_dir_all(a).unwrap();
    for e in std::fs::read_dir(de).unwrap().flatten() {
        if e.file_type().unwrap().is_dir() {
            copiar(&e.path(), &a.join(e.file_name()));
        } else {
            std::fs::copy(e.path(), a.join(e.file_name())).unwrap();
        }
    }
}

fn raiz() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().to_path_buf()
}

/// Copia los playbooks de prueba a una carpeta temporal y los firma con `helpert-server`.
fn firmados(nombre: &str) -> (PathBuf, ed25519_dalek::VerifyingKey) {
    let dir = std::env::temp_dir().join(format!("helpert-test-{nombre}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    copiar(&raiz().join("pruebas/playbooks"), &dir.join("pb"));
    let srv = |args: &[&str]| {
        let ok = Command::new("uv").args(["run", "-q", "--project"]).arg(raiz().join("server"))
            .arg("helpert-server").args(args).status().unwrap().success();
        assert!(ok, "helpert-server {args:?}");
    };
    let claves = dir.join("claves");
    srv(&["claves", claves.to_str().unwrap()]);
    srv(&["firmar", dir.join("pb").to_str().unwrap(), "--clave", claves.join("playbooks.key").to_str().unwrap()]);
    let clave = leer_clave(&claves.join("playbooks.pub")).unwrap();
    (dir.join("pb"), clave)
}

#[test]
fn firma_de_python_valida_y_ejecucion_completa() {
    let (pb, clave) = firmados("ok");
    let p = cargar(&pb, "demo.archivo", "0.1.0", &clave).expect("firma válida");
    let nombre = format!("t{}", std::process::id());
    let env = validar(&p.manifiesto, json!({"nombre": nombre}).as_object().unwrap()).unwrap();
    #[cfg(unix)]
    let (archivo, ruta) = (PathBuf::from(format!("/tmp/helpert-prueba-{nombre}")), "/usr/local/sbin:".to_string());
    #[cfg(windows)]
    let (archivo, ruta) = {
        let (raiz, datos) = (std::env::var("SystemRoot").unwrap(), std::env::var("ProgramData").unwrap());
        (PathBuf::from(format!(r"{datos}\Helpert\tmp\helpert-prueba-{nombre}")), format!(r"{raiz}\System32;"))
    };
    #[cfg(windows)]
    agente::preparar_powershell(); // como el servicio al arrancar: el primer PowerShell deja la caché de módulos
    let d = ejecutar(&p, SO, "diagnosticar", &env, "ana");
    assert_eq!(d.codigo, 0, "{d:?}");
    assert!(d.salida.contains("Se creará"), "salida en UTF-8: {d:?}");
    let s = ejecutar(&p, SO, "aplicar", &env, "ana");
    assert_eq!(s.codigo, 0, "{s:?}");
    let contenido = std::fs::read_to_string(&archivo).unwrap();
    assert!(contenido.contains(&format!("paso=aplicar usuario=ana path={ruta}")), "{contenido}");
    assert_eq!(ejecutar(&p, SO, "verificar", &env, "ana").codigo, 0);
    assert_eq!(ejecutar(&p, SO, "deshacer", &env, "ana").codigo, 0);
    assert!(!archivo.exists());
    assert_eq!(ejecutar(&p, SO, "rm -rf /", &env, "ana").codigo, -1);
    let otro = if SO == "linux" { "windows" } else { "linux" };
    assert_eq!(ejecutar(&p, otro, "aplicar", &env, "ana").codigo, -1); // el script de otro sistema nunca corre aquí
}

#[test]
fn rechaza_script_alterado() {
    let (pb, clave) = firmados("alterado");
    let script = pb.join(if SO == "windows" { "demo.archivo/windows.ps1" } else { "demo.archivo/linux.sh" });
    let mut t = std::fs::read_to_string(&script).unwrap();
    t.push_str("\ntouch /tmp/helpert-pwned\n");
    std::fs::write(&script, t).unwrap();
    assert_eq!(cargar(&pb, "demo.archivo", "0.1.0", &clave).err().unwrap(), "firma no válida");
}

#[test]
fn rechaza_archivo_agregado_version_e_id() {
    let (pb, clave) = firmados("extra");
    assert!(cargar(&pb, "demo.archivo", "9.9.9", &clave).is_err());
    assert!(cargar(&pb, "../demo.archivo", "0.1.0", &clave).is_err());
    std::fs::write(pb.join("demo.archivo/otro.sh"), "reboot").unwrap();
    assert!(cargar(&pb, "demo.archivo", "0.1.0", &clave).is_err());
}

#[test]
fn valida_parametros_como_el_servidor() {
    let m: Manifiesto = toml::from_str(&std::fs::read_to_string(raiz().join("playbooks/print.clear-queue/manifest.toml")).unwrap()).unwrap();
    let v = |x: serde_json::Value| validar(&m, x.as_object().unwrap());
    assert_eq!(v(json!({"impresora": "HP-Piso3"})).unwrap(), vec![("HP_IMPRESORA".into(), "HP-Piso3".into())]);
    assert!(v(json!({})).unwrap().is_empty());
    for malo in ["HP; reboot", "$(id)", "a b", "`id`"] {
        assert!(v(json!({"impresora": malo})).is_err(), "{malo}");
    }
    assert!(v(json!({"impresora": "x".repeat(101)})).is_err());
    assert!(v(json!({"comando": "x"})).is_err());
    assert!(v(json!({"impresora": 3})).is_err());
}

#[test]
fn corta_por_tiempo_y_mata_a_los_hijos() {
    let m: Manifiesto = toml::from_str("id='x'\nversion='1'\nnombre='x'\ntimeout=1\n[sistemas]\nlinux='l.sh'\nwindows='w.ps1'").unwrap();
    let archivos = [("l.sh".to_string(), b"sleep 30 & sleep 30".to_vec()),
                    ("w.ps1".to_string(), b"Start-Process -NoNewWindow ping -ArgumentList '-n','30','127.0.0.1'; Start-Sleep 30".to_vec())]
        .into_iter().collect();
    let p = Paquete { manifiesto: m, archivos };
    let t = std::time::Instant::now();
    assert_eq!(ejecutar(&p, SO, "aplicar", &[], "ana").codigo, 124);
    assert!(t.elapsed().as_secs() < 5);
}

#[test]
fn solo_https_salvo_servidor_local() {
    for ok in ["https://helpert.ejemplo.pe", "http://127.0.0.1:8765", "http://localhost:8000/", "http://[::1]:8000"] {
        assert!(servidor_seguro(ok).is_ok(), "{ok}");
    }
    for malo in ["http://helpert.ejemplo.pe", "http://203.0.113.5:8000", "http://localhost.ejemplo.pe",
                 "http://127.0.0.1.ejemplo.pe", "ftp://x", "helpert.ejemplo.pe", "http://localhost@malo.pe"] {
        assert!(servidor_seguro(malo).is_err(), "{malo}");
    }
}

/// Va a internet: `cargo test -- --ignored`. Un servidor sin Helpert debe responder con un error HTTP, no de certificado.
#[test]
#[ignore]
fn https_real_con_certificados_publicos() {
    let http = ureq::Agent::new_with_config(ureq::config::Config::builder().http_status_as_error(false).build());
    let r = http.post("https://example.com/v1/mensaje").send_json(serde_json::json!({})).expect("TLS debe funcionar");
    assert!(r.status().as_u16() >= 200);
}

/// Una actualización firmada con `helpert-server firmar-agente` se acepta en Rust; otra versión, otro sistema o
/// otros bytes, no.
#[test]
fn actualizacion_firmada_en_python() {
    let dir = std::env::temp_dir().join(format!("helpert-test-act-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let bin = dir.join("helpert-agente");
    let otro = if SO == "linux" { "windows" } else { "linux" };
    std::fs::write(&bin, b"binario de prueba").unwrap();
    let srv = |args: &[&str]| {
        assert!(Command::new("uv").args(["run", "-q", "--project"]).arg(raiz().join("server"))
            .arg("helpert-server").args(args).status().unwrap().success());
    };
    srv(&["claves", dir.join("claves").to_str().unwrap()]);
    srv(&["firmar-agente", bin.to_str().unwrap(), "--version", "0.2.0", "--so", SO,
          "--clave", dir.join("claves/playbooks.key").to_str().unwrap()]);
    let clave = leer_clave(&dir.join("claves/playbooks.pub")).unwrap();
    let firma = std::fs::read_to_string(dir.join("helpert-agente.firma")).unwrap();
    let datos = std::fs::read(&bin).unwrap();
    let sha = huella(&datos);
    assert!(verificar_actualizacion(&datos, "0.2.0", SO, &sha, &firma, &clave).is_ok());
    assert!(verificar_actualizacion(&datos, "0.2.1", SO, &sha, &firma, &clave).is_err());
    assert!(verificar_actualizacion(b"otro binario", "0.2.0", SO, &sha, &firma, &clave).is_err());
    assert!(verificar_actualizacion(&datos, "0.2.0", otro, &sha, &firma, &clave).is_err());
    let _ = std::fs::remove_dir_all(&dir);
}
