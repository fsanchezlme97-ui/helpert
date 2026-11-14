//! helpert-bandeja: el icono de Helpert en la bandeja (StatusNotifierItem) y el panel de chat, como el de OneDrive:
//! un clic en el icono despliega el panel junto a la barra y se recoge al hacer clic fuera.
//! Corre como el usuario y habla con el servicio del equipo por el socket local, igual que el chat de terminal.
//!
//! Estados del icono (logo y estados helpert.jpg): disponible, pensando (esperando al servidor o a la IA),
//! trabajando (el servicio corre un paso de playbook) y aviso (respuesta sin leer o error).

mod guia;

use serde_json::{json, Value};
use std::collections::HashSet;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::Ordering;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::image::Image;
use tauri::{AppHandle, Manager, WindowEvent};

#[derive(Clone, Copy, PartialEq)]
enum Estado {
    Disponible,
    Pensando,
    Trabajando,
    Aviso,
}

struct Actual(Mutex<Estado>);
struct Icono(ksni::Handle<Bandeja>);
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
    if let Some(i) = app.try_state::<Icono>() {
        i.0.update(|b| b.estado = e);
    }
}

/// PNG → ARGB32 en orden de red, el formato de los iconos de StatusNotifierItem. La imagen va en el mensaje D-Bus, no
/// como archivo: así ninguna barra muestra una copia vieja guardada por ruta.
fn argb(png: &[u8]) -> ksni::Icon {
    let img = Image::from_bytes(png).expect("icono PNG incluido en el binario");
    let data = img.rgba().chunks_exact(4).flat_map(|p| [p[3], p[0], p[1], p[2]]).collect();
    ksni::Icon { width: img.width() as i32, height: img.height() as i32, data }
}

/// El icono de la bandeja. Clic: abre o cierra el panel. Clic derecho: menú.
struct Bandeja {
    estado: Estado,
    oscuro: bool,
    app: AppHandle,
}

impl ksni::Tray for Bandeja {
    fn id(&self) -> String {
        "helpert".into()
    }
    fn title(&self) -> String {
        "Helpert".into()
    }
    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        vec![argb(png(self.estado, self.oscuro))]
    }
    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip { title: "Helpert · soporte TI".into(), ..Default::default() }
    }
    fn activate(&mut self, _x: i32, _y: i32) {
        let a = self.app.clone(); // ksni llama desde su hilo; las ventanas se tocan en el principal
        let _ = self.app.run_on_main_thread(move || alternar(&a));
    }
    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::StandardItem;
        vec![
            StandardItem { label: "Abrir Helpert".into(), activate: Box::new(|b: &mut Self| {
                let a = b.app.clone();
                let _ = b.app.run_on_main_thread(move || mostrar(&a));
            }), ..Default::default() }.into(),
            StandardItem { label: "Salir".into(), activate: Box::new(|b: &mut Self| b.app.exit(0)), ..Default::default() }.into(),
        ]
    }
}

fn socket() -> String {
    std::env::var("HELPERT_SOCKET").unwrap_or_else(|_| "/run/helpert/agente.sock".into())
}

fn mostrar(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("chat") {
        *MOSTRADO.lock().unwrap() = Some(Instant::now());
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

/// Cuándo se abrió y cuándo se recogió el panel por perder el foco.
static MOSTRADO: Mutex<Option<Instant>> = Mutex::new(None);
static RECOGIDO: Mutex<Option<Instant>> = Mutex::new(None);

/// ¿Pasó hace menos de 400 ms?
fn reciente(t: &Mutex<Option<Instant>>) -> bool {
    t.lock().unwrap().is_some_and(|t| t.elapsed() < Duration::from_millis(400))
}

/// El clic en el icono: abre el panel o lo recoge.
fn alternar(app: &AppHandle) {
    let Some(w) = app.get_webview_window("chat") else { return };
    if w.is_visible().unwrap_or(false) {
        let _ = w.hide();
    } else if !reciente(&RECOGIDO) {
        mostrar(app); // (si se acaba de recoger, fue este mismo clic al quitarle el foco: era para cerrarlo)
    }
}

/// ¿La barra del escritorio está arriba? En Hyprland, por el espacio que reserva en el monitor activo
/// ([izquierda, arriba, derecha, abajo]); en los demás, se asume abajo, como en Windows.
fn barra_arriba() -> bool {
    std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_some()
        && std::process::Command::new("hyprctl").args(["-j", "monitors"]).output().ok()
            .and_then(|o| serde_json::from_slice::<Value>(&o.stdout).ok())
            .and_then(|v| v.as_array()?.iter().find(|m| m["focused"] == true)?["reserved"].as_array().cloned())
            .is_some_and(|r| r.len() == 4 && r[1].as_i64() > r[3].as_i64())
}

/// La ventana de chat como panel en la esquina de la barra, del lado derecho (donde está la bandeja).
fn preparar_panel(w: &tauri::WebviewWindow, abrir: bool) {
    let arriba = barra_arriba();
    #[cfg(target_os = "linux")]
    if guia::capa(w, 2, &[1, if arriba { 2 } else { 3 }], 8, 0, 2, c"helpert-panel") {
        // Wayland: el compositor lo pone junto a la barra, sin taparla. La primera vez que se muestra, la capa no
        // aparece (Hyprland 0.57, GTK 3): se muestra (no se ve) y se oculta un momento después, en otra vuelta del
        // bucle de eventos (en la misma no sirve), para que el primer clic de la persona sí lo abra.
        let _ = w.show();
        let h = w.app_handle().clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(300));
            let _ = h.clone().run_on_main_thread(move || {
                if let Some(w) = h.get_webview_window("chat") {
                    let _ = w.hide();
                }
                if abrir {
                    mostrar(&h);
                }
            });
        });
        return;
    }
    // X11 y escritorios sin capas: en la esquina del monitor principal.
    // shortcut: el alto de la barra se supone de 48 px; leerlo (_NET_WORKAREA) si queda encima o lejos
    if let (Ok(Some(m)), Ok(t)) = (w.primary_monitor(), w.outer_size()) {
        let (mp, ms, borde) = (m.position(), m.size(), (12.0 * m.scale_factor()) as i32);
        let barra = (48.0 * m.scale_factor()) as i32;
        let x = mp.x + ms.width as i32 - t.width as i32 - borde;
        let y = if arriba { mp.y + barra + borde } else { mp.y + ms.height as i32 - t.height as i32 - barra - borde };
        let _ = w.set_position(tauri::PhysicalPosition::new(x, y));
    }
    if abrir {
        mostrar(w.app_handle());
    }
}

/// Esc en el panel lo recoge.
#[tauri::command]
fn recoger(app: AppHandle) {
    if let Some(w) = app.get_webview_window("chat") {
        let _ = w.hide();
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

fn main() {
    let Some(unica) = ya_abierta() else { return };
    tauri::Builder::default()
        .manage(Actual(Mutex::new(Estado::Disponible)))
        .manage(Notificados(Mutex::new(HashSet::new())))
        .manage(guia::Ultimo(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![enviar, consultar, capturar, abrir_remoto, abrir, recoger,
                                                 guia::guia_paso, guia::guia_actuar, guia::guia_cerrar])
        .setup(|app| {
            let inicial = if std::path::Path::new(&socket()).exists() { Estado::Disponible } else { Estado::Aviso };
            // sin barra con bandeja (o sin D-Bus) el icono no aparece: la ventana se abre igual con --abrir
            let icono = ksni::TrayService::new(Bandeja { estado: inicial, oscuro: oscuro(), app: app.handle().clone() });
            app.manage(Icono(icono.handle()));
            icono.spawn();
            let abrir = std::env::args().any(|a| a == "--abrir");
            if let Some(w) = app.get_webview_window("chat") {
                preparar_panel(&w, abrir);
            }
            *app.state::<Actual>().0.lock().unwrap() = inicial;
            let h = app.handle().clone();
            std::thread::spawn(move || {
                for _ in unica.incoming().flatten() {
                    mostrar(&h); // otra copia (p. ej. desde el menú de aplicaciones) pidió abrir la ventana
                }
            });
            Ok(())
        })
        .on_window_event(|w, ev| match ev {
            WindowEvent::CloseRequested { api, .. } => {
                api.prevent_close(); // cerrar la ventana deja el icono en la bandeja
                let _ = w.hide();
            }
            WindowEvent::Focused(false) if w.label() == "chat" && !guia::GUIANDO.load(Ordering::Relaxed) && !reciente(&MOSTRADO) => {
                // como OneDrive: el panel se recoge al hacer clic fuera (no durante una guía en pantalla). Al abrirse,
                // GTK avisa que ganó y perdió el foco antes de que la capa aparezca (Hyprland): eso no cuenta.
                if w.is_visible().unwrap_or(false) {
                    let _ = w.hide();
                    *RECOGIDO.lock().unwrap() = Some(Instant::now());
                }
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
    fn icono_en_argb_de_red() {
        // en tres píxeles (una esquina, uno de la marca, la otra esquina) el alfa pasa adelante: RGBA → ARGB
        let i = super::argb(super::png(super::Estado::Disponible, false));
        assert_eq!((i.width, i.height, i.data.len()), (64, 64, 64 * 64 * 4));
        let img = tauri::image::Image::from_bytes(super::png(super::Estado::Disponible, false)).unwrap();
        for n in [0, 32 * 64 + 20, 64 * 64 - 1] {
            let (r, a) = (&img.rgba()[n * 4..n * 4 + 4], &i.data[n * 4..n * 4 + 4]);
            assert_eq!(a, [r[3], r[0], r[1], r[2]]);
        }
    }

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
