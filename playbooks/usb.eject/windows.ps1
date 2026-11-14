# Expulsar una memoria USB o disco externo: dice qué programa la usa, escribe lo pendiente (Write-VolumeCache) y la
# expulsa como «Quitar hardware de forma segura» (CM_Request_Device_Eject, que funciona desde el servicio, a
# diferencia del menú «Expulsar» del Explorador). Nunca cierra programas. Solo discos USB, SD o MMC que no son los del
# sistema. «Qué programa la usa» son los que se abrieron desde la memoria o con un archivo de ella (su ruta en la
# línea de órdenes); si Windows se niega a expulsarla, el registro del sistema (Kernel-PnP 225) dice cuál fue.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
# el tipo de bus llega como nombre o como número según la versión
function Externos {
  @(Get-Disk -ErrorAction SilentlyContinue | Where-Object {
      @('USB', 'SD', 'MMC', '7', '12', '13') -contains "$($_.BusType)" -and -not $_.IsBoot -and -not $_.IsSystem })
}
function Letras($d) { @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Where-Object { [int]$_.DriveLetter -ne 0 } | ForEach-Object { "$($_.DriveLetter):" }) }
function Abiertos { @(Externos | Where-Object { @(Letras $_).Count -gt 0 }) }
function TodasLetras { @(Abiertos | ForEach-Object { Letras $_ }) }
function Usando($letras) {
  $u = foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
    $t = "$($p.ExecutablePath) $($p.CommandLine)".ToUpper()
    foreach ($l in $letras) { if ($t.Contains("$l\".ToUpper())) { $p.Name -replace '\.exe$', ''; break } }
  }
  @($u | Sort-Object -Unique)
}
# el programa que impidió la expulsión, según el aviso que deja Windows (la ruta del .exe está en el mensaje)
function Culpable($desde) {
  try {
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-PnP'; Id = 225; StartTime = $desde } -MaxEvents 3 -ErrorAction Stop)
    @($ev | ForEach-Object { if ($_.Message -match '([^\\\s]+)\.exe') { $Matches[1] } } | Sort-Object -Unique) -join ', '
  } catch { '' }
}
function Expulsar($d) {
  if (-not ('HpEject' -as [type])) {
    Add-Type -TypeDefinition 'using System; using System.Text; using System.Runtime.InteropServices; public static class HpEject { [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] public static extern int CM_Locate_DevNodeW(out uint nodo, string id, int f); [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode)] public static extern int CM_Request_Device_EjectW(uint nodo, out int veto, StringBuilder nombre, int largo, int f); }'
  }
  $id = (Get-CimInstance Win32_DiskDrive -Filter "Index = $([int]$d.Number)").PNPDeviceID
  if (-not $id) { return $false }
  # en las memorias USB lo que se expulsa es el dispositivo USB que contiene el disco
  $padre = $null
  try { $padre = (Get-PnpDeviceProperty -InstanceId $id -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data } catch { }
  if ("$padre" -like 'USB\*') { $id = $padre }
  $nodo = [uint32]0
  if ([HpEject]::CM_Locate_DevNodeW([ref]$nodo, $id, 0) -ne 0) { return $false }
  $veto = 0; $nombre = New-Object Text.StringBuilder 260
  ([HpEject]::CM_Request_Device_EjectW($nodo, [ref]$veto, $nombre, 260, 0) -eq 0) -and $veto -eq 0
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $l = @(TodasLetras)
      if ($l.Count -eq 0) {
        if (@(Externos).Count) { 'La memoria está conectada pero no está abierta: ya puedes desconectarla.' } else { 'No hay ninguna memoria USB ni disco externo conectado.' }
        exit 10
      }
      "Memoria abierta: $($l -join ', ')."
      $u = @(Usando $l)
      if ($u.Count) { "La está usando: $($u -join ', '). Guarda tu trabajo y cierra esos programas; después la expulso." }
      else { 'No veo programas que la estén usando: voy a terminar de guardar lo pendiente y expulsarla.' }
      exit 0
    }
    'comprobar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para expulsar la memoria.'; exit 3 }
      $l = @(TodasLetras)
      if ($l.Count -eq 0) { 'Ya no hay ninguna memoria abierta.'; exit 3 }
      $u = @(Usando $l)
      if ($u.Count) { "Todavía la está usando: $($u -join ', '). Guarda tu trabajo, cierra esos programas y vuelve a intentarlo."; exit 3 }
      exit 0
    }
    'aplicar' {
      $ds = @(Abiertos)
      if ($ds.Count -eq 0) { 'No había ninguna memoria abierta: ya puedes desconectarla.'; exit 0 }
      $desde = (Get-Date).AddSeconds(-5)
      $hechas = @()
      foreach ($d in $ds) {
        $l = @(Letras $d)
        foreach ($x in $l) { try { Write-VolumeCache -DriveLetter $x.Substring(0, 1) } catch { } }
        if (-not (Expulsar $d)) {
          $c = Culpable $desde
          if ($c) { "No pude expulsar $($l -join ', '): la está usando $c. Ciérralo y vuelve a intentarlo." }
          else { "No pude expulsar $($l -join ', '): algún programa la sigue usando. Cierra los que tengan archivos de ella abiertos y vuelve a intentarlo." }
          exit 1
        }
        $hechas += $l
      }
      "Guardé lo pendiente y expulsé $($hechas -join ', ')."
      exit 0
    }
    'verificar' {
      Start-Sleep -Seconds 2
      if (@(TodasLetras).Count) { 'La memoria sigue abierta: no la desconectes todavía.'; exit 1 }
      'Ya puedes desconectar la memoria con seguridad.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
