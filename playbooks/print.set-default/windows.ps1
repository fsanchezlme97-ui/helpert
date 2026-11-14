# Impresora predeterminada. En Windows es de cada persona: se guarda en su registro (HKEY_USERS\<SID>, valor Device).
# Además se apaga «Permitir que Windows administre la impresora predeterminada» (LegacyDefaultPrinterMode = 1),
# porque si no Windows la cambia sola por la última que se usó. HP_IMPRESORA ya viene validado; se busca sin
# distinguir mayúsculas, primero por nombre exacto y luego por parte del nombre.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$pedida = "$env:HP_IMPRESORA"

function SidDe($cuenta) {  # solo cuentas de personas (locales, de dominio o de Entra ID), nunca SYSTEM ni de servicio
  if (-not $cuenta) { return $null }
  try { $s = (New-Object Security.Principal.NTAccount($cuenta)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
  if ($s -match '^S-1-(5-21|12-1)-') { $s }
}
function Valor($ruta, $nombre) {  # sin -Name: los nombres de impresora pueden traer [ ] y -Name los toma como comodines
  try { (Get-ItemProperty -LiteralPath $ruta -ErrorAction Stop).$nombre } catch { $null }
}
$sid = SidDe $env:HP_USUARIO
$K = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows NT\CurrentVersion"

# las del equipo y las conexiones de la persona a impresoras de un servidor (SYSTEM no ve estas con Get-Printer)
function Impresoras {
  $l = @(Get-Printer -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  $l += @(Get-ChildItem -LiteralPath "Registry::HKEY_USERS\$sid\Printers\Connections" -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName.Replace(',', '\') })
  @($l | Sort-Object -Unique)
}
function Elegida {
  $t = @(Impresoras)
  $e = @($t | Where-Object { $_ -eq $pedida })
  if ($e.Count -eq 0) { $e = @($t | Where-Object { $_ -like "*$pedida*" }) }
  $e | Select-Object -First 1
}
function Actual { $d = Valor "$K\Windows" 'Device'; if ($d) { ($d -split ',')[0] } }
function Fija { (Valor "$K\Windows" 'LegacyDefaultPrinterMode') -eq 1 }
function NoPuedo {
  if (-not $sid) { return 'No sé qué persona lo pide.' }
  if (-not (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid")) { return 'Necesito que tengas la sesión abierta en este equipo para cambiar tu impresora predeterminada.' }
  if (-not $pedida) { return 'Necesito el nombre de la impresora.' }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = NoPuedo; if ($m) { $m; exit 3 }
      $todas = @(Impresoras)
      if ($todas.Count -eq 0) { 'Este equipo no tiene impresoras instaladas; soporte tiene que instalarla.'; exit 1 }
      $e = Elegida
      if (-not $e) { "No encontré la impresora «$pedida». Las instaladas son: $($todas -join ', ')."; exit 1 }
      $a = Actual
      if ($a -eq $e -and (Fija)) { "«$e» ya es la impresora predeterminada."; exit 10 }
      if ($a -eq $e) { "«$e» ya es la predeterminada, pero Windows la cambia sola por la última que usaste; eso lo apago para que se quede."; exit 0 }
      if ($a) { "La predeterminada ahora es «$a»; la cambio por «$e»." } else { "No tienes impresora predeterminada; dejo «$e»." }
      exit 0
    }
    'comprobar' {
      $m = NoPuedo; if ($m) { $m; exit 3 }
      $yo = [Security.Principal.WindowsIdentity]::GetCurrent()
      $admin = (New-Object Security.Principal.WindowsPrincipal $yo).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
      if ($yo.User.Value -ne $sid -and -not $admin) { 'Helpert necesita privilegios de administrador para cambiar la impresora predeterminada.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $e = Elegida
      if (-not $e) { "No encontré la impresora «$pedida»."; exit 1 }
      # el valor lleva el puerto que Windows anotó para esa impresora en Devices («winspool,Ne01:»)
      $puerto = Valor "$K\Devices" $e
      if (-not $puerto) { $puerto = 'winspool,Ne00:' }
      Set-ItemProperty -LiteralPath "$K\Windows" -Name LegacyDefaultPrinterMode -Value 1 -Type DWord
      Set-ItemProperty -LiteralPath "$K\Windows" -Name Device -Value "$e,$puerto" -Type String
      "Dejé «$e» como impresora predeterminada."
      exit 0
    }
    'verificar' {
      $e = Elegida
      if (-not $e -or (Actual) -ne $e -or -not (Fija)) { 'La predeterminada no cambió.'; exit 1 }
      "«$e» es ahora la impresora predeterminada. Si tu programa recuerda otra, elígela una vez al imprimir; los programas que ya estaban abiertos la ven al volver a abrirlos."
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
