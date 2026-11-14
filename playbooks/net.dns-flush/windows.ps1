# Limpiar la caché de nombres (DNS) de Windows (servicio Cliente DNS). No reinicia la red.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Servicio { (Get-Service Dnscache -ErrorAction SilentlyContinue).Status -eq 'Running' }
function DnsOk { try { $null = Resolve-DnsName example.com -QuickTimeout -ErrorAction Stop; $true } catch { $false } }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      if (-not (Servicio)) { 'El servicio de caché de nombres de Windows (Cliente DNS) está detenido, así que no hay caché que borrar. Si las páginas no abren, avisa a soporte.'; exit 10 }
      $n = @(Get-DnsClientCache -ErrorAction SilentlyContinue).Count
      "Puedo borrar la caché de nombres del equipo (tiene $n nombres guardados)."
      'Así el equipo vuelve a preguntar la dirección de cada página o sistema. No corta la red.'
      exit 0
    }
    'comprobar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para borrar la caché de nombres.'; exit 3 }
      if (-not (Servicio)) { 'El servicio de caché de nombres de Windows está detenido: no hay caché que borrar.'; exit 3 }
      exit 0
    }
    'aplicar' {
      try { Clear-DnsClientCache } catch { 'No pude borrar la caché de nombres.'; exit 1 }
      'Borré la caché de nombres. Cierra y vuelve a abrir el navegador para que también olvide las direcciones viejas.'
      exit 0
    }
    'verificar' {
      if (-not (DnsOk)) { 'Borré la caché, pero los nombres de dominio no se resuelven: prueba «Sin internet o Wi-Fi».'; exit 1 }
      'La caché de nombres está limpia y el equipo resuelve bien los nombres de dominio.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
