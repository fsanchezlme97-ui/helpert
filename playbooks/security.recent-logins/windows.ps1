# Ver los inicios de sesión (en el equipo, por Escritorio remoto o con la contraseña guardada) y los intentos fallidos
# de los últimos 7 días, según el registro de seguridad de Windows (eventos 4624 y 4625). Solo cuenta personas, no
# cuentas del sistema. Solo lectura: termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$SEMANA = 'TimeCreated[timediff(@SystemTime) <= 604800000]'
$TIPO = @{ 2 = 'en el equipo'; 3 = 'por la red'; 7 = 'al desbloquear'; 10 = 'por Escritorio remoto'; 11 = 'en el equipo' }
$CI = [Globalization.CultureInfo]::InvariantCulture

# los eventos que pide $filtro, cada uno como diccionario con sus datos; $null si no se puede leer el registro
function Eventos($filtro) {
  try { $ev = @(Get-WinEvent -LogName Security -FilterXPath $filtro -MaxEvents 1000 -ErrorAction Stop) }
  catch { if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return , @() }; return $null }
  , @($ev | ForEach-Object {
      $d = @{ Hora = $_.TimeCreated }
      foreach ($n in ([xml]$_.ToXml()).Event.EventData.Data) { $d[$n.Name] = $n.'#text' }
      $d
    })
}
function Como($t) { $x = $TIPO[[int]$t]; if ($x) { $x } else { 'de otra forma' } }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $ok = Eventos "*[System[(EventID=4624) and $SEMANA] and EventData[Data[@Name='LogonType']='2' or Data[@Name='LogonType']='10' or Data[@Name='LogonType']='11']]"
      $mal = Eventos "*[System[(EventID=4625) and $SEMANA]]"
      if ($null -eq $ok -or $null -eq $mal) { 'No pude leer el registro de seguridad de Windows: avisa a soporte.'; exit 1 }
      # solo personas (no DWM, UMFD ni servicios); Windows anota dos veces cada inicio de un administrador
      $tope = $ok.Count -ge 1000
      $ok = @($ok | Where-Object { $_.TargetUserSid -match '^S-1-(5-21|12-1)-' } |
          Sort-Object { "$($_.TargetUserSid) $($_.Hora.ToString('yyyyMMddHHmmss'))" } -Unique | Sort-Object { $_.Hora })
      $n1 = "$($ok.Count)"; if ($tope) { $n1 = "al menos $n1" }
      $n2 = "$($mal.Count)"; if ($mal.Count -ge 1000) { $n2 = 'más de 1000' }
      "En los últimos 7 días hubo $n1 inicio(s) de sesión y $n2 intento(s) fallido(s)."
      $ok | Group-Object { "$($_.TargetDomainName)\$($_.TargetUserName)" } | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object {
        $u = $_.Group[-1]
        $remoto = @($_.Group | Where-Object { $_.LogonType -eq '10' }).Count
        "- $($_.Name): $($_.Count) inicio(s); el último el $($u.Hora.ToString('dd/MM', $CI)) a las $($u.Hora.ToString('HH:mm', $CI)), $(Como $u.LogonType)$(if ($remoto) { " ($remoto por Escritorio remoto)" })."
      }
      $mal | Group-Object { "$($_.TargetUserName)|$($_.LogonType)" } | Sort-Object Count -Descending | Select-Object -First 3 | ForEach-Object {
        $f = $_.Group[-1]
        $desde = "$($f.IpAddress)"; if ($desde -match '^(-|127\.|::1$)' -or -not $desde) { $desde = '' } else { $desde = " desde $desde" }
        "- Fallaron $($_.Count) intento(s) con la cuenta «$($f.TargetUserName)» $(Como $f.LogonType)$desde."
      }
      $viejo = $null; try { $viejo = (Get-WinEvent -LogName Security -MaxEvents 1 -Oldest -ErrorAction Stop).TimeCreated } catch { }
      if ($viejo -and $viejo -gt (Get-Date).AddDays(-6)) { "Ojo: el registro de seguridad solo guarda desde el $($viejo.ToString('dd/MM HH:mm', $CI)); antes de eso no puedo saberlo." }
      if ($mal.Count) { 'Si no reconoces algún intento, cambia tu contraseña y avisa a soporte.' }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
