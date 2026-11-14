# Permitir rutas de más de 260 caracteres en todo el equipo (LongPathsEnabled = 1 en Control\FileSystem).
# Deshacer lo vuelve a 0 (el valor de fábrica: aplicar solo corre si no estaba en 1). La directiva de grupo
# «Habilitar rutas largas de Win32» escribe este mismo valor: si la empresa lo fija en 0, lo vuelve a poner al
# actualizar las directivas, y verificar lo verá.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$CLAVE = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'

function Valor { try { (Get-ItemProperty -LiteralPath $CLAVE -Name LongPathsEnabled -ErrorAction Stop).LongPathsEnabled } catch { $null } }
function Poner($v) { $null = New-ItemProperty -LiteralPath $CLAVE -Name LongPathsEnabled -Value $v -PropertyType DWord -Force }
function NoAdmin {
  $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
  -not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      if ((Valor) -eq 1) {
        'Las rutas largas ya están permitidas en este equipo.'
        'Si un programa sigue dando el error, es que ese programa no las admite (el Explorador de archivos y muchos programas antiguos no las usan): acorta el nombre de las carpetas o del archivo.'
        exit 10
      }
      'Windows tiene limitadas las rutas de archivo a 260 caracteres.'
      'Si sigo, permito rutas más largas en todo el equipo (se puede deshacer). Algunos programas no las admiten aunque esté activado.'
      exit 0
    }
    'comprobar' {
      if (NoAdmin) { 'Helpert necesita privilegios de administrador para cambiar este ajuste.'; exit 3 }
      exit 0
    }
    'aplicar' {
      if (NoAdmin) { 'Helpert necesita privilegios de administrador para cambiar este ajuste.'; exit 1 }
      Poner 1
      'Activé las rutas largas. Cierra y vuelve a abrir el programa que daba el error (algunos necesitan reiniciar el equipo).'
      exit 0
    }
    'verificar' {
      if ((Valor) -ne 1) { 'Las rutas largas siguen desactivadas: puede que una directiva de la empresa lo impida. Pide a soporte que lo revise.'; exit 1 }
      'Las rutas largas están permitidas.'
      exit 0
    }
    'deshacer' {
      if (NoAdmin) { 'Helpert necesita privilegios de administrador para cambiar este ajuste.'; exit 1 }
      Poner 0
      if ((Valor) -ne 0) { 'No pude volver a dejar el límite de 260 caracteres.'; exit 1 }
      'Volví a dejar el límite de 260 caracteres en las rutas, como estaba.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
