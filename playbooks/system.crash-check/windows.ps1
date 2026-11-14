# Ver por qué el equipo se apagó solo: busca en el registro del sistema de los últimos 30 días los reinicios
# inesperados (Kernel-Power 41), las pantallas azules (BugCheck 1001) y los errores de hardware (WHEA). Los datos se
# leen por nombre del evento, no del texto (que cambia con el idioma). Solo lectura: termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$DESDE = (Get-Date).AddDays(-30)

function Eventos($proveedor, $id) {
  $f = @{ LogName = 'System'; ProviderName = $proveedor; StartTime = $DESDE }; if ($id) { $f.Id = $id }
  try { @(Get-WinEvent -FilterHashtable $f -MaxEvents 50 -ErrorAction Stop) } catch { @() }
}
function Dato($evento, $nombre) {
  foreach ($d in ([xml]$evento.ToXml()).Event.EventData.Data) { if ($d.Name -eq $nombre) { return "$($d.'#text')" } }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $cortes = @(Eventos 'Microsoft-Windows-Kernel-Power' 41)
      $azules = @(Eventos 'Microsoft-Windows-WER-SystemErrorReporting' 1001)
      $hw = @(Eventos 'Microsoft-Windows-WHEA-Logger' $null | Where-Object { $_.Level -in 1, 2 })
      $volcados = @(Get-ChildItem -LiteralPath "$env:SystemRoot\Minidump" -Filter '*.dmp' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $DESDE })
      if (-not ($cortes.Count + $azules.Count + $hw.Count + $volcados.Count)) {
        'En los últimos 30 días el equipo no tuvo apagados inesperados ni pantallas azules.'
        exit 10
      }
      $azul = $azules.Count -gt 0 -or $volcados.Count -gt 0
      $partes = @()
      if ($cortes.Count) { $partes += "$($cortes.Count) apagado(s) o reinicio(s) inesperado(s)" }
      if ($azules.Count + $volcados.Count) { $partes += "$([math]::Max($azules.Count, $volcados.Count)) pantalla(s) azul(es)" }
      if ($hw.Count) { $partes += "$($hw.Count) error(es) de hardware (procesador, memoria o disco)" }
      "En los últimos 30 días encontré $($partes -join ', ')."
      foreach ($e in ($cortes | Select-Object -First 5)) {
        $codigo = [int64](Dato $e 'BugcheckCode'); $boton = Dato $e 'PowerButtonTimestamp'; $sueno = Dato $e 'SleepInProgress'
        if ($codigo) { $c = 'pantalla azul (código 0x{0:X})' -f $codigo; $azul = $true }
        elseif ($boton -and $boton -ne '0') { $c = 'se mantuvo apretado el botón de encendido' }
        elseif ($sueno -and $sueno -ne '0' -and $sueno -ne 'false') { $c = 'se apagó mientras estaba suspendido (batería agotada o corte de luz)' }
        else { $c = 'se cortó de golpe (corte de luz, batería agotada o equipo congelado)' }
        "- $($e.TimeCreated.ToString('yyyy-MM-dd HH:mm')): $c."
      }
      if ($hw.Count) { 'Los errores de hardware los tiene que revisar un técnico.' }
      elseif ($azul) { 'Las pantallas azules suelen venir de un controlador o del hardware: avisa a soporte con esta información.' }
      else { 'Si vuelve a pasar con el cargador conectado, avisa a soporte.' }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
