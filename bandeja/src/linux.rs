//! Lo propio de Linux: el icono por StatusNotifierItem (D-Bus), el panel como capa de Wayland, la captura con las
//! herramientas de cada escritorio, avisos con notify-send y una sola bandeja por sesión con un socket.

use crate::{alternar, mostrar, png, Estado};
use serde_json::Value;
use std::time::Duration;
use tauri::image::Image;
use tauri::{AppHandle, Manager};

struct Icono(ksni::Handle<Bandeja>);

/// Tema del panel: HELPERT_TEMA=claro|oscuro, o el esquema de color del escritorio (oscuro si no hay gsettings).
pub fn oscuro() -> bool {
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

/// PNG → ARGB32 en orden de red, el formato de los iconos de StatusNotifierItem. La imagen va en el mensaje D-Bus, no
/// como archivo: así ninguna barra muestra una copia vieja guardada por ruta.
pub fn argb(png: &[u8]) -> ksni::Icon {
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

/// Publica el icono. Sin barra con bandeja (o sin D-Bus) no aparece: la ventana se abre igual con --abrir.
pub fn icono(app: &tauri::App, inicial: Estado) {
    let icono = ksni::TrayService::new(Bandeja { estado: inicial, oscuro: oscuro(), app: app.handle().clone() });
    app.manage(Icono(icono.handle()));
    icono.spawn();
}

pub fn poner_icono(app: &AppHandle, e: Estado) {
    if let Some(i) = app.try_state::<Icono>() {
        i.0.update(|b| b.estado = e);
    }
}

/// ¿El servicio del equipo está instalado? (su socket existe)
pub fn servicio_presente() -> bool {
    std::path::Path::new(&crate::canal::ruta()).exists()
}

/// ¿La barra del escritorio está arriba? En Hyprland, por el espacio que reserva en el monitor activo
/// ([izquierda, arriba, derecha, abajo]).
fn barra_arriba() -> bool {
    std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_some()
        && std::process::Command::new("hyprctl").args(["-j", "monitors"]).output().ok()
            .and_then(|o| serde_json::from_slice::<Value>(&o.stdout).ok())
            .and_then(|v| v.as_array()?.iter().find(|m| m["focused"] == true)?["reserved"].as_array().cloned())
            .is_some_and(|r| r.len() == 4 && r[1].as_i64() > r[3].as_i64())
}

/// Wayland: el panel como capa pegada a la barra, en la esquina derecha, sin taparla. Devuelve false si el escritorio
/// no tiene capas (X11, GNOME): entonces el panel se coloca como ventana normal.
pub fn panel_en_capa(w: &tauri::WebviewWindow, abrir: bool) -> bool {
    if !crate::guia::capa(w, 2, &[1, if barra_arriba() { 2 } else { 3 }], 8, 0, 2, c"helpert-panel") {
        return false;
    }
    // La primera vez que se muestra, la capa no aparece (Hyprland 0.57, GTK 3): se muestra (no se ve) y se oculta un
    // momento después, en otra vuelta del bucle de eventos (en la misma no sirve), para que el primer clic sí lo abra.
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
    true
}

/// Captura de toda la pantalla en PNG.
/// shortcut: herramientas de captura de cada escritorio (grim, gnome-screenshot, spectacle, import, scrot) y sin
/// ocultamiento automático de datos sensibles.
pub fn tomar_captura() -> Result<Vec<u8>, String> {
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

/// Aviso del escritorio (una visita de técnico, por ejemplo).
pub fn notificar(texto: &str) {
    let _ = std::process::Command::new("notify-send").args(["-a", "Helpert", "-i", "helpert", "Helpert"]).arg(texto).spawn();
}

/// Abre un enlace ya validado (mailto: o wa.me) con el programa del escritorio.
pub fn abrir_url(url: &str) -> std::io::Result<()> {
    std::process::Command::new("xdg-open").arg(url).spawn().map(|_| ())
}

/// El ejecutable del programa de control remoto.
pub fn remoto(programa: &str) -> &'static str {
    if programa == "rustdesk" { "rustdesk" } else { "anydesk" }
}

/// Una sola bandeja por sesión: si ya hay una, se le pide que abra su ventana y esta termina (None). Si no, `escuchar`
/// abre el panel cada vez que otra copia lo pide (p. ej. desde el menú de aplicaciones).
pub fn unica() -> Option<std::os::unix::net::UnixListener> {
    let ruta = std::path::PathBuf::from(std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| "/tmp".into())).join("helpert-bandeja.sock");
    if std::os::unix::net::UnixStream::connect(&ruta).is_ok() {
        return None;
    }
    let _ = std::fs::remove_file(&ruta);
    std::os::unix::net::UnixListener::bind(&ruta).ok()
}

pub fn escuchar(unica: std::os::unix::net::UnixListener, h: AppHandle) {
    std::thread::spawn(move || {
        for _ in unica.incoming().flatten() {
            mostrar(&h);
        }
    });
}

#[cfg(test)]
mod pruebas {
    #[test]
    fn icono_en_argb_de_red() {
        // en tres píxeles (una esquina, uno de la marca, la otra esquina) el alfa pasa adelante: RGBA → ARGB
        let png = crate::png(crate::Estado::Disponible, false);
        let i = super::argb(png);
        assert_eq!((i.width, i.height, i.data.len()), (64, 64, 64 * 64 * 4));
        let img = tauri::image::Image::from_bytes(png).unwrap();
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
}
