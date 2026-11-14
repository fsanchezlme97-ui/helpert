# Reconstruir el índice de Windows Search: con SetupCompletedSuccessfully = 0 y el servicio reiniciado, Windows
# borra el índice y lo vuelve a llenar solo (lo mismo que «Reconstruir» en Opciones de indización).
# Si el servicio está desactivado (decisión de soporte o de la empresa), no se fuerza.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$CLAVE = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows Search'

function Servicio { Get-Service WSearch -ErrorAction SilentlyContinue }
function NoPuedo {
  $s = Servicio
  if (-not $s) { return 'Este equipo no tiene el servicio de búsqueda de Windows.' }
  if ("$($s.StartType)" -eq 'Disabled') { return 'La indexación de búsqueda está desactivada en este equipo (lo decidió soporte o la empresa): no la cambio.' }
}
function MB {
  $d = [IO.Path]::Combine($env:ProgramData, 'Microsoft\Search\Data\Applications\Windows')
  $b = 0
  try { foreach ($f in (New-Object IO.DirectoryInfo $d).EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) { $b += $f.Length } } catch {}
  [math]::Round($b / 1MB)
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = NoPuedo; if ($m) { $m; exit 3 }
      $mb = MB
      $txt = ''; if ($mb) { $txt = " y su índice ocupa $mb MB" }
      if ((Servicio).Status -eq 'Running') { "El servicio de búsqueda está funcionando$txt." } else { "El servicio de búsqueda está detenido$txt." }
      'Si sigo, borro el índice y Windows lo vuelve a llenar solo: tarda un rato (hasta horas si tienes muchos archivos) y mientras tanto la búsqueda encuentra menos.'
      exit 0
    }
    'comprobar' {
      $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
      if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Helpert necesita privilegios de administrador para reconstruir el índice.'; exit 3 }
      $m = NoPuedo; if ($m) { $m; exit 3 }
      exit 0
    }
    'aplicar' {
      try {
        Stop-Service WSearch -Force
        [Microsoft.Win32.Registry]::SetValue($CLAVE, 'SetupCompletedSuccessfully', 0, [Microsoft.Win32.RegistryValueKind]::DWord)
        Start-Service WSearch
      } catch { "No pude reconstruir el índice de búsqueda: $($_.Exception.Message)"; exit 1 }
      'Borré el índice de búsqueda; Windows lo está volviendo a llenar. Dale un rato antes de buscar de nuevo.'
      exit 0
    }
    'verificar' {
      for ($i = 0; $i -lt 10 -and (Servicio).Status -ne 'Running'; $i++) { Start-Sleep -Seconds 1 }
      if ((Servicio).Status -ne 'Running') { 'El servicio de búsqueda no volvió a arrancar: reinicia el equipo y, si sigue igual, pide a soporte que lo revise.'; exit 1 }
      'El servicio de búsqueda está funcionando y rehaciendo el índice: irá encontrando más archivos a medida que termine.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
