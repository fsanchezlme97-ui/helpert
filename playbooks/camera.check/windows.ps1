# Revisar la cámara: si Windows la detecta, si su controlador funciona, si la privacidad la bloquea y qué programa
# la está usando (Windows lo anota en el registro de la persona). Solo lectura: termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$CONSENTIMIENTO = 'Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\webcam'

function SidDe($cuenta) {  # solo cuentas de personas (locales, de dominio o de Entra ID), nunca SYSTEM ni de servicio
  if (-not $cuenta) { return $null }
  try { $s = (New-Object Security.Principal.NTAccount($cuenta)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
  if ($s -match '^S-1-(5-21|12-1)-') { $s }
}
function Valor($ruta, $nombre) {
  try { (Get-ItemProperty -LiteralPath $ruta -Name $nombre -ErrorAction Stop).$nombre } catch { $null }
}
# programas que tienen la cámara abierta ahora: los que empezaron a usarla y no terminaron (LastUsedTimeStop = 0)
function Usando($raiz) {
  foreach ($k in @(Get-ChildItem -LiteralPath $raiz -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath "$raiz\NonPackaged" -ErrorAction SilentlyContinue)) {
    if ($k.PSChildName -eq 'NonPackaged') { continue }
    $ini = Valor $k.PSPath 'LastUsedTimeStart'; $fin = Valor $k.PSPath 'LastUsedTimeStop'
    if ($ini -and $fin -eq 0) {
      # NonPackaged: «C:#Program Files#Zoom#bin#Zoom.exe»; apps de la tienda: «Microsoft.WindowsCamera_8wekyb3d8bbwe»
      (($k.PSChildName -split '#')[-1] -split '_')[0] -replace '\.exe$', ''
    }
  }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      # sin ninguna cámara, Get-PnpDevice da error en vez de una lista vacía
      $todas = @(try { Get-PnpDevice -Class Camera, Image -PresentOnly -ErrorAction Stop } catch { })
      $cams = @($todas | Where-Object { $_.Class -eq 'Camera' -or $_.FriendlyName -match 'cam|video' })
      if ($cams.Count -eq 0) {
        'El equipo no detecta ninguna cámara. Si es externa, desconéctala y conéctala en otro puerto; si es de la laptop, revisa que no tenga una tapa o una tecla de cámara apagada.'
        exit 10
      }
      $c = $cams[0]
      "El equipo detecta la cámara «$($c.FriendlyName)»."
      if ($c.ConfigManagerErrorCode -eq 22) { 'La cámara está desactivada en el Administrador de dispositivos: pide a soporte que la active.'; exit 10 }
      if ($c.Status -ne 'OK') { "Windows dice que la cámara tiene un problema (código $($c.ConfigManagerErrorCode)): desconéctala y conéctala, o reinicia el equipo. Si sigue igual, pide a soporte que revise su controlador."; exit 10 }
      if ((Valor "HKLM:\$CONSENTIMIENTO" 'Value') -eq 'Deny') { 'El acceso a la cámara está bloqueado para todo el equipo: pide a soporte que lo active en la privacidad de Windows.'; exit 10 }
      $sid = SidDe $env:HP_USUARIO
      $usuario = "Registry::HKEY_USERS\$sid\$CONSENTIMIENTO"
      if ($sid -and (Test-Path -LiteralPath $usuario)) {
        if ((Valor $usuario 'Value') -eq 'Deny') { 'Tienes desactivado el acceso a la cámara: actívalo en Configuración > Privacidad y seguridad > Cámara.'; exit 10 }
        if ((Valor "$usuario\NonPackaged" 'Value') -eq 'Deny') { 'Los programas de escritorio no tienen permiso para usar la cámara: actívalo en Configuración > Privacidad y seguridad > Cámara («Permitir que las aplicaciones de escritorio accedan a la cámara»).'; exit 10 }
        $usando = @(Usando $usuario | Sort-Object -Unique)
        if ($usando.Count) { "Ahora la está usando: $($usando -join ', '). Cierra ese programa y vuelve a abrir la videollamada."; exit 10 }
      }
      'Ningún programa la está usando. En la videollamada, elige esta cámara en la configuración de video y dale permiso si lo pide.'
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
