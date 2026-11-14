# Prueba de los scripts de Windows de los playbooks, para CI (Windows PowerShell 5.1). No es un playbook.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File playbooks\probar-windows.ps1
# 1. Cada playbooks\*\windows.ps1 es UTF-8 sin BOM, no pasa de 10 000 caracteres y no tiene errores de sintaxis.
#    Se lee como UTF-8 y se analiza con ParseInput (no ParseFile): sin BOM, 5.1 leería el archivo como ANSI, y el
#    agente tampoco lo lee del disco, sino que lo pasa como texto con -EncodedCommand.
# 2. Cada manifiesto que declara windows = "windows.ps1" tiene el archivo, y cada archivo está declarado.
# 3. El paso «diagnosticar» de cada script corre en un powershell.exe nuevo, como lo lanza el agente: entorno mínimo,
#    HP_PASO, HP_USUARIO (quien corre la prueba) y los parámetros requeridos con un valor de ejemplo del manifiesto.
#    Debe salir con 0, 1, 3 o 10, en menos de 120 s, con texto y sin caracteres dañados (U+FFFD) al leerlo como UTF-8.
#    Un 1 que viene del catch general («Algo salió mal...») también cuenta como falla: es un error, no un mensaje.
# 4. Con -Aplicar (solo en la CI, máquinas desechables): si diagnosticar dice que hay algo que hacer, también corren
#    comprobar → aplicar → verificar, salvo los que dejarían a la máquina sin red o la reiniciarían ($NO_APLICAR).
# Este archivo lleva BOM para que 5.1 lo lea bien con -File.
param([switch]$Aplicar)
$ErrorActionPreference = 'Stop'
$NO_APLICAR = '^(net\.(no-internet|wifi|vpn|network-drive|ip-renew|winsock-reset)|system\.restart|system\.update|app\.update|app\.office-(repair|update)|system\.repair-files|security\.quick-scan|disk\.optimize|security\.firewall|time\.sync|domain\.|bluetooth\.)'
$raiz = Split-Path -Parent $MyInvocation.MyCommand.Path
$estricto = New-Object System.Text.UTF8Encoding($false, $true)
$utf8 = New-Object System.Text.UTF8Encoding $false
# la misma cabecera que pone el agente (sin cmdlets: cargarlos sin caché completa tarda 18-28 s)
$encabezado = "`$ProgressPreference = 'SilentlyContinue'`n[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(`$false)`n`$OutputEncoding = [Console]::OutputEncoding`n"
# carpetas como las del agente: temporal y caché de módulos propias
$datos = Join-Path $env:ProgramData 'HelpertPrueba'
$tmp = Join-Path $datos 'tmp'; $cache = Join-Path $datos 'powershell'
New-Item -ItemType Directory -Force $tmp, $cache | Out-Null
$fallos = New-Object System.Collections.Generic.List[string]
function Falla($texto) { $fallos.Add($texto); Write-Host "FALLA  $texto" }

# lo justo de TOML para esta prueba: windows en [sistemas], la descripción y los [parametros.X]
function Manifiesto($ruta) {
  $m = @{ windows = $null; descripcion = ''; parametros = [ordered]@{} }
  $seccion = ''
  foreach ($l in [System.IO.File]::ReadAllLines($ruta, $utf8)) {
    if ($l -match '^\s*\[\s*([^\]]+?)\s*\]') {
      $seccion = $Matches[1]
      if ($seccion -like 'parametros.*') { $m.parametros[$seccion.Substring(11)] = @{} }
      continue
    }
    if ($l -notmatch '^\s*([A-Za-z_]+)\s*=\s*(.*)$') { continue }
    $clave = $Matches[1]; $valor = $Matches[2]
    if ($valor -match '^"([^"]*)"') { $valor = $Matches[1] } else { $valor = ($valor -replace '#.*$', '').Trim() }
    if ($seccion -eq 'sistemas' -and $clave -eq 'windows') { $m.windows = $valor }
    elseif ($seccion -eq '' -and $clave -eq 'descripcion') { $m.descripcion = $valor }
    elseif ($seccion -like 'parametros.*') { $m.parametros[$seccion.Substring(11)][$clave] = $valor }
  }
  $m
}
# un valor válido para el agente: [A-Za-z0-9._-], sacado de «por ejemplo ...» en la pregunta o la descripción
function Ejemplo($m, $p) {
  if ($p.tipo -eq 'entero') { if ($p.min) { return $p.min } else { return '1' } }
  if ($p.tipo -eq 'booleano') { return '1' }
  $v = 'prueba'
  foreach ($t in @($p.pregunta, $m.descripcion)) {
    if ("$t" -match 'por ejemplo\s+([A-Za-z0-9._-]+)') { $v = $Matches[1]; break }
  }
  if ($p.max -and $v.Length -gt [int]$p.max) { $v = $v.Substring(0, [int]$p.max) }
  $v
}
function Ejecutar($texto, $variables) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $codigo = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($encabezado + $texto))
  $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $codigo"
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
  # el mismo entorno mínimo que da el agente
  $psi.EnvironmentVariables.Clear()
  foreach ($k in 'SystemRoot', 'windir', 'SystemDrive', 'ProgramData', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432',
                 'CommonProgramFiles', 'CommonProgramFiles(x86)', 'COMPUTERNAME', 'PATHEXT', 'NUMBER_OF_PROCESSORS',
                 'PROCESSOR_ARCHITECTURE', 'OS', 'ALLUSERSPROFILE', 'PUBLIC') {
    $v = [Environment]::GetEnvironmentVariable($k); if ($v) { $psi.EnvironmentVariables[$k] = $v }
  }
  $r0 = $env:SystemRoot
  $psi.EnvironmentVariables['PATH'] = "$r0\System32;$r0;$r0\System32\Wbem;$r0\System32\WindowsPowerShell\v1.0\"
  $psi.EnvironmentVariables['PSModuleAnalysisCachePath'] = Join-Path $cache 'ModuleAnalysisCache'
  $psi.EnvironmentVariables['TEMP'] = $tmp
  $psi.EnvironmentVariables['TMP'] = $tmp
  foreach ($k in $variables.Keys) { $psi.EnvironmentVariables[$k] = $variables[$k] }
  $p = [System.Diagnostics.Process]::Start($psi)
  $p.StandardInput.Close()
  $salida = $p.StandardOutput.ReadToEndAsync(); $error2 = $p.StandardError.ReadToEndAsync()
  $codigoSalida = 124
  if ($p.WaitForExit(600000)) { $p.WaitForExit(); $codigoSalida = $p.ExitCode } else { try { $p.Kill() } catch { } }
  [void]$salida.Wait(5000); [void]$error2.Wait(5000)
  $r = @{ Codigo = $codigoSalida; Salida = ''; Error = '' }
  if ($salida.IsCompleted) { $r.Salida = $salida.Result }
  if ($error2.IsCompleted) { $r.Error = $error2.Result }
  $r
}

$usuario = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
Write-Host "Usuario: $usuario"
# como preparar_powershell del agente: la caché completa de módulos, una vez
$t0 = Get-Date
$null = Ejecutar '$null = Get-Module -ListAvailable -Refresh; $null = Get-Command -CommandType Cmdlet, Function' @{}
Write-Host "Caché de módulos lista en $([int]((Get-Date) - $t0).TotalSeconds) s"
$carpetas = @(Get-ChildItem -LiteralPath $raiz -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'manifest.toml') } | Sort-Object Name)
if ($carpetas.Count -eq 0) { Falla 'no encontré ningún playbook'; exit 1 }
$probados = 0
foreach ($c in $carpetas) {
  $id = $c.Name
  $m = Manifiesto (Join-Path $c.FullName 'manifest.toml')
  $script = Join-Path $c.FullName 'windows.ps1'
  $hay = Test-Path -LiteralPath $script
  if ($m.windows -and $m.windows -ne 'windows.ps1') { Falla "${id}: el manifiesto declara «$($m.windows)»; se espera windows.ps1"; continue }
  if ($m.windows -and -not $hay) { Falla "${id}: el manifiesto declara windows.ps1, pero el archivo no existe"; continue }
  if ($hay -and -not $m.windows) { Falla "${id}: hay windows.ps1, pero el manifiesto no lo declara en [sistemas]"; continue }
  if (-not $hay) { Write-Host "--     ${id}: sin script de Windows"; continue }

  $bytes = [System.IO.File]::ReadAllBytes($script)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { Falla "${id}: windows.ps1 tiene BOM"; continue }
  try { $texto = $estricto.GetString($bytes) } catch { Falla "${id}: windows.ps1 no es UTF-8 válido"; continue }
  if ($texto.Length -gt 10000) { Falla "${id}: windows.ps1 tiene $($texto.Length) caracteres (máximo 10 000)"; continue }
  $tokens = $null; $errores = $null
  [void][System.Management.Automation.Language.Parser]::ParseInput($texto, [ref]$tokens, [ref]$errores)
  if ($errores.Count) {
    foreach ($e in $errores) { Falla "${id}: línea $($e.Extent.StartLineNumber): $($e.Message)" }
    continue
  }

  $variables = @{ HP_PASO = 'diagnosticar'; HP_USUARIO = $usuario }
  foreach ($n in $m.parametros.Keys) {
    $p = $m.parametros[$n]
    if ($p.requerido -eq 'true') { $variables["HP_$($n.ToUpper())"] = Ejemplo $m $p }
  }
  $inicio = Get-Date
  $r = Ejecutar $texto $variables
  $seg = [int]((Get-Date) - $inicio).TotalSeconds
  $probados++
  $primera = ("$($r.Salida)".Trim() -split "`r?`n")[0]
  if (@(0, 1, 3, 10) -notcontains $r.Codigo) { Falla "${id}: diagnosticar salió con $($r.Codigo) en $seg s. Salida: $($r.Salida.Trim()) Error: $($r.Error.Trim())"; continue }
  if (-not "$($r.Salida)".Trim()) { Falla "${id}: diagnosticar no escribió nada (código $($r.Codigo)). Error: $($r.Error.Trim())"; continue }
  # el catch general de cada script: un error de .NET inesperado, no un «no se puede» con su mensaje
  if ($r.Salida.Contains('Algo salió mal y no pude terminar')) { Falla "${id}: diagnosticar terminó en el catch general: $($r.Salida.Trim())"; continue }
  if ($r.Salida.Contains([string][char]0xFFFD)) { Falla "${id}: la salida tiene caracteres dañados (U+FFFD): $($r.Salida.Trim())"; continue }
  Write-Host "ok     ${id}: código $($r.Codigo) en $seg s: $primera"
  if (-not $Aplicar -or $r.Codigo -ne 0 -or $id -match $NO_APLICAR) { continue }
  # los pasos que cambian algo, en una máquina desechable: 0, 1 o 3 con su mensaje; nunca el catch general ni 2
  foreach ($paso in 'comprobar', 'aplicar', 'verificar') {
    $variables.HP_PASO = $paso
    $r = Ejecutar $texto $variables
    $txt = "$($r.Salida)".Trim()
    if (@(0, 1, 3) -notcontains $r.Codigo -or $txt.Contains('Algo salió mal y no pude terminar') -or $txt.Contains([string][char]0xFFFD)) {
      Falla "${id}: $paso salió con $($r.Codigo). Salida: $txt Error: $($r.Error.Trim())"; break
    }
    Write-Host "         $paso → $($r.Codigo): $(($txt -split "`r?`n")[0])"
    if ($r.Codigo -ne 0) { break }
  }
}

Write-Host ''
if ($fallos.Count) { Write-Host "$($fallos.Count) falla(s) en $($carpetas.Count) playbooks."; exit 1 }
Write-Host "Todo bien: $probados script(s) de Windows probados."
exit 0
