//! helpert-bandeja: el icono de Helpert en la bandeja (app indicators) y la ventana de chat.
//! Corre como el usuario y habla con el servicio del equipo por el socket local, igual que el chat de terminal.
//!
//! Estados del icono (logo y estados helpert.jpg): disponible, pensando (esperando al servidor o a la IA),
//! trabajando (el servicio corre un paso de playbook) y aviso (respuesta sin leer o error).

mod guia;

use serde_json::{json, Value};
use std::collections::HashSet;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::Mutex;
use std::time::Duration;
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager, WindowEvent};

#[derive(Clone, Copy, PartialEq)]
enum Estado {
    Disponible,
    Pensando,
    Trabajando,
    Aviso,
}

struct Actual(Mutex<Estado>);
struct Notificados(Mutex<HashSet<i64>>); // avisos ya notificados al escritorio

fn png(e: Estado, oscuro: bool) -> &'static [u8] {
    match (e, oscuro) {
        (Estado::Disponible, false) => include_bytes!("../iconos/disponible-claro.png"),
        (Estado::Pensando, false) => include_bytes!("../iconos/pensando-claro.png"),
        (Estado::Trabajando, false) => include_bytes!("../iconos/trabajando-claro.png"),
        (Estado::Aviso, false) => include_bytes!("../iconos/aviso-claro.png"),
        (Estado::Disponible, true) => include_bytes!("../iconos/disponible-oscuro.png"),
        (Estado::Pensando, true) => include_bytes!("../iconos/pensando-oscuro.png"),
        (Estado::Trabajando, true) => include_bytes!("../iconos/trabajando-oscuro.png"),
        (Estado::Aviso, true) => include_bytes!("../iconos/aviso-oscuro.png"),
    }
}

/// Tema del panel: HELPERT_TEMA=claro|oscuro, o el esquema de color del escritorio (oscuro si no hay gsettings).
fn oscuro() -> bool {
    match std::env::var("HELPERT_TEMA").as_deref() {
        Ok("claro") => false,
        Ok("oscuro") => true,
        _ => std::process::Command::new("gsettings")
            .args(["get", "org.gnome.desktop.interface", "color-scheme"])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).contains("dark"))
            .unwrap_or(true),
    }
}

fn poner(app: &AppHandle, e: Estado) {
    *app.state::<Actual>().0.lock().unwrap() = e;
    if let Some(tray) = app.tray_by_id("helpert") {
        let _ = tray.set_icon(Image::from_bytes(png(e, oscuro())).ok());
    }
}

fn socket() -> String {
    std::env::var("HELPERT_SOCKET").unwrap_or_else(|_| "/run/helpert/agente.sock".into())
}

fn mostrar(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("chat") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

/// Una petición al servicio del equipo; las líneas de progreso solo cambian el icono.
fn pedir(app: &AppHandle, pet: &Value) -> Value {
    (|| -> std::io::Result<Value> {
        let s = UnixStream::connect(socket())?;
        writeln!(&s, "{pet}")?;
        for linea in BufReader::new(&s).lines() {
            let v: Value = serde_json::from_str(&linea?).unwrap_or(json!({"error": "Respuesta no válida del servicio"}));
            if v["progreso"] == "trabajando" {
                poner(app, Estado::Trabajando);
            } else {
                return Ok(v);
            }
        }
        Ok(json!({"error": "El servicio de Helpert cerró la conexión"}))
    })()
    .unwrap_or_else(|e| json!({"error": format!("No pude hablar con el servicio de Helpert: {e}")}))
}

/// Envía una petición del chat al servicio y devuelve su respuesta, con el icono en «pensando» mientras tanto.
fn hablar(app: &AppHandle, pet: Value) -> Value {
    poner(app, Estado::Pensando);
    let r = pedir(app, &pet);
    let a_la_vista = app.get_webview_window("chat").and_then(|w| w.is_focused().ok()).unwrap_or(false);
    poner(app, if r.get("error").is_some() || !a_la_vista { Estado::Aviso } else { Estado::Disponible });
    r
}

#[tauri::command]
async fn enviar(app: AppHandle, pet: Value) -> Value {
    let a = app.clone();
    tauri::async_runtime::spawn_blocking(move || hablar(&a, pet))
        .await
        .unwrap_or_else(|e| json!({"error": e.to_string()}))
}

/// Avisos del servicio (visitas de técnicos), sin tocar el icono salvo que haya uno nuevo; su confirmación; y la cuenta
/// (inicio de sesión, perfil, historial), que el servicio valida.
#[tauri::command]
async fn consultar(app: AppHandle, pet: Value) -> Value {
    if !matches!(pet["tipo"].as_str(), Some("avisos" | "aviso_visto" | "cuenta")) {
        return json!({"error": "Petición no válida"});
    }
    let a = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let r = pedir(&a, &pet);
        for aviso in r["avisos"].as_array().into_iter().flatten() {
            let id = aviso["id"].as_i64().unwrap_or_default();
            if a.state::<Notificados>().0.lock().unwrap().insert(id) {
                let a_la_vista = a.get_webview_window("chat").and_then(|w| w.is_focused().ok()).unwrap_or(false);
                if !a_la_vista {
                    poner(&a, Estado::Aviso);
                    let _ = std::process::Command::new("notify-send").args(["-a", "Helpert", "-i", "helpert", "Helpert"])
                        .arg(aviso["texto"].as_str().unwrap_or_default()).spawn();
                }
            }
        }
        r
    })
    .await
    .unwrap_or_else(|e| json!({"error": e.to_string()}))
}

/// Captura de pantalla para el caso. Solo la pide la persona con un botón; la ventana de Helpert se oculta para no
/// salir en la imagen. Devuelve los bytes PNG: la persona los ve antes de decidir si se envían.
/// shortcut: herramientas de captura de cada escritorio (grim, gnome-screenshot, spectacle, import, scrot) y sin
/// ocultamiento automático de datos sensibles; en Windows, la API de captura del sistema.
#[tauri::command]
async fn capturar(app: AppHandle) -> Result<tauri::ipc::Response, String> {
    let ventana = app.get_webview_window("chat");
    if let Some(w) = &ventana {
        let _ = w.hide();
    }
    let r = tauri::async_runtime::spawn_blocking(|| {
        std::thread::sleep(Duration::from_millis(500)); // que la ventana termine de ocultarse
        tomar_captura()
    })
    .await
    .map_err(|e| e.to_string())?;
    if let Some(w) = &ventana {
        let _ = w.show();
        let _ = w.set_focus();
    }
    r.map(tauri::ipc::Response::new)
}

fn tomar_captura() -> Result<Vec<u8>, String> {
    // carpeta propia (0700, falla si ya existe): en /tmp nadie puede dejar antes un enlace con ese nombre
    use std::os::unix::fs::DirBuilderExt;
    let base = std::env::var("XDG_RUNTIME_DIR").map(std::path::PathBuf::from).unwrap_or_else(|_| std::env::temp_dir());
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0);
    let dir = base.join(format!("helpert-captura-{}-{nanos}", std::process::id()));
    std::fs::DirBuilder::new().mode(0o700).create(&dir).map_err(|_| "No pude preparar la captura.".to_string())?;
    let archivo = dir.join("captura.png");
    let f = archivo.display().to_string();
    let propia = std::env::var("HELPERT_CAPTURA_CMD").ok(); // pruebas: un programa que deja un PNG en la ruta dada
    let mut intentos: Vec<Vec<String>> = vec![];
    if let Some(c) = propia {
        intentos.push(vec![c, f.clone()]);
    } else {
        for c in [vec!["grim", &f], vec!["gnome-screenshot", "-f", &f], vec!["spectacle", "-b", "-n", "-o", &f],
                  vec!["import", "-window", "root", &f], vec!["scrot", "-o", &f]] {
            intentos.push(c.into_iter().map(String::from).collect());
        }
    }
    for c in intentos {
        let _ = std::fs::remove_file(&archivo);
        let ok = std::process::Command::new(&c[0]).args(&c[1..]).stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null()).status().map(|s| s.success()).unwrap_or(false);
        let datos = std::fs::read(&archivo).unwrap_or_default();
        let _ = std::fs::remove_file(&archivo);
        if ok && datos.starts_with(b"\x89PNG\r\n\x1a\n") {
            let _ = std::fs::remove_dir(&dir);
            return Ok(datos);
        }
    }
    let _ = std::fs::remove_dir(&dir);
    Err("No pude tomar la captura en este escritorio. Sigue sin ella; el técnico puede pedirla después.".into())
}

/// Abre el programa de control remoto que usa la empresa. Solo esos dos nombres: nada que venga del servidor se ejecuta.
#[tauri::command]
fn abrir_remoto(programa: String) -> Result<(), String> {
    let (bin, nombre) = match programa.as_str() {
        "rustdesk" => ("rustdesk", "RustDesk"),
        "anydesk" => ("anydesk", "AnyDesk"),
        _ => return Err("Programa no válido".into()),
    };
    std::process::Command::new(bin).spawn().map(|_| ()).map_err(|_| format!("{nombre} no está instalado en este equipo. Pide a soporte que lo instale."))
}

/// El contacto de soporte: solo un correo (mailto:) o un número de WhatsApp (https://wa.me/<dígitos>).
fn url_permitida(url: &str) -> bool {
    if let Some(n) = url.strip_prefix("https://wa.me/") {
        return (6..=15).contains(&n.len()) && n.bytes().all(|b| b.is_ascii_digit());
    }
    url.strip_prefix("mailto:").is_some_and(|c| {
        c.len() <= 200 && c.matches('@').count() == 1 && !c.starts_with('@') && !c.ends_with('@')
            && c.bytes().all(|b| b.is_ascii_alphanumeric() || b"@._+-".contains(&b))
    })
}

#[tauri::command]
fn abrir(url: String) -> Result<(), String> {
    if !url_permitida(&url) {
        return Err("Enlace no válido".into());
    }
    std::process::Command::new("xdg-open").arg(url).spawn().map(|_| ()).map_err(|e| e.to_string())
}

/// Una sola bandeja por sesión: si ya hay una, se le pide que abra su ventana y esta termina.
fn ya_abierta() -> Option<std::os::unix::net::UnixListener> {
    let ruta = std::path::PathBuf::from(std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into())).join("helpert-bandeja.sock");
    if UnixStream::connect(&ruta).is_ok() {
        return None;
    }
    let _ = std::fs::remove_file(&ruta);
    std::os::unix::net::UnixListener::bind(&ruta).ok()
}

/// Carpeta de los PNG del icono de la bandeja, nueva en cada ejecución (~/.cache/helpert/bandeja/<pid>). El app indicator
/// los pasa por ruta: con la ruta de siempre (/run/user/N/tray-icon/tray-icon-helpert-0.png), una barra que guarda las
/// imágenes por ruta mostraba el icono de una versión anterior; y algunas barras cambian los de /run y /tmp por el del tema.
fn carpeta_iconos() -> Option<std::path::PathBuf> {
    let cache = std::env::var_os("XDG_CACHE_HOME").map(std::path::PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| std::path::PathBuf::from(h).join(".cache")))?;
    let base = cache.join("helpert").join("bandeja");
    if let Ok(viejas) = std::fs::read_dir(&base) {
        for d in viejas.flatten() {
            let _ = std::fs::remove_dir_all(d.path()); // de ejecuciones anteriores: solo corre una bandeja por sesión
        }
    }
    Some(base.join(std::process::id().to_string()))
}

fn main() {
    let Some(unica) = ya_abierta() else { return };
    tauri::Builder::default()
        .manage(Actual(Mutex::new(Estado::Disponible)))
        .manage(Notificados(Mutex::new(HashSet::new())))
        .manage(guia::Ultimo(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![enviar, consultar, capturar, abrir_remoto, abrir,
                                                 guia::guia_paso, guia::guia_actuar, guia::guia_cerrar])
        .setup(|app| {
            let menu = Menu::with_items(app, &[
                &MenuItem::with_id(app, "abrir", "Abrir Helpert", true, None::<&str>)?,
                &MenuItem::with_id(app, "salir", "Salir", true, None::<&str>)?,
            ])?;
            let inicial = if std::path::Path::new(&socket()).exists() { Estado::Disponible } else { Estado::Aviso };
            let mut tray = TrayIconBuilder::with_id("helpert");
            if let Some(dir) = carpeta_iconos() {
                tray = tray.temp_dir_path(dir);
            }
            tray.icon(Image::from_bytes(png(inicial, oscuro()))?)
                .tooltip("Helpert · soporte TI")
                .menu(&menu)
                .on_menu_event(|app, ev| match ev.id.as_ref() {
                    "abrir" => mostrar(app),
                    "salir" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, ev| {
                    if let tauri::tray::TrayIconEvent::Click { .. } = ev {
                        mostrar(tray.app_handle()); // Windows; en Linux el clic abre el menú
                    }
                })
                .build(app)?;
            *app.state::<Actual>().0.lock().unwrap() = inicial;
            let h = app.handle().clone();
            std::thread::spawn(move || {
                for _ in unica.incoming().flatten() {
                    mostrar(&h); // otra copia (p. ej. desde el menú de aplicaciones) pidió abrir la ventana
                }
            });
            if std::env::args().any(|a| a == "--abrir") {
                mostrar(app.handle());
            }
            Ok(())
        })
        .on_window_event(|w, ev| match ev {
            WindowEvent::CloseRequested { api, .. } => {
                api.prevent_close(); // cerrar la ventana deja el icono en la bandeja
                let _ = w.hide();
            }
            WindowEvent::Focused(true) => {
                let app = w.app_handle();
                if *app.state::<Actual>().0.lock().unwrap() == Estado::Aviso {
                    poner(app, Estado::Disponible); // el aviso se leyó
                }
            }
            _ => {}
        })
        .run(tauri::generate_context!())
        .expect("no pude iniciar la bandeja de Helpert");
}

#[cfg(test)]
mod pruebas {
    #[test]
    fn captura_en_carpeta_propia_que_se_borra() {
        use std::os::unix::fs::PermissionsExt;
        let base = std::env::temp_dir().join(format!("helpert-prueba-{}", std::process::id()));
        std::fs::create_dir_all(&base).unwrap();
        let prog = base.join("capturar.sh");  // deja un PNG mínimo en la ruta y anota la carpeta y sus permisos
        std::fs::write(&prog, format!("#!/bin/sh\nprintf '\\211PNG\\r\\n\\032\\nx' > \"$1\"\nstat -c %a \"$(dirname \"$1\")\" > {0}/permisos\ndirname \"$1\" > {0}/carpeta\n", base.display())).unwrap();
        std::fs::set_permissions(&prog, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::env::set_var("HELPERT_CAPTURA_CMD", &prog);
        let datos = super::tomar_captura().unwrap();
        std::env::remove_var("HELPERT_CAPTURA_CMD");
        assert!(datos.starts_with(b"\x89PNG"));
        assert_eq!(std::fs::read_to_string(base.join("permisos")).unwrap().trim(), "700");
        assert!(!std::path::Path::new(std::fs::read_to_string(base.join("carpeta")).unwrap().trim()).exists());
        std::fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn solo_enlaces_de_contacto() {
        assert!(super::url_permitida("https://wa.me/51999888777"));
        assert!(super::url_permitida("mailto:soporte@acme.pe"));
        for mala in ["https://wa.me/51999&x=1", "https://evil.pe", "mailto:a@b?subject=x", "mailto:a b@c", "file:///etc/passwd",
                     "mailto:@acme.pe", "https://wa.me/"] {
            assert!(!super::url_permitida(mala), "{mala}");
        }
    }
}
