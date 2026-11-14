//! Canal local entre el servicio del equipo y sus clientes (la bandeja y el chat de terminal): una línea JSON
//! por petición. Linux: socket Unix en /run/helpert (de root). Windows: tubería con nombre de SYSTEM.
//!
//! La bandeja incluye este archivo tal cual (`#[path]`), así que solo usa std y windows-sys.

#[cfg(unix)]
pub type Conexion = std::os::unix::net::UnixStream;
#[cfg(windows)]
pub type Conexion = std::fs::File;

#[cfg(unix)]
pub const RUTA: &str = "/run/helpert/agente.sock";
#[cfg(windows)]
pub const RUTA: &str = r"\\.\pipe\helpert-agente";

/// La ruta del canal: `HELPERT_SOCKET` (desarrollo) o la del servicio instalado.
pub fn ruta() -> String {
    std::env::var("HELPERT_SOCKET").unwrap_or_else(|_| RUTA.into())
}

#[cfg(unix)]
pub fn conectar(ruta: &str) -> std::io::Result<Conexion> {
    Conexion::connect(ruta)
}

/// Abre la tubería con los permisos justos (leer y escribir datos, no crear instancias) y, si es la del servicio,
/// comprueba que su dueño sea SYSTEM: otro usuario que la creara antes que el servicio no recibe la conversación.
#[cfg(windows)]
pub fn conectar(ruta: &str) -> std::io::Result<Conexion> {
    use std::os::windows::fs::OpenOptionsExt;
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Foundation::{LocalFree, ERROR_SUCCESS};
    use windows_sys::Win32::Security::Authorization::{GetSecurityInfo, SE_KERNEL_OBJECT};
    use windows_sys::Win32::Security::{IsWellKnownSid, WinLocalSystemSid, OWNER_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR, PSID};
    use windows_sys::Win32::Storage::FileSystem::{FILE_GENERIC_READ, FILE_WRITE_DATA};
    let f = std::fs::OpenOptions::new().access_mode(FILE_GENERIC_READ | FILE_WRITE_DATA).open(ruta)?;
    if ruta != RUTA {
        return Ok(f); // desarrollo: el agente corre como el propio usuario
    }
    let (mut dueno, mut sd): (PSID, PSECURITY_DESCRIPTOR) = (std::ptr::null_mut(), std::ptr::null_mut());
    let r = unsafe {
        GetSecurityInfo(f.as_raw_handle() as _, SE_KERNEL_OBJECT, OWNER_SECURITY_INFORMATION, &mut dueno,
                        std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut(), &mut sd)
    };
    let de_system = r == ERROR_SUCCESS && unsafe { IsWellKnownSid(dueno, WinLocalSystemSid) } != 0;
    if !sd.is_null() {
        unsafe { LocalFree(sd as _) };
    }
    if !de_system {
        return Err(std::io::Error::new(std::io::ErrorKind::PermissionDenied, "la tubería del agente no es del servicio de Helpert"));
    }
    Ok(f)
}
