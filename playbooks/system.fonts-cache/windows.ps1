# Reparar las fuentes: para el servicio de caché de fuentes de Windows (FontCache, y el de WPF si está en marcha),
# borra sus archivos de caché (en el perfil de LocalService y FNTCACHE.DAT) y lo vuelve a arrancar: Windows los
# rehace solo. Son archivos del sistema, no de la persona. Un archivo que esté en uso se deja (se rehace al reiniciar).
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$CACHE = "$env:SystemRoot\ServiceProfiles\LocalService\AppData\Local\FontCache"
$FNT = "$env:SystemRoot\System32\FNTCACHE.DAT"

function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Servicio($n) { Get-CimInstance Win32_Service -Filter "Name='$n'" }
# archivos de la caché; $null si no se puede entrar a la carpeta
function Archivos {
  $l = @()
  try {
    if (Test-Path -LiteralPath $CACHE) { $l += @(Get-ChildItem -LiteralPath $CACHE -File -Force -ErrorAction Stop | Where-Object { $_.Name -like '*FontCache*' }) }
    if (Test-Path -LiteralPath $FNT) { $l += Get-Item -LiteralPath $FNT -Force -ErrorAction Stop }
  } catch { return $null }
  , $l
}
function MB($l) { $s = 0; foreach ($f in $l) { $s += $f.Length }; [math]::Round($s / 1MB, 1) }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $s = Servicio 'FontCache'
      if (-not $s) { 'Este equipo no tiene el servicio de caché de fuentes de Windows.'; exit 1 }
      if ($s.StartMode -eq 'Disabled') { 'El servicio de caché de fuentes está desactivado (puede ser una decisión de la empresa): lo tiene que revisar soporte.'; exit 3 }
      $a = Archivos
      if ($null -eq $a) { 'La caché de fuentes existe, pero no pude medirla.' } else { "La caché de fuentes ocupa $(MB $a) MB." }
      'Puedo borrarla y dejar que Windows la reconstruya, para que los programas vuelvan a ver bien las fuentes.'
      exit 0
    }
    'comprobar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para reconstruir la caché de fuentes.'; exit 3 }
      $s = Servicio 'FontCache'
      if (-not $s -or $s.StartMode -eq 'Disabled') { 'El servicio de caché de fuentes no está disponible en este equipo.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $wpf = Servicio 'FontCache3.0.0.0'
      $borrados = 0; $quedan = 0; $m = $null
      try {
        Stop-Service -Name FontCache -Force -ErrorAction Stop
        if ($wpf -and $wpf.State -eq 'Running') { Stop-Service -Name 'FontCache3.0.0.0' -Force -ErrorAction SilentlyContinue }
        $a = Archivos
        if ($null -eq $a) { $m = 'No pude entrar a la carpeta de la caché de fuentes: lo tiene que ver soporte.' }
        else { foreach ($f in $a) { try { $f.Delete(); $borrados++ } catch { $quedan++ } } }
      } catch {
        $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
        $m = "No pude detener el servicio de caché de fuentes: $($e.Message)"
      } finally {
        try { Start-Service -Name FontCache -ErrorAction Stop } catch {}
        if ($wpf -and $wpf.State -eq 'Running') { try { Start-Service -Name 'FontCache3.0.0.0' -ErrorAction Stop } catch {} }
      }
      if ($m) { $m; exit 1 }
      if (-not $borrados) { 'No pude borrar ningún archivo de la caché de fuentes (están en uso o no tengo acceso): reinicia el equipo y vuelve a intentarlo.'; exit 1 }
      "Borré la caché de fuentes ($borrados archivo(s)) y Windows la está reconstruyendo."
      if ($quedan) { "$quedan archivo(s) estaban en uso: se rehacen al reiniciar el equipo." }
      'Cierra y vuelve a abrir los programas para que vean las fuentes; si alguno sigue igual, reinicia el equipo.'
      exit 0
    }
    'verificar' {
      if ((Get-Service -Name FontCache).Status -ne 'Running') { 'El servicio de caché de fuentes no volvió a arrancar.'; exit 1 }
      'El servicio de caché de fuentes funciona y la caché se está reconstruyendo.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
