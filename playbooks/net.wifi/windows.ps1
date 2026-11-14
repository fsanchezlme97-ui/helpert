# Reconectar el Wi-Fi: arranca el servicio de Wi-Fi (WLAN AutoConfig), activa la tarjeta si está desactivada,
# enciende su radio y la conecta a una red guardada. La radio y las redes se leen con la API de WLAN (wlanapi.dll),
# que funciona desde el servicio y no depende del idioma, en vez de leer textos de netsh.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

function Tarjeta { Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.NdisPhysicalMedium -eq 9 } | Select-Object -First 1 }  # 9 = 802.11
function Conectada($t) { $t -and (Get-NetAdapter -InterfaceIndex $t.ifIndex).Status -eq 'Up' }
function Red($t) { (Get-NetConnectionProfile -InterfaceIndex $t.ifIndex -ErrorAction SilentlyContinue | Select-Object -First 1).Name }
function Wlan {
  if ('HpWlan' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class HpWlan {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct Parametros { public int modo; [MarshalAs(UnmanagedType.LPWStr)] public string perfil; public IntPtr ssid, bssids; public int tipo, opciones; }
  [DllImport("wlanapi.dll")] static extern int WlanOpenHandle(uint v, IntPtr r, out uint neg, out IntPtr h);
  [DllImport("wlanapi.dll")] static extern int WlanCloseHandle(IntPtr h, IntPtr r);
  [DllImport("wlanapi.dll")] static extern void WlanFreeMemory(IntPtr p);
  [DllImport("wlanapi.dll")] static extern int WlanQueryInterface(IntPtr h, ref Guid g, int op, IntPtr r, out int n, out IntPtr d, IntPtr t);
  [DllImport("wlanapi.dll")] static extern int WlanSetInterface(IntPtr h, ref Guid g, int op, int n, IntPtr d, IntPtr r);
  [DllImport("wlanapi.dll")] static extern int WlanGetProfileList(IntPtr h, ref Guid g, IntPtr r, out IntPtr d);
  [DllImport("wlanapi.dll")] static extern int WlanConnect(IntPtr h, ref Guid g, ref Parametros p, IntPtr r);
  static IntPtr Abrir() { uint n; IntPtr h; if (WlanOpenHandle(2, IntPtr.Zero, out n, out h) != 0) throw new Exception("El servicio de Wi-Fi no responde."); return h; }
  // 1 = encendida, 2 = apagada, 3 = apagada con el interruptor o la tecla del equipo, 0 = no se sabe
  public static int Radio(Guid g) {
    IntPtr h = Abrir(), d; int n, r = 0;
    try {
      if (WlanQueryInterface(h, ref g, 4, IntPtr.Zero, out n, out d, IntPtr.Zero) != 0) return 0;
      int fases = Marshal.ReadInt32(d);
      for (int i = 0; i < fases; i++) {
        int sw = Marshal.ReadInt32(d, 8 + i * 12), hw = Marshal.ReadInt32(d, 12 + i * 12);
        if (hw == 2) r = 3; else if (sw == 2 && r != 3) r = 2; else if (sw == 1 && r == 0) r = 1;
      }
      WlanFreeMemory(d); return r;
    } finally { WlanCloseHandle(h, IntPtr.Zero); }
  }
  public static void Encender(Guid g) {
    IntPtr h = Abrir(), d; int n;
    try {
      if (WlanQueryInterface(h, ref g, 4, IntPtr.Zero, out n, out d, IntPtr.Zero) != 0) return;
      int fases = Marshal.ReadInt32(d); WlanFreeMemory(d);
      IntPtr e = Marshal.AllocHGlobal(12);
      try {
        for (int i = 0; i < fases; i++) {
          Marshal.WriteInt32(e, 0, i); Marshal.WriteInt32(e, 4, 1); Marshal.WriteInt32(e, 8, 1);
          WlanSetInterface(h, ref g, 4, 12, e, IntPtr.Zero);
        }
      } finally { Marshal.FreeHGlobal(e); }
    } finally { WlanCloseHandle(h, IntPtr.Zero); }
  }
  // redes guardadas de la tarjeta, en el orden de preferencia de Windows
  public static string[] Perfiles(Guid g) {
    IntPtr h = Abrir(), d; var l = new List<string>();
    try {
      if (WlanGetProfileList(h, ref g, IntPtr.Zero, out d) != 0) return l.ToArray();
      int n = Marshal.ReadInt32(d);
      for (int i = 0; i < n; i++) l.Add(Marshal.PtrToStringUni(new IntPtr(d.ToInt64() + 8 + i * 516)));
      WlanFreeMemory(d); return l.ToArray();
    } finally { WlanCloseHandle(h, IntPtr.Zero); }
  }
  public static int Conectar(Guid g, string perfil) {
    IntPtr h = Abrir();
    try { var p = new Parametros { modo = 0, perfil = perfil, tipo = 1 }; return WlanConnect(h, ref g, ref p, IntPtr.Zero); }
    finally { WlanCloseHandle(h, IntPtr.Zero); }
  }
}
'@
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $t = Tarjeta
      if (-not $t) { 'No encontré una tarjeta Wi-Fi en este equipo.'; exit 1 }
      if (Conectada $t) { "El Wi-Fi está conectado a «$(Red $t)»."; exit 10 }
      if ((Get-Service WlanSvc).Status -ne 'Running') { 'El servicio de Wi-Fi de Windows está detenido.'; exit 0 }
      if ($t.Status -eq 'Disabled') { 'La tarjeta Wi-Fi está desactivada.'; exit 0 }
      Wlan
      $g = [Guid]$t.InterfaceGuid
      $r = [HpWlan]::Radio($g)
      if ($r -eq 3) { 'El Wi-Fi está apagado con el interruptor o la tecla del equipo (a veces la del avión): enciéndelo ahí, que yo no puedo.'; exit 1 }
      if ($r -eq 2) { 'El Wi-Fi está apagado (o el equipo está en modo avión).' }
      'La tarjeta Wi-Fi no está conectada a ninguna red.'
      if (@([HpWlan]::Perfiles($g)).Count -eq 0) { 'El equipo no tiene redes Wi-Fi guardadas: hace falta elegir la red y escribir su contraseña.'; exit 10 }
      exit 0
    }
    'comprobar' {
      $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
      if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Helpert necesita privilegios de administrador para encender el Wi-Fi.'; exit 3 }
      if (-not (Tarjeta)) { 'No encontré una tarjeta Wi-Fi.'; exit 3 }
      exit 0
    }
    'aplicar' {
      if ((Get-Service WlanSvc).Status -ne 'Running') { Start-Service WlanSvc; Start-Sleep -Seconds 2 }
      $t = Tarjeta
      if ($t.Status -eq 'Disabled') { Enable-NetAdapter -Name $t.Name -Confirm:$false; Start-Sleep -Seconds 3; $t = Tarjeta }
      Wlan
      $g = [Guid]$t.InterfaceGuid
      if ([HpWlan]::Radio($g) -ne 1) { [HpWlan]::Encender($g); Start-Sleep -Seconds 3 }
      if ([HpWlan]::Radio($g) -ne 1) { 'No pude encender el Wi-Fi: enciéndelo en el icono de red de la barra de tareas o con la tecla del equipo.'; exit 1 }
      # Windows se conecta solo a una red guardada; si no lo hace, se le pide cada una por orden
      # (las 3 primeras, para no pasarse del tiempo límite)
      for ($i = 0; $i -lt 10 -and -not (Conectada $t); $i++) { Start-Sleep -Seconds 1 }
      foreach ($p in @([HpWlan]::Perfiles($g) | Select-Object -First 3)) {
        if (Conectada $t) { break }
        if ([HpWlan]::Conectar($g, $p) -ne 0) { continue }
        for ($i = 0; $i -lt 6 -and -not (Conectada $t); $i++) { Start-Sleep -Seconds 1 }
      }
      'Encendí el Wi-Fi y le pedí conectarse a una red guardada.'
      exit 0
    }
    'verificar' {
      $t = Tarjeta
      for ($i = 0; $i -lt 5 -and -not (Conectada $t); $i++) { Start-Sleep -Seconds 1 }
      if (-not (Conectada $t)) { 'El Wi-Fi está encendido, pero no se conectó a ninguna red guardada.'; exit 1 }
      "El Wi-Fi está conectado a «$(Red $t)»."
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
