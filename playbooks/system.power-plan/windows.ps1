# Poner el plan de energía equilibrado (powercfg). Se lee el GUID del plan, no su nombre, que cambia con el idioma.
# Si una política de la empresa fija el plan, no se toca.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$EQUILIBRADO = '381b4222-f694-41f0-9685-ff5bb260df2e'
$NOMBRES = @{ 'a1841308-3541-4fab-bc81-f71556f20b4a' = 'ahorro de energía'; '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'alto rendimiento'; 'e9a42b02-d5df-448d-aa00-03f14749eb61' = 'máximo rendimiento' }
$GUID = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

# con la salida redirigida, 5.1 convierte el stderr de un programa en error: aquí se ignora
function Powercfg { $ErrorActionPreference = 'Continue'; & "$env:SystemRoot\System32\powercfg.exe" @args 2>$null }
function Valor($ruta, $nombre) { try { (Get-ItemProperty -LiteralPath $ruta -Name $nombre -ErrorAction Stop).$nombre } catch { $null } }
function Activo { $l = "$(Powercfg /getactivescheme)"; if ($l -match $GUID) { $Matches[0].ToLower() } }
function Nombre {  # del plan activo: el conocido en español, o el que muestra Windows entre paréntesis
  $g = Activo
  if ($g -and $NOMBRES[$g]) { return $NOMBRES[$g] }
  if ("$(Powercfg /getactivescheme)" -match '\(([^)]+)\)\s*$') { return $Matches[1] }
  'otro plan'
}
function Existe { @(Powercfg /list) -match $EQUILIBRADO }
function Politica { $p = "$(Valor 'HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings' 'ActivePowerScheme')"; $p -and $p.ToLower() -ne $EQUILIBRADO }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $g = Activo
      if (-not $g) { 'No pude leer el plan de energía de este equipo.'; exit 1 }
      if ($g -eq $EQUILIBRADO) { 'El plan de energía ya está en equilibrado.'; exit 10 }
      if (Politica) { "El plan de energía está en «$(Nombre)» porque lo fija una política de la empresa. Si te molesta, habla con soporte."; exit 3 }
      if (-not (Existe)) { "El plan de energía está en «$(Nombre)» y este equipo no tiene el plan equilibrado. Avisa a soporte."; exit 3 }
      "El plan de energía está en «$(Nombre)». Lo dejaría en equilibrado."
      exit 0
    }
    'comprobar' {
      $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
      if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Helpert necesita privilegios de administrador para cambiar el plan de energía.'; exit 3 }
      if (Politica) { 'Una política de la empresa fija el plan de energía: no lo cambio.'; exit 3 }
      if (-not (Existe)) { 'Este equipo no tiene el plan equilibrado.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $null = Powercfg /setactive $EQUILIBRADO
      if ($LASTEXITCODE -ne 0 -or (Activo) -ne $EQUILIBRADO) { 'No se pudo cambiar el plan de energía.'; exit 1 }
      'Dejé el plan de energía en equilibrado.'
      exit 0
    }
    'verificar' {
      if ((Activo) -ne $EQUILIBRADO) { "El plan de energía sigue en «$(Nombre)»."; exit 1 }
      'El plan de energía está en equilibrado.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
