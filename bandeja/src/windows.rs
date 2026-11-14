//! Lo propio de Windows: el icono en el área de notificación (clic: panel; clic derecho: menú), la captura de pantalla
//! y el clic de «Hazlo tú» con la API del sistema, y una sola bandeja por sesión.

use crate::{alternar, mostrar, png, Estado};
use tauri::image::Image;
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::AppHandle;

const ID: &str = "helpert";

/// ¿La barra de tareas es oscura? (SystemUsesLightTheme = 0). HELPERT_TEMA=claro|oscuro lo fuerza.
pub fn oscuro() -> bool {
    use windows_sys::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD};
    match std::env::var("HELPERT_TEMA").as_deref() {
        Ok("claro") => return false,
        Ok("oscuro") => return true,
        _ => {}
    }
    let ancho = |t: &str| t.encode_utf16().chain([0]).collect::<Vec<u16>>();
    let (clave, valor) = (ancho(r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"), ancho("SystemUsesLightTheme"));
    let (mut dato, mut largo) = (1u32, 4u32);
    let r = unsafe {
        RegGetValueW(HKEY_CURRENT_USER, clave.as_ptr(), valor.as_ptr(), RRF_RT_REG_DWORD, std::ptr::null_mut(),
                     &mut dato as *mut u32 as _, &mut largo)
    };
    r == 0 && dato == 0
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
                // al soltar el botón, como OneDrive (el clic en el icono ya le quitó el foco al panel si estaba abierto)
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

/// En Windows no se mira la tubería antes de usarla (abrirla ocupa al servicio con una conexión vacía): el primer
/// mensaje dice si el servicio responde.
pub fn servicio_presente() -> bool {
    true
}

/// Captura del monitor principal en PNG, con PowerShell (System.Drawing), en píxeles reales (proceso con DPI propio).
/// La imagen sale por la salida estándar en base64: sin archivo temporal.
pub fn tomar_captura() -> Result<Vec<u8>, String> {
    use base64::Engine;
    use std::os::windows::process::CommandExt;
    const SCRIPT: &str = r#"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Name D -Namespace H -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][H.D]::SetProcessDPIAware()
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$img = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($img)
$g.CopyFromScreen($b.X, $b.Y, 0, 0, $img.Size)
$m = New-Object System.IO.MemoryStream
$img.Save($m, [System.Drawing.Imaging.ImageFormat]::Png)
[Console]::Out.Write([Convert]::ToBase64String($m.ToArray()))
"#;
    let utf16: Vec<u8> = SCRIPT.encode_utf16().flat_map(u16::to_le_bytes).collect();
    let b64 = base64::engine::general_purpose::STANDARD;
    let raiz = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
    let salida = std::process::Command::new(format!(r"{raiz}\System32\WindowsPowerShell\v1.0\powershell.exe"))
        .args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", &b64.encode(utf16)])
        .creation_flags(0x0800_0000) // sin ventana de consola
        .stderr(std::process::Stdio::null())
        .output();
    let datos = salida.ok().filter(|s| s.status.success())
        .and_then(|s| b64.decode(String::from_utf8_lossy(&s.stdout).trim()).ok())
        .filter(|d| d.starts_with(b"\x89PNG\r\n\x1a\n"));
    datos.ok_or_else(|| "No pude tomar la captura en este equipo. Sigue sin ella; el técnico puede pedirla después.".into())
}

/// shortcut: sin aviso del sistema (notificación de Windows); el icono pasa a «aviso». Usar las notificaciones
/// de Windows (requiere un AppUserModelID registrado por el instalador) cuando haga falta.
pub fn notificar(_texto: &str) {}

/// Abre un enlace ya validado (mailto: o wa.me) con el programa predeterminado.
pub fn abrir_url(url: &str) -> std::io::Result<()> {
    let raiz = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
    std::process::Command::new(format!(r"{raiz}\System32\rundll32.exe")).args(["url.dll,FileProtocolHandler", url]).spawn().map(|_| ())
}

/// El ejecutable del programa de control remoto, donde lo deja su instalador.
pub fn remoto(programa: &str) -> &'static str {
    if programa == "rustdesk" { r"C:\Program Files\RustDesk\rustdesk.exe" } else { r"C:\Program Files (x86)\AnyDesk\AnyDesk.exe" }
}

/// «Hazlo tú»: mueve el cursor al punto (píxeles reales del monitor principal) y hace la acción, con SendInput.
pub fn accionar(accion: &str, x: i32, y: i32) -> Result<(), String> {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::*;
    use windows_sys::Win32::UI::WindowsAndMessaging::SetCursorPos;
    let raton = |flags: MOUSE_EVENT_FLAGS, dato: i32| INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 { mi: MOUSEINPUT { dx: 0, dy: 0, mouseData: dato as u32, dwFlags: flags, time: 0, dwExtraInfo: 0 } },
    };
    let clic = [raton(MOUSEEVENTF_LEFTDOWN, 0), raton(MOUSEEVENTF_LEFTUP, 0)];
    let entradas: Vec<INPUT> = match accion {
        "clic" => clic.to_vec(),
        "doble_clic" => [clic, clic].concat(),
        "desplazar_abajo" => vec![raton(MOUSEEVENTF_WHEEL, -360)],
        "desplazar_arriba" => vec![raton(MOUSEEVENTF_WHEEL, 360)],
        _ => return Err("Este paso lo haces tú.".into()),
    };
    if unsafe { SetCursorPos(x, y) } == 0 {
        return Err("No pude mover el cursor. Hazlo tú y pulsa «Ya lo hice».".into());
    }
    std::thread::sleep(std::time::Duration::from_millis(80));
    let n = unsafe { SendInput(entradas.len() as u32, entradas.as_ptr(), std::mem::size_of::<INPUT>() as i32) };
    if n as usize != entradas.len() {
        return Err("Windows no dejó hacer el clic (¿una ventana de administrador?). Hazlo tú y pulsa «Ya lo hice».".into());
    }
    Ok(())
}
