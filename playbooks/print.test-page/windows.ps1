# Imprimir una página de prueba: la de Windows (Win32_Printer.PrintTestPage). HP_IMPRESORA (opcional) por nombre
# exacto o, si no, que lo contenga; sin él, la predeterminada de la persona (está en su rama del registro: la de
# SYSTEM es otra). No envía a impresoras virtuales (PDF, XPS, OneNote, fax): ahí no sale papel y el trabajo puede
# quedarse esperando un nombre de archivo. Desde el servicio solo se ven las impresoras instaladas en el equipo:
# las conectadas desde un servidor (\\servidor\impresora) son de la sesión de la persona.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$imp = "$env:HP_IMPRESORA"
$VIRTUAL = 'PDF|XPS|OneNote|Fax'

function SidDe($cuenta) {  # solo cuentas de personas (locales, de dominio o de Entra ID), nunca SYSTEM ni de servicio
  if (-not $cuenta) { return $null }
  try { $s = (New-Object Security.Principal.NTAccount($cuenta)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
  if ($s -match '^S-1-(5-21|12-1)-') { $s }
}
function Valor($ruta, $nombre) {
  try { (Get-ItemProperty -LiteralPath $ruta -Name $nombre -ErrorAction Stop).$nombre } catch { $null }
}
function Activo { (Get-Service Spooler -ErrorAction SilentlyContinue).Status -eq 'Running' }
function Predeterminada {
  $sid = SidDe $env:HP_USUARIO
  if ($sid) {
    $d = Valor "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows NT\CurrentVersion\Windows" 'Device'
    if ($d) { return ($d -split ',')[0] }
  }
  $p = @(Get-CimInstance Win32_Printer -Filter 'Default = TRUE' -ErrorAction SilentlyContinue)
  if ($p.Count) { $p[0].Name }
}
function Destino {
  $t = @(Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue)
  if ($imp) {
    $e = @($t | Where-Object { $_.Name -eq $imp })
    if ($e.Count -eq 0) { $patron = '*' + [WildcardPattern]::Escape($imp) + '*'; $e = @($t | Where-Object { $_.Name -like $patron }) }
    return ($e | Select-Object -First 1)
  }
  $d = Predeterminada
  if ($d) { $t | Where-Object { $_.Name -eq $d } | Select-Object -First 1 }
}
function Virtual($p) { $p.Name -match $VIRTUAL -or "$($p.PortName)" -match '^(PORTPROMPT|FILE|nul|XPSPort|SHRFAX):' }
function Estado($p) { $x = @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $p.Name }); if ($x.Count) { [int]$x[0].PrinterStatus } else { -1 } }
function Pendientes($p) { @(Get-PrintJob -PrinterName $p.Name -ErrorAction SilentlyContinue).Count }
# el motivo por el que no se puede enviar la prueba (nada si se puede)
function Motivo {
  if (-not (Activo)) { return 'El servicio de impresión está detenido: usa primero «Liberar cola de impresión».' }
  $p = Destino
  if (-not $p) {
    if ($imp) { return "No encontré la impresora «$imp» en este equipo. Si es una impresora compartida de un servidor, desde aquí no la puedo usar: imprime la prueba desde sus propiedades." }
    $d = Predeterminada
    if ($d) { return "Tu impresora predeterminada «$d» está compartida desde un servidor: desde aquí no la puedo usar. Imprime la prueba desde sus propiedades o dime otra impresora." }
    return 'No hay una impresora predeterminada: dime a qué impresora envío la prueba.'
  }
  if (Virtual $p) { return "«$($p.Name)» no es una impresora de papel (guarda en un archivo): dime una impresora de verdad." }
  if ((Estado $p) -eq 1) { return "La impresora «$($p.Name)» está en pausa: usa primero «Liberar cola de impresión» para reactivarla." }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Motivo; if ($m) { $m; exit 1 }
      $p = Destino; $n = Pendientes $p
      "Voy a enviar una página de prueba a «$($p.Name)»."
      if ($n) { "Tiene $n trabajo(s) esperando en la cola: la prueba saldrá después de ellos." }
      exit 0
    }
    'comprobar' {
      $m = Motivo; if ($m) { $m; exit 3 }
      exit 0
    }
    'aplicar' {
      $p = Destino
      if (-not $p) { 'No sé a qué impresora enviar la prueba.'; exit 1 }
      try { $r = Invoke-CimMethod -InputObject $p -MethodName PrintTestPage } catch { "No pude enviar la página de prueba a «$($p.Name)»: Windows no la aceptó."; exit 1 }
      if ($r.ReturnValue -ne 0) { "No pude enviar la página de prueba a «$($p.Name)» (código $($r.ReturnValue))."; exit 1 }
      "Envié una página de prueba a «$($p.Name)»."
      exit 0
    }
    'verificar' {
      $p = Destino
      if (-not $p) { 'No sé a qué impresora envié la prueba.'; exit 1 }
      for ($i = 0; $i -lt 20 -and (Pendientes $p) -gt 0; $i++) { Start-Sleep -Seconds 1 }
      $e = Estado $p
      $motivos = @{ 1 = 'quedó en pausa'; 2 = 'tiene un error'; 4 = 'tiene un atasco de papel'; 5 = 'se quedó sin papel'; 7 = 'tiene un problema con el papel'; 8 = 'no está conectada'; 19 = 'se quedó sin tóner'; 21 = 'necesita que alguien la revise'; 23 = 'tiene una tapa abierta' }
      if ($motivos.ContainsKey($e)) { "La impresora «$($p.Name)» $($motivos[$e]): revísala y vuelve a probar."; exit 1 }
      if ((Pendientes $p) -gt 0) { "La página sigue en la cola de «$($p.Name)» sin imprimirse: la impresora no responde. Revisa que esté encendida, con papel y conectada."; exit 1 }
      "La página de prueba ya pasó a «$($p.Name)»."
      'Si no salió el papel, revisa que esté encendida, con papel y sin luces de error; si sigue igual, avisa a soporte.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
