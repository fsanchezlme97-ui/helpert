//! Lo propio de macOS: el icono en la barra de menús (clic: panel; clic derecho: menú), la captura con screencapture
//! y avisos con el Centro de notificaciones. Una sola bandeja por sesión: tauri-plugin-single-instance (main.rs).
//! El clic de «Hazlo tú» no está: la guía muestra dónde y la persona lo hace (guia.rs lo dice).

use crate::{alternar, mostrar, png, Estado};
use std::process::{Command, Stdio};
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::AppHandle;

const ID: &str = "helpert";

/// ¿La barra de menús es oscura? (AppleInterfaceStyle = Dark). HELPERT_TEMA=claro|oscuro lo fuerza.
pub fn oscuro() -> bool {
    match std::env::var("HELPERT_TEMA").as_deref() {
        Ok("claro") => return false,
        Ok("oscuro") => return true,
        _ => {}
    }
    Command::new("/usr/bin/defaults").args(["read", "-g", "AppleInterfaceStyle"]).stderr(Stdio::null()).output()
        .is_ok_and(|o| String::from_utf8_lossy(&o.stdout).trim() == "Dark")
}

pub fn icono(app: &tauri::App, inicial: Estado) {
    let construir = || -> tauri::Result<()> {
        let abrir = MenuItem::with_id(app, "abrir", "Abrir Helpert", true, None::<&str>)?;
        let salir = MenuItem::with_id(app, "salir", "Salir", true, None::<&str>)?;
        TrayIconBuilder::with_id(ID)
            .icon(Image::from_bytes(png(inicial, oscuro()))?)
            .tooltip("Helpert · soporte TI")
            .menu(&Menu::with_items(app, &[&abrir, &salir])?)
            .show_menu_on_left_click(false)
            .on_menu_event(|app, e| match e.id().as_ref() {
                "abrir" => mostrar(app),
                "salir" => app.exit(0),
                _ => {}
            })
            .on_tray_icon_event(|t, e| {
                if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = e {
                    alternar(t.app_handle());
                }
            })
            .build(app)?;
        Ok(())
    };
    if let Err(e) = construir() {
        eprintln!("[bandeja] icono: {e}");
    }
}

pub fn poner_icono(app: &AppHandle, e: Estado) {
    if let (Some(t), Ok(i)) = (app.tray_by_id(ID), Image::from_bytes(png(e, oscuro()))) {
        let _ = t.set_icon(Some(i));
    }
}

/// ¿El servicio del equipo está instalado? (su socket existe)
pub fn servicio_presente() -> bool {
    std::path::Path::new(&crate::canal::ruta()).exists()
}

/// Captura de toda la pantalla en PNG con screencapture, en una carpeta propia (0700) dentro de la carpeta temporal
/// de la persona. macOS pide permiso de «Grabación de pantalla» la primera vez; sin él la imagen sale vacía o falla.
pub fn tomar_captura() -> Result<Vec<u8>, String> {
    use std::os::unix::fs::DirBuilderExt;
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0);
    let dir = std::env::temp_dir().join(format!("helpert-captura-{}-{nanos}", std::process::id()));
    std::fs::DirBuilder::new().mode(0o700).create(&dir).map_err(|_| "No pude preparar la captura.".to_string())?;
    let archivo = dir.join("captura.png");
    let ok = Command::new("/usr/sbin/screencapture").args(["-x", "-t", "png"]).arg(&archivo)
        .stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok_and(|s| s.success());
    let datos = std::fs::read(&archivo).unwrap_or_default();
    let _ = std::fs::remove_file(&archivo);
    let _ = std::fs::remove_dir(&dir);
    if ok && datos.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Ok(datos);
    }
    Err("No pude tomar la captura. Si macOS lo pidió, da permiso a Helpert en Ajustes del Sistema > Privacidad y \
         seguridad > Grabación de pantalla. Sigue sin ella; el técnico puede pedirla después.".into())
}

/// Aviso del Centro de notificaciones. El texto va como argumento del script, no dentro de él.
pub fn notificar(texto: &str) {
    let _ = Command::new("/usr/bin/osascript")
        .args(["-e", "on run argv", "-e", "display notification (item 1 of argv) with title \"Helpert\"", "-e", "end run"])
        .arg(texto).stdout(Stdio::null()).stderr(Stdio::null()).spawn();
}

/// Abre un enlace ya validado (mailto: o wa.me) con el programa predeterminado.
pub fn abrir_url(url: &str) -> std::io::Result<()> {
    Command::new("/usr/bin/open").arg(url).spawn().map(|_| ())
}

/// El ejecutable del programa de control remoto, donde lo deja su instalador.
pub fn remoto(programa: &str) -> &'static str {
    if programa == "rustdesk" { "/Applications/RustDesk.app/Contents/MacOS/RustDesk" } else { "/Applications/AnyDesk.app/Contents/MacOS/AnyDesk" }
}
