# Win32 access to displays and to DDC/CI, the I2C side channel in the video
# cable through which a monitor accepts VESA MCCS "VCP" feature commands.
# Mechanism only: argument parsing and percent arithmetic live in Logic.ps1.

Set-StrictMode -Version 3.0

# DDC/CI is a slow I2C link and a single transfer occasionally fails (no reply,
# bad checksum); a short retry makes one-shot commands reliable.
$script:DdcAttempts = 3
$script:DdcRetryDelayMs = 50

if (-not ('MonitorBrightness.Win32' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace MonitorBrightness
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PhysicalMonitor
    {
        public IntPtr Handle;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Description;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MonitorInfoEx
    {
        public int Size;
        public Rect Monitor;
        public Rect WorkArea;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DisplayDevice
    {
        public int Size;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceId;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceKey;
    }

    public static class Win32
    {
        private const uint MonitorInfoPrimary = 0x1;     // MONITORINFOF_PRIMARY
        private const uint DisplayDeviceActive = 0x1;    // DISPLAY_DEVICE_ACTIVE
        private const uint GetDeviceInterfaceName = 0x1; // EDD_GET_DEVICE_INTERFACE_NAME

        private delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data);

        [DllImport("user32.dll")]
        private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc callback, IntPtr data);

        [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool NativeGetMonitorInfo(IntPtr monitor, ref MonitorInfoEx info);

        [DllImport("user32.dll", EntryPoint = "EnumDisplayDevicesW", CharSet = CharSet.Unicode)]
        private static extern bool NativeEnumDisplayDevices(string device, uint index, ref DisplayDevice info, uint flags);

        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();

        [DllImport("dxva2.dll", SetLastError = true)]
        private static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr monitor, out uint count);

        [DllImport("dxva2.dll", SetLastError = true)]
        private static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr monitor, uint count, [Out] PhysicalMonitor[] monitors);

        [DllImport("dxva2.dll", SetLastError = true)]
        private static extern bool DestroyPhysicalMonitor(IntPtr handle);

        [DllImport("dxva2.dll", SetLastError = true)]
        private static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr handle, byte code, out int codeType, out uint current, out uint maximum);

        [DllImport("dxva2.dll", SetLastError = true)]
        private static extern bool SetVCPFeature(IntPtr handle, byte code, uint value);

        // Without this, Windows scales monitor coordinates for a DPI-unaware
        // process and the identify overlay lands in the wrong place.
        public static void EnableDpiAwareness()
        {
            SetProcessDPIAware();
        }

        public static IntPtr[] GetDisplayMonitors()
        {
            var monitors = new List<IntPtr>();
            MonitorEnumProc callback = (monitor, hdc, rect, data) => { monitors.Add(monitor); return true; };
            bool ok = EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero);
            GC.KeepAlive(callback);
            if (!ok)
                throw new InvalidOperationException("EnumDisplayMonitors failed");
            return monitors.ToArray();
        }

        public static MonitorInfoEx GetMonitorInfo(IntPtr monitor)
        {
            var info = new MonitorInfoEx();
            info.Size = Marshal.SizeOf(typeof(MonitorInfoEx));
            if (!NativeGetMonitorInfo(monitor, ref info))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "GetMonitorInfo failed");
            return info;
        }

        public static bool IsPrimary(MonitorInfoEx info)
        {
            return (info.Flags & MonitorInfoPrimary) != 0;
        }

        // Device interface paths of the active monitors on one display output.
        public static string[] GetActiveMonitorInterfaceIds(string displayName)
        {
            var ids = new List<string>();
            for (uint index = 0; ; index++)
            {
                var device = new DisplayDevice();
                device.Size = Marshal.SizeOf(typeof(DisplayDevice));
                if (!NativeEnumDisplayDevices(displayName, index, ref device, GetDeviceInterfaceName))
                    break;
                if ((device.StateFlags & DisplayDeviceActive) != 0)
                    ids.Add(device.DeviceId);
            }
            return ids.ToArray();
        }

        // Empty when Windows exposes no DDC/CI handle for the display.
        public static PhysicalMonitor[] OpenPhysicalMonitors(IntPtr monitor)
        {
            uint count;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, out count) || count == 0)
                return new PhysicalMonitor[0];
            var monitors = new PhysicalMonitor[count];
            if (!GetPhysicalMonitorsFromHMONITOR(monitor, count, monitors))
                return new PhysicalMonitor[0];
            return monitors;
        }

        public static void ClosePhysicalMonitor(IntPtr handle)
        {
            if (handle != IntPtr.Zero)
                DestroyPhysicalMonitor(handle);
        }

        // The error code is captured here, right after the call: back in
        // PowerShell other P/Invokes may already have overwritten it.
        public static bool TryGetVcpFeature(IntPtr handle, byte code, out uint current, out uint maximum, out int error)
        {
            int codeType;
            bool ok = GetVCPFeatureAndVCPFeatureReply(handle, code, out codeType, out current, out maximum);
            error = ok ? 0 : Marshal.GetLastWin32Error();
            return ok;
        }

        public static bool TrySetVcpFeature(IntPtr handle, byte code, uint value, out int error)
        {
            bool ok = SetVCPFeature(handle, code, value);
            error = ok ? 0 : Marshal.GetLastWin32Error();
            return ok;
        }
    }
}
'@
}

function Get-MonitorIdentityTable {
    <#
    .SYNOPSIS
        Reads each monitor's EDID identity from WMI, keyed by PnP instance path.
    #>
    $table = @{}
    foreach ($id in Get-CimInstance -Namespace 'root\wmi' -ClassName 'WmiMonitorID' -ErrorAction Stop) {
        $table[(ConvertFrom-WmiInstanceName -InstanceName $id.InstanceName)] = [pscustomobject]@{
            Manufacturer = ConvertFrom-EdidString -Codes $id.ManufacturerName
            Model        = ConvertFrom-EdidString -Codes $id.UserFriendlyName
            Serial       = ConvertFrom-EdidString -Codes $id.SerialNumberID
        }
    }
    $table
}

function Open-Monitor {
    <#
    .SYNOPSIS
        Enumerates the displays and opens a DDC/CI handle to each physical monitor.
    .DESCRIPTION
        Returns one record per physical monitor, numbered left to right. The
        records own native handles: pass them to Close-Monitor when done. A
        display Windows exposes no DDC/CI handle for gets Handle = IntPtr.Zero.
    .PARAMETER Identities
        EDID identities keyed by PnP instance path (Get-MonitorIdentityTable);
        monitors missing from it fall back to the driver's description.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Identities)

    [MonitorBrightness.Win32]::EnableDpiAwareness()
    $records = foreach ($hMonitor in [MonitorBrightness.Win32]::GetDisplayMonitors()) {
        $info = [MonitorBrightness.Win32]::GetMonitorInfo($hMonitor)
        $interfaceIds = @([MonitorBrightness.Win32]::GetActiveMonitorInterfaceIds($info.DeviceName))
        $physical = @([MonitorBrightness.Win32]::OpenPhysicalMonitors($hMonitor))

        # Physical monitors and interface IDs are paired by position. Each
        # output drives one monitor except in clone mode, where the pairing
        # is not guaranteed by the API.
        for ($i = 0; $i -lt [Math]::Max($physical.Count, 1); $i++) {
            $identity = $null
            if ($i -lt $interfaceIds.Count) {
                $instancePath = ConvertFrom-DeviceInterfaceId -InterfaceId $interfaceIds[$i]
                if ($instancePath) {
                    $identity = $Identities[$instancePath]
                }
            }
            $hasHandle = $i -lt $physical.Count
            $description = if ($hasHandle) { $physical[$i].Description } else { '' }

            [pscustomobject]@{
                Index        = 0
                DisplayName  = $info.DeviceName
                IsPrimary    = [MonitorBrightness.Win32]::IsPrimary($info)
                Left         = $info.Monitor.Left
                Top          = $info.Monitor.Top
                Width        = $info.Monitor.Right - $info.Monitor.Left
                Height       = $info.Monitor.Bottom - $info.Monitor.Top
                Manufacturer = if ($identity) { $identity.Manufacturer } else { '' }
                Model        = if ($identity -and $identity.Model) { $identity.Model }
                               elseif ($description) { $description } else { 'unknown' }
                Serial       = if ($identity) { $identity.Serial } else { '' }
                Handle       = if ($hasHandle) { $physical[$i].Handle } else { [IntPtr]::Zero }
            }
        }
    }

    $index = 0
    @($records | Sort-Object Left, Top | ForEach-Object { $index++; $_.Index = $index; $_ })
}

function Close-Monitor {
    <#
    .SYNOPSIS
        Releases the DDC/CI handles held by records from Open-Monitor.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Monitors)

    foreach ($monitor in $Monitors) {
        [MonitorBrightness.Win32]::ClosePhysicalMonitor($monitor.Handle)
    }
}

function New-DdcException {
    param([string]$Operation, [int]$ErrorCode)

    $reason = if ($ErrorCode -ne 0) {
        ([System.ComponentModel.Win32Exception]::new($ErrorCode)).Message
    } else {
        'the monitor did not reply'
    }
    [System.IO.IOException]::new("$Operation failed after $script:DdcAttempts attempts: $reason")
}

function Read-VcpFeature {
    <#
    .SYNOPSIS
        Reads a VCP feature's current and maximum value, retrying transient failures.
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$Handle,
        [Parameter(Mandatory)][byte]$Code
    )

    $current = [uint32]0
    $maximum = [uint32]0
    $errorCode = 0
    for ($attempt = 1; $attempt -le $script:DdcAttempts; $attempt++) {
        if ([MonitorBrightness.Win32]::TryGetVcpFeature($Handle, $Code, [ref]$current, [ref]$maximum, [ref]$errorCode)) {
            return [pscustomobject]@{ Current = [int]$current; Maximum = [int]$maximum }
        }
        Start-Sleep -Milliseconds $script:DdcRetryDelayMs
    }
    throw (New-DdcException -Operation ('reading VCP 0x{0:X2}' -f $Code) -ErrorCode $errorCode)
}

function Write-VcpFeature {
    <#
    .SYNOPSIS
        Writes a VCP feature value, retrying transient failures.
    #>
    param(
        [Parameter(Mandatory)][IntPtr]$Handle,
        [Parameter(Mandatory)][byte]$Code,
        [Parameter(Mandatory)][int]$Value
    )

    $errorCode = 0
    for ($attempt = 1; $attempt -le $script:DdcAttempts; $attempt++) {
        if ([MonitorBrightness.Win32]::TrySetVcpFeature($Handle, $Code, [uint32]$Value, [ref]$errorCode)) {
            return
        }
        Start-Sleep -Milliseconds $script:DdcRetryDelayMs
    }
    throw (New-DdcException -Operation ('writing VCP 0x{0:X2}' -f $Code) -ErrorCode $errorCode)
}
