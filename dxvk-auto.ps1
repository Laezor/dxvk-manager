<#
.SYNOPSIS
  Detects the DirectX version and bitness of an executable,
  then places the appropriate DXVK DLL(s) into the application folder,
  based on the architecture subfolder in the dxvk-[version] folder.

.PARAMETER exePath
  Full path to the target executable.

.NOTES
  Ensure the DXVK DLLs are organized in a folder structure.
  For example, if a folder named "dxvk-2.5.3" (or any dxvk-[version]) exists in the script folder,
  it should contain:

    <ScriptFolder>\dxvk-[version]\x32\
      d3d8.dll, d3d9.dll, d3d10core.dll, d3d11.dll, dxgi.dll

    <ScriptFolder>\dxvk-[version]\x64\
      d3d8.dll, d3d9.dll, d3d10core.dll, d3d11.dll, dxgi.dll

  Note: DXVK does not support DirectX 12; if d3d12.dll is detected, the script will exit.
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$exePath
)

# Ensure the exe exists.
if (-not (Test-Path $exePath)) {
    Write-Error "The specified file '$exePath' does not exist."
    exit
}

# Function to detect whether a PE file is 32-bit or 64-bit.
function Get-PEBitness {
    param (
       [string]$FilePath
    )
    $fs = [System.IO.File]::OpenRead($FilePath)
    $br = New-Object System.IO.BinaryReader($fs)
    
    # Check for "MZ" signature
    $mz = $br.ReadBytes(2)
    if ([System.Text.Encoding]::ASCII.GetString($mz) -ne "MZ") {
         throw "Not a valid PE file."
    }
    
    # Locate PE header offset
    $fs.Seek(0x3C, [System.IO.SeekOrigin]::Begin) | Out-Null
    $peHeaderOffset = $br.ReadInt32()
    $fs.Seek($peHeaderOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
    
    # Read and validate the PE signature ("PE\0\0")
    $peSignature = $br.ReadBytes(4)
    if (!($peSignature[0] -eq 80 -and $peSignature[1] -eq 69 -and $peSignature[2] -eq 0 -and $peSignature[3] -eq 0)) {
         throw "Not a valid PE file."
    }
    
    # Skip over FileHeader (20 bytes) to the start of the Optional Header.
    $fs.Seek(20, [System.IO.SeekOrigin]::Current) | Out-Null
    $magic = $br.ReadUInt16()
    $fs.Close()
    
    # 0x10B = PE32 (32-bit), 0x20B = PE32+ (64-bit)
    if ($magic -eq 0x10B) {
       return 32
    } elseif ($magic -eq 0x20B) {
       return 64
    } else {
       throw "Unknown PE format."
    }
}

# Detect the application bitness.
try {
    $bitness = Get-PEBitness -FilePath $exePath
    Write-Output "Detected application bitness: $bitness-bit"
} catch {
    Write-Error $_.Exception.Message
    exit
}

# Read the executable’s bytes and convert to an ASCII string.
$bytes = [System.IO.File]::ReadAllBytes($exePath)
$content = [System.Text.Encoding]::ASCII.GetString($bytes)

# Auto-detect DirectX version by checking for common DirectX DLL names.
$dxVersion = $null
if ($content -match "d3d11\.dll") {
    $dxVersion = 11
} elseif ($content -match "d3d10\.dll") {
    $dxVersion = 10
} elseif ($content -match "d3d9\.dll") {
    $dxVersion = 9
} elseif ($content -match "d3d8\.dll") {
    $dxVersion = 8
} else {
    Write-Output "Could not detect any DirectX dependency in the executable."
    exit
}
Write-Output "Detected DirectX version: $dxVersion"

# DXVK currently does not support DirectX 12.
if ($dxVersion -eq 12) {
    Write-Output "DirectX 12 is not supported by DXVK."
    exit
}

# Determine the script folder.
$scriptFolder = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Search for a folder that matches the pattern "dxvk-[version]"
$dxvkFolders = Get-ChildItem -Path $scriptFolder -Directory | Where-Object { $_.Name -match "^dxvk-\d+(\.\d+)*$" }
if (-not $dxvkFolders) {
    Write-Error "No DXVK folder matching the pattern 'dxvk-[version]' was found in $scriptFolder"
    exit
}

# Select the first matching folder (adjust as needed if multiple exist).
$baseDXVKFolder = $dxvkFolders[0].FullName
Write-Output "Using DXVK folder: $($dxvkFolders[0].Name)"

# Choose the subfolder based on bitness (using x64 for 64-bit and x32 for 32-bit).
if ($bitness -eq 64) {
    $archFolder = "x64"
} else {
    $archFolder = "x32"
}

# Full folder path that contains the appropriate DXVK DLLs.
$dxvkFolder = Join-Path $baseDXVKFolder $archFolder

# Map the detected DirectX version to the corresponding DLL base name for single file copies.
switch ($dxVersion) {
    8  { $dxDllBase = "d3d8" }
    9  { $dxDllBase = "d3d9" }
    10 { $dxDllBase = "d3d10" }
    11 { $dxDllBase = "d3d11" }  # For DirectX 11, we will copy multiple files.
}

# Define the destination folder (the folder where the exe resides).
$destinationFolder = Split-Path $exePath

if ($dxVersion -eq 11) {
    # For DirectX 11, copy three DLL files: d3d10core.dll, d3d11.dll, dxgi.dll.
    $filesToCopy = @("d3d10core.dll", "d3d11.dll", "dxgi.dll")
    foreach ($file in $filesToCopy) {
        $sourceFile = Join-Path $dxvkFolder $file
        $destinationFile = Join-Path $destinationFolder $file
        if (-not (Test-Path $sourceFile)) {
            Write-Error "Source DXVK DLL not found: $sourceFile"
            exit
        }
        Copy-Item -Path $sourceFile -Destination $destinationFile -Force
        Write-Output "Successfully copied '$sourceFile' to '$destinationFile'."
    }
} else {
    # For other DirectX versions, copy the single DLL file.
    $sourceFile = Join-Path $dxvkFolder ("$dxDllBase.dll")
    $destinationFile = Join-Path $destinationFolder ("$dxDllBase.dll")
    Write-Output "Destination: $destinationFile"
    if (-not (Test-Path $sourceFile)) {
        Write-Error "Source DXVK DLL not found: $sourceFile"
        exit
    }
    Copy-Item -Path $sourceFile -Destination $destinationFile -Force
    Write-Output "Successfully copied '$sourceFile' to '$destinationFile'."
}
