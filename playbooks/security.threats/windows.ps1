# Ver qué detectó Microsoft Defender en los últimos 30 días y qué hizo con cada amenaza. Solo lectura: termina
# con 10. Sacar un archivo de la cuarentena lo decide soporte.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$ACCION = @{ 1 = 'detectada, sin resolver'; 2 = 'limpiada'; 3 = 'aislada en cuarentena'; 4 = 'eliminada'; 5 = 'permitida'
  6 = 'bloqueada'; 102 = 'no se pudo aislar'; 103 = 'no se pudo eliminar'; 105 = 'sin resolver'; 107 = 'no se pudo bloquear' }

function OtroAV {
  try { $p = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop) } catch { return $null }
  ($p | Where-Object { ($_.productState -band 0x1000) -and $_.displayName -notmatch 'Defender' } | Select-Object -First 1).displayName
}

# nombre del archivo de un recurso de Defender («file:_C:\...\a.zip->b.exe», «webfile:_C:\...\a.exe|https://...»)
function Archivo($r) { ((("$r" -replace '^[A-Za-z]+:_', '') -split '\||->')[0] -split '\\')[-1] }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $s = $null; try { $s = Get-MpComputerStatus -ErrorAction Stop } catch { }
      if (-not $s) {
        $o = OtroAV
        if ($o) { "El antivirus de este equipo es «$o». Helpert solo sabe leer el historial de Microsoft Defender: revísalo en ese programa o pide ayuda a soporte." }
        else { 'Microsoft Defender no está funcionando en este equipo, así que no puedo leer su historial: avisa a soporte.' }
        exit 3
      }
      $desde = (Get-Date).AddDays(-30)
      try { $todas = @(Get-MpThreatDetection -ErrorAction Stop) } catch { 'No pude leer el historial de Microsoft Defender: avisa a soporte.'; exit 1 }
      $det = @($todas | Where-Object { $_.InitialDetectionTime -ge $desde } | Sort-Object InitialDetectionTime -Descending)
      if ($det.Count -eq 0) { 'Microsoft Defender no registró amenazas en los últimos 30 días.'; exit 10 }
      $nombres = @{}
      foreach ($t in @(try { Get-MpThreat -ErrorAction Stop } catch { })) { $nombres["$($t.ThreatID)"] = $t.ThreatName }
      "Microsoft Defender detectó $($det.Count) amenaza(s) en los últimos 30 días. Las más recientes:"
      foreach ($d in ($det | Select-Object -First 7)) {
        $cuando = ([datetime]$d.InitialDetectionTime).ToString('dd/MM HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        $archivo = Archivo (@($d.Resources)[0])
        $que = $ACCION[[int]$d.ThreatStatusID]; if (-not $que) { $que = 'sin datos de qué hizo' }
        "- ${cuando}: $($nombres["$($d.ThreatID)"])$(if ($archivo) { " en «$archivo»" }): $que."
      }
      'No abras esos archivos. Si falta un archivo tuyo que necesitas, soporte decide si se puede sacar de la cuarentena.'
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
