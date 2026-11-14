# Revisar errores del sistema de archivos sin reparar nada (solo lectura: termina con 10). El disco del sistema se
# revisa en línea con Repair-Volume -Scan (lo mismo que «chkdsk /scan»: no repara, solo anota lo que encuentra para la
# reparación); los demás discos fijos, con el estado que ya conoce Windows. También avisa de discos en solo lectura.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
      if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Helpert necesita privilegios de administrador para revisar el disco.'; exit 3 }
      $letra = $env:SystemDrive.TrimEnd(':')
      try { $r = "$(Repair-Volume -DriveLetter $letra -Scan)" } catch { "No pude revisar el disco ${letra}: $($_.Exception.Message)"; exit 1 }
      $malos = New-Object Collections.Generic.List[string]
      try {
        foreach ($v in @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and "$($_.DriveLetter)" -ne $letra })) {
          if ("$($v.HealthStatus)" -notin '', 'Healthy', 'Unknown', '0', '5') { $malos.Add("$($v.DriveLetter):") }
        }
      } catch {}
      $soloLectura = @()
      try { $soloLectura = @(Get-Disk | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.FriendlyName }) } catch {}
      $problema = $false
      if ($r -match 'NoErrors') { "No encontré errores en el disco ${letra}: (el del sistema)." }
      elseif ($r -match 'SpotFix|FullRepair|Corrupt') {
        "El disco ${letra}: tiene errores que hay que reparar al reiniciar el equipo."
        'Guarda tu trabajo y pide a soporte que programe la reparación (la hace Windows al arrancar y puede tardar un rato).'
        $problema = $true
      }
      else { "Revisé el disco ${letra}: y Windows dice: $r." }
      if ($malos.Count) { "Windows también marca con problemas: $($malos -join ', '). Pide a soporte que los revise."; $problema = $true }
      if ($soloLectura.Count) { "Estos discos están en solo lectura: $($soloLectura -join ', '). Puede ser un bloqueo de la empresa o un error del disco: pide a soporte que lo revise."; $problema = $true }
      if (-not $problema) { 'Si un programa dice que un archivo está dañado, puede ser solo ese archivo: prueba con una copia de seguridad.' }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
