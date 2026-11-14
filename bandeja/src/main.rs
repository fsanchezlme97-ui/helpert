//! helpert-bandeja: el icono de Helpert en la bandeja y el panel de chat, como el de OneDrive: un clic en el icono
//! despliega el panel junto a la barra y se recoge al hacer clic fuera. Corre como el usuario y habla con el servicio
//! del equipo por el canal local (socket o tubería), igual que el chat de terminal. Lo propio de cada sistema está en
//! linux.rs, windows.rs y macos.rs.
//!
//! Estados del icono (logo y estados helpert.jpg): disponible, pensando (esperando al servidor o a la IA),
//! trabajando (el servicio corre un paso de playbook) y aviso (respuesta sin leer o error).

#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")] // sin ventana de consola

#[path = "../../agente/src/canal.rs"]
mod canal;
mod guia;
#[cfg_attr(target_os = "linux", path = "linux.rs")]
#[cfg_attr(target_os = "macos", path = "macos.rs")]
#[cfg_attr(windows, path = "windows.rs")]
mod plataforma;

use serde_json::{json, Value};
use std::collections::HashSet;
use std::io::{BufRead, BufReader, Write};
use std::sync::atomic::Ordering;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager, WindowEvent};

#[derive(Clone, Copy, PartialEq)]
pub enum Estado {
    Disponible,
    Pensando,
    Trabajando,
    Aviso,
}

struct Actual(Mutex<Estado>);
struct Notificados(Mutex<HashSet<i64>>); // avisos ya notificados al escritorio

pub fn png(e: Estado, oscuro: bool) -> &'static [u8] {
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

fn poner(app: &AppHandle, e: Estado) {
    *app.state::<Actual>().0.lock().unwrap() = e;
    plataforma::poner_icono(app, e);
}

pub fn mostrar(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("chat") {
        *MOSTRADO.lock().unwrap() = Some(Instant::now());
        if !EN_CAPA.load(Ordering::Relaxed) {
            esquina(&w); // el monitor o la barra pudieron cambiar desde la última vez
        }
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
    }
}

/// El panel es una capa de Wayland: el compositor lo pone junto a la barra.
static EN_CAPA: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Cuándo se abrió y cuándo se recogió el panel por perder el foco.
static MOSTRADO: Mutex<Option<Instant>> = Mutex::new(None);
static RECOGIDO: Mutex<Option<Instant>> = Mutex::new(None);

/// ¿Pasó hace menos de 400 ms?
fn reciente(t: &Mutex<Option<Instant>>) -> bool {
    t.lock().unwrap().is_some_and(|t| t.elapsed() < Duration::from_millis(400))
}

/// El clic en el icono: abre el panel o lo recoge.
pub fn alternar(app: &AppHandle) {
    let Some(w) = app.get_webview_window("chat") else { return };
    if w.is_visible().unwrap_or(false) {
        let _ = w.hide();
    } else if !reciente(&RECOGIDO) {
        mostrar(app); // (si se acaba de recoger, fue este mismo clic al quitarle el foco: era para cerrarlo)
    }
}

/// El panel junto a la barra, del lado derecho (donde está la bandeja). En Wayland con capas lo coloca el compositor;
/// si no, va en la esquina del área de trabajo del monitor donde está el cursor (sin la barra de tareas): abajo, o
/// arriba si la barra está arriba.
fn preparar_panel(w: &tauri::WebviewWindow, abrir: bool) {
    #[cfg(target_os = "linux")]
    if plataforma::panel_en_capa(w, abrir) {
        EN_CAPA.store(true, Ordering::Relaxed);
        return;
    }
    esquina(w);
    if abrir {
        mostrar(w.app_handle());
    }
}

fn esquina(w: &tauri::WebviewWindow) {
    let monitor = w.cursor_position().ok().and_then(|c| w.monitor_from_point(c.x, c.y).ok().flatten())
        .or_else(|| w.primary_monitor().ok().flatten());
    let (Some(m), Ok(t)) = (monitor, w.outer_size()) else { return };
    let (area, borde) = (m.work_area(), (12.0 * m.scale_factor()) as i32);
    let x = area.position.x + area.size.width as i32 - t.width as i32 - borde;
    let y = if area.position.y > m.position().y {
        area.position.y + borde
    } else {
        area.position.y + area.size.height as i32 - t.height as i32 - borde
    };
    let _ = w.set_position(tauri::PhysicalPosition::new(x, y));
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
        let s = canal::conectar(&canal::ruta())?;
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
                    plataforma::notificar(aviso["texto"].as_str().unwrap_or_default());
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
#[tauri::command]
async fn capturar(app: AppHandle) -> Result<tauri::ipc::Response, String> {
    let ventana = app.get_webview_window("chat");
    if let Some(w) = &ventana {
        let _ = w.hide();
    }
    let r = tauri::async_runtime::spawn_blocking(|| {
        std::thread::sleep(Duration::from_millis(500)); // que la ventana termine de ocultarse
        plataforma::tomar_captura()
    })
    .await
    .map_err(|e| e.to_string())?;
    if let Some(w) = &ventana {
        let _ = w.show();
        let _ = w.set_focus();
    }
    r.map(tauri::ipc::Response::new)
}

/// Abre el programa de control remoto que usa la empresa. Solo esos dos nombres: nada que venga del servidor se ejecuta.
#[tauri::command]
fn abrir_remoto(programa: String) -> Result<(), String> {
    let nombre = match programa.as_str() {
        "rustdesk" => "RustDesk",
        "anydesk" => "AnyDesk",
        _ => return Err("Programa no válido".into()),
    };
    std::process::Command::new(plataforma::remoto(&programa)).spawn().map(|_| ()).map_err(|_| format!("{nombre} no está instalado en este equipo. Pide a soporte que lo instale."))
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
    plataforma::abrir_url(&url).map_err(|e| e.to_string())
}

fn main() {
    // una sola bandeja por sesión: si ya hay una, se le pide que abra su panel y esta termina
    #[cfg(target_os = "linux")]
    let Some(unica) = plataforma::unica() else { return };
    let constructor = tauri::Builder::default();
    #[cfg(any(windows, target_os = "macos"))]
    let constructor = constructor.plugin(tauri_plugin_single_instance::init(|app, _, _| mostrar(app)));
    constructor
        .manage(Actual(Mutex::new(Estado::Disponible)))
        .manage(Notificados(Mutex::new(HashSet::new())))
        .manage(guia::Ultimo(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![enviar, consultar, capturar, abrir_remoto, abrir, recoger,
                                                 guia::guia_paso, guia::guia_actuar, guia::guia_cerrar])
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory); // solo en la barra de menús, sin icono en el Dock
            let inicial = if plataforma::servicio_presente() { Estado::Disponible } else { Estado::Aviso };
            plataforma::icono(app, inicial);
            let abrir = std::env::args().any(|a| a == "--abrir");
            if let Some(w) = app.get_webview_window("chat") {
                preparar_panel(&w, abrir);
            }
            *app.state::<Actual>().0.lock().unwrap() = inicial;
            #[cfg(target_os = "linux")]
            plataforma::escuchar(unica, app.handle().clone());
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
    fn solo_enlaces_de_contacto() {
        assert!(super::url_permitida("https://wa.me/51999888777"));
        assert!(super::url_permitida("mailto:soporte@acme.pe"));
        for mala in ["https://wa.me/51999&x=1", "https://evil.pe", "mailto:a@b?subject=x", "mailto:a b@c", "file:///etc/passwd",
                     "mailto:@acme.pe", "https://wa.me/"] {
            assert!(!super::url_permitida(mala), "{mala}");
        }
    }
}
