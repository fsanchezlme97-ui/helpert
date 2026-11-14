# Revisar la señal del Wi-Fi: calidad de señal (%), banda y canal de la red conectada y cuántas redes más comparten ese
# canal. Se lee con la API de WLAN (wlanapi.dll), que funciona desde el servicio y no depende del idioma, en vez de
# leer textos de netsh. Usa la última búsqueda de redes de Windows, sin volver a buscar. Solo revisa: termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

function Tarjeta { Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.NdisPhysicalMedium -eq 9 } | Select-Object -First 1 }  # 9 = 802.11
function Wlan {
  if ('HpSenal' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class HpSenal {
  [DllImport("wlanapi.dll")] static extern int WlanOpenHandle(uint v, IntPtr r, out uint neg, out IntPtr h);
  [DllImport("wlanapi.dll")] static extern int WlanCloseHandle(IntPtr h, IntPtr r);
  [DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr p);
  [DllImport("wlanapi.dll")] static extern int WlanQueryInterface(IntPtr h, ref Guid g, int op, IntPtr r, out int n, out IntPtr d, IntPtr t);
  [DllImport("wlanapi.dll")] static extern int WlanGetNetworkBssList(IntPtr h, ref Guid g, IntPtr ssid, int tipo, bool seguridad, IntPtr r, out IntPtr d);
  // { calidad %, MHz (0 si no se sabe), redes en la misma frecuencia }, o null si no está conectada. SSID aparte.
  public static int[] Leer(Guid g, out string ssid) {
    uint v; IntPtr h, d; int n; ssid = "";
    if (WlanOpenHandle(2, IntPtr.Zero, out v, out h) != 0) return null;
    try {
      // 7 = conexión actual (WLAN_CONNECTION_ATTRIBUTES): estado en 0 (1 = conectada), SSID en 520 (largo + 32 bytes),
      // BSSID en 560 (6 bytes), calidad de señal en 576
      if (WlanQueryInterface(h, ref g, 7, IntPtr.Zero, out n, out d, IntPtr.Zero) != 0) return null;
      byte[] bssid = new byte[6]; int calidad;
      try {
        if (Marshal.ReadInt32(d) != 1) return null;
        int largo = Math.Min(Marshal.ReadInt32(d, 520), 32);
        byte[] s = new byte[largo]; Marshal.Copy(new IntPtr(d.ToInt64() + 524), s, 0, largo);
        ssid = Encoding.UTF8.GetString(s);
        Marshal.Copy(new IntPtr(d.ToInt64() + 560), bssid, 0, 6);
        calidad = Marshal.ReadInt32(d, 576);
      } finally { WlanFreeMemory(d); }
      // redes vistas (WLAN_BSS_LIST: cantidad en 4, entradas de 360 bytes desde 8; en cada una, BSSID en 40 y
      // frecuencia central en kHz en 92)
      int mhz = 0, iguales = 0;
      if (WlanGetNetworkBssList(h, ref g, IntPtr.Zero, 3, false, IntPtr.Zero, out d) == 0) {
        try {
          int total = Marshal.ReadInt32(d, 4); int[] f = new int[total]; byte[] b = new byte[6];
          for (int i = 0; i < total; i++) {
            IntPtr e = new IntPtr(d.ToInt64() + 8 + i * 360);
            f[i] = Marshal.ReadInt32(e, 92) / 1000;
            Marshal.Copy(new IntPtr(e.ToInt64() + 40), b, 0, 6);
            bool mia = true; for (int k = 0; k < 6; k++) if (b[k] != bssid[k]) mia = false;
            if (mia) { mhz = f[i]; f[i] = -1; }
          }
          if (mhz > 0) foreach (int x in f) if (x == mhz) iguales++;
        } finally { WlanFreeMemory(d); }
      }
      return new int[] { calidad, mhz, iguales };
    } finally { WlanCloseHandle(h, IntPtr.Zero); }
  }
}
'@
}
function Canal($mhz) {
  if ($mhz -eq 2484) { return 14 }
  if ($mhz -ge 5925) { return [int](($mhz - 5950) / 5) }
  if ($mhz -ge 4900) { return [int](($mhz - 5000) / 5) }
  [int](($mhz - 2407) / 5)
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $t = Tarjeta
      if (-not $t) { 'No encontré una tarjeta Wi-Fi en este equipo.'; exit 10 }
      if ((Get-Service WlanSvc -ErrorAction SilentlyContinue).Status -ne 'Running') { 'El servicio de Wi-Fi de Windows está detenido: para eso usa «Reconectar el Wi-Fi».'; exit 10 }
      Wlan
      $ssid = ''
      $r = [HpSenal]::Leer([Guid]$t.InterfaceGuid, [ref]$ssid)
      if (-not $r) { 'El Wi-Fi no está conectado a ninguna red: para eso usa «Reconectar el Wi-Fi».'; exit 10 }
      $senal = $r[0]; $mhz = $r[1]; $otras = $r[2]
      if ($senal -ge 70) { "La señal del Wi-Fi es buena ($senal %) en la red «$ssid»." }
      elseif ($senal -ge 40) { "La señal del Wi-Fi es regular ($senal %) en la red «$ssid»: acercarte al router o quitar obstáculos (paredes, muebles metálicos) ayudaría." }
      else { "La señal del Wi-Fi es débil ($senal %) en la red «$ssid»: por eso puede ir lento o cortarse. Acércate al router o, si puedes, usa un cable." }
      if ($mhz -gt 0) {
        $c = Canal $mhz
        if ($mhz -ge 5925) { "Estás en la banda de 6 GHz (canal $c): es la más rápida, pero la de menos alcance." }
        elseif ($mhz -ge 4900) { "Estás en la banda de 5 GHz (canal $c): es rápida, pero atraviesa peor las paredes que la de 2,4 GHz." }
        else { "Estás en la banda de 2,4 GHz (canal $c): llega más lejos, pero es más lenta y suele estar saturada. Si el router tiene una red de 5 GHz, úsala cuando estés cerca." }
        if ($otras -ge 4) { "Hay $otras redes más en el mismo canal: está saturado. Quien administra el router puede cambiarlo de canal." }
      }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
