# Reparar Microsoft Office: lanza la reparación rápida de Office «Hacer clic y ejecutar» (OfficeClickToRun.exe
# scenario=Repair RepairType=QuickRepair, sin ventanas y sin cerrar programas a la fuerza) y espera a que termine.
# Office tiene que estar cerrado: comprobar lo exige (en cualquier sesión, porque Office es uno solo para el equipo).
# Office instalado con MSI no se repara así: lo hace soporte.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$C2R = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
$OFFICE = [ordered]@{ winword = 'Word'; excel = 'Excel'; powerpnt = 'PowerPoint'; outlook = 'Outlook'; onenote = 'OneNote'
  msaccess = 'Access'; mspub = 'Publisher'; visio = 'Visio'; winproj = 'Project'; lync = 'Skype Empresarial' }

function Valor($ruta, $nombre) {
  try { (Get-ItemProperty -LiteralPath $ruta -Name $nombre -ErrorAction Stop).$nombre } catch { $null }
}
function Exe { [IO.Path]::Combine($env:CommonProgramFiles, 'microsoft shared\ClickToRun\OfficeClickToRun.exe') }
function Instalado { (Valor $C2R 'Platform') -and [IO.File]::Exists((Exe)) }
function Abiertos {  # nombres de los programas de Office abiertos en el equipo
  @(Get-CimInstance Win32_Process | ForEach-Object { "$($_.Name)".ToLower() -replace '\.exe$', '' } | Where-Object { $OFFICE.Contains($_) } |
      Sort-Object -Unique | ForEach-Object { $OFFICE[$_] })
}
function Reparando { @(Get-CimInstance Win32_Process -Filter "Name='OfficeClickToRun.exe'" | Where-Object { "$($_.CommandLine)" -match 'scenario=repair' }).Count -gt 0 }
function EsAdmin {
  (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      if (-not (Instalado)) { 'No encontré Microsoft Office «Hacer clic y ejecutar» en este equipo: si tienes Office, es de otro tipo y la reparación la tiene que hacer soporte.'; exit 3 }
      "Tienes Microsoft Office, versión $(Valor $C2R 'VersionToReport'). Puedo hacer su reparación rápida: no necesita internet y tarda unos minutos."
      $a = Abiertos
      if ($a.Count) { "Antes tienes que cerrar: $($a -join ', '). Guarda tus documentos." }
      if (Reparando) { 'Ya hay una reparación de Office en curso: espera a que termine.'; exit 10 }
      exit 0
    }
    'comprobar' {
      if (-not (EsAdmin)) { 'Helpert necesita privilegios de administrador para reparar Office.'; exit 3 }
      if (-not (Instalado)) { 'No encontré Office «Hacer clic y ejecutar» en este equipo.'; exit 3 }
      if (Reparando) { 'Ya hay una reparación de Office en curso.'; exit 3 }
      $a = Abiertos
      if ($a.Count) { "Cierra $($a -join ', ') (guarda tus documentos) y vuelve a pedírmelo. Si ya lo cerraste, puede que siga abierto en otra sesión de este equipo."; exit 3 }
      exit 0
    }
    'aplicar' {
      if (-not (Instalado)) { 'No encontré Office «Hacer clic y ejecutar» en este equipo.'; exit 1 }
      $plat = "$(Valor $C2R 'Platform')".ToLower(); $cult = "$(Valor $C2R 'ClientCulture')".ToLower()
      # vienen del registro del equipo, pero van en una línea de órdenes: solo valores con forma conocida
      if ($plat -notmatch '^(x86|x64|arm64)$') { $plat = 'x64' }
      if ($cult -notmatch '^[a-z]{2,3}(-[a-z]{2,4})?$') { $cult = 'en-us' }
      $psi = New-Object Diagnostics.ProcessStartInfo (Exe), "scenario=Repair platform=$plat culture=$cult RepairType=QuickRepair forceappshutdown=False DisplayLevel=False"
      $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
      $p = [Diagnostics.Process]::Start($psi)
      $limite = (Get-Date).AddMinutes(27)
      if (-not $p.WaitForExit(1500000)) { 'La reparación de Office sigue en curso después de 25 minutos: déjala terminar y vuelve a probar más tarde.'; exit 1 }
      # el lanzador puede terminar antes que la reparación: se espera a que no quede ninguna en curso
      while ((Reparando) -and (Get-Date) -lt $limite) { Start-Sleep -Seconds 10 }
      if ($p.ExitCode -ne 0) { "La reparación de Office terminó con un error (código $($p.ExitCode)). Pide a soporte que la haga."; exit 1 }
      'Terminé la reparación rápida de Office. Abre el programa que fallaba para probar. Si sigue fallando, soporte puede hacer la reparación completa (por internet).'
      exit 0
    }
    'verificar' {
      if (Reparando) { 'La reparación de Office todavía está en curso.'; exit 1 }
      if (-not (Instalado)) { 'Office ya no aparece instalado después de la reparación: avisa a soporte.'; exit 1 }
      'Office está instalado y la reparación terminó. Abre el programa que fallaba para probar.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
