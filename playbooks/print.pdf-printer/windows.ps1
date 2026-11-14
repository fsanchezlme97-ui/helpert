# Recuperar la impresora PDF: vuelve a activar la función de Windows «Microsoft Print to PDF»
# (Printing-PrintToPDFServices-Features) y, si la función ya estaba activa pero falta la impresora, la vuelve a crear
# con su controlador y su puerto de siempre (PORTPROMPT:, que pregunta dónde guardar).
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$NOMBRE = 'Microsoft Print to PDF'
$CONTROLADOR = 'Microsoft Print To PDF'
$FUNCION = 'Printing-PrintToPDFServices-Features'

function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Activo { (Get-Service Spooler -ErrorAction SilentlyContinue).Status -eq 'Running' }
function Hay { @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $NOMBRE }).Count -gt 0 }
function Estado { try { "$((Get-WindowsOptionalFeature -Online -FeatureName $FUNCION -ErrorAction Stop).State)" } catch { '' } }
function Activar { (Enable-WindowsOptionalFeature -Online -FeatureName $FUNCION -All -NoRestart -ErrorAction Stop).RestartNeeded }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      if (-not (Activo)) { 'El servicio de impresión está detenido: usa primero «Liberar cola de impresión».'; exit 1 }
      if (Hay) { "La impresora «$NOMBRE» ya está instalada: al imprimir, elígela en la lista de impresoras. Si no la ves, cierra y abre el programa."; exit 10 }
      $e = Estado
      if (-not $e) { 'Este equipo no tiene la función de imprimir a PDF de Windows (o necesito privilegios de administrador para verla).'; exit 1 }
      if ($e -eq 'Enabled') { "La función de imprimir a PDF está activa, pero falta la impresora «$NOMBRE»: la vuelvo a instalar." }
      else { "La función de imprimir a PDF está desactivada: la vuelvo a activar." }
      exit 0
    }
    'comprobar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para activar la impresora PDF.'; exit 3 }
      if (-not (Activo)) { 'El servicio de impresión está detenido: usa primero «Liberar cola de impresión».'; exit 3 }
      if (-not (Estado)) { 'Este equipo no tiene la función de imprimir a PDF de Windows.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $reiniciar = $false
      try {
        if ((Estado) -ne 'Enabled') { $reiniciar = Activar; Start-Sleep -Seconds 3 }
        if (-not (Hay)) {
          if (Get-PrinterDriver -Name $CONTROLADOR -ErrorAction SilentlyContinue) {
            Add-Printer -Name $NOMBRE -DriverName $CONTROLADOR -PortName 'PORTPROMPT:'
          } else {
            # el controlador se perdió: desactivar y volver a activar la función lo reinstala
            $null = Disable-WindowsOptionalFeature -Online -FeatureName $FUNCION -NoRestart -ErrorAction Stop
            $reiniciar = (Activar) -or $reiniciar
            Start-Sleep -Seconds 3
          }
        }
      } catch {
        'No pude activar la impresora PDF: Windows no encontró sus archivos. Pide a soporte que la reinstale.'; exit 1
      }
      "Volví a activar la impresora «$NOMBRE»."
      if ($reiniciar) { 'Windows pide reiniciar el equipo para terminar: guarda tu trabajo y reinícialo cuando puedas.' }
      exit 0
    }
    'verificar' {
      if (-not (Hay)) { "La impresora «$NOMBRE» todavía no aparece: reinicia el equipo; si sigue sin aparecer, avisa a soporte."; exit 1 }
      "La impresora «$NOMBRE» está instalada. Cierra y abre el programa, y elígela al imprimir."
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
