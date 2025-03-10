# Load required assemblies for Windows Forms and Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Global log textbox (will be created later) � used by Write-Log.
$global:logTextBox = $null

# Helper function to append messages to the log textbox.
function Write-Log {
    param([string]$message)
    if ($global:logTextBox -ne $null) {
        $global:logTextBox.AppendText("$message`r`n")
    }
    else {
        Write-Output $message
    }
}

# Function to detect whether a PE file is 32-bit or 64-bit.
function Get-PEBitness {
    param (
       [string]$FilePath
    )
    $fs = [System.IO.File]::OpenRead($FilePath)
    $br = New-Object System.IO.BinaryReader($fs)
    
    # Check for "MZ" signature.
    $mz = $br.ReadBytes(2)
    if ([System.Text.Encoding]::ASCII.GetString($mz) -ne "MZ") {
         throw "Not a valid PE file."
    }
    
    # Locate PE header offset.
    $fs.Seek(0x3C, [System.IO.SeekOrigin]::Begin) | Out-Null
    $peHeaderOffset = $br.ReadInt32()
    $fs.Seek($peHeaderOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
    
    # Read and validate the PE signature ("PE\0\0").
    $peSignature = $br.ReadBytes(4)
    if (!($peSignature[0] -eq 80 -and $peSignature[1] -eq 69 -and $peSignature[2] -eq 0 -and $peSignature[3] -eq 0)) {
         throw "Not a valid PE file."
    }
    
    # Skip FileHeader (20 bytes) to the start of the Optional Header.
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

# Function to install DXVK for a given executable.
# It detects the application's bitness and DirectX version, then copies:
#   - For DirectX 11: d3d10core.dll, d3d11.dll, dxgi.dll
#   - For other versions: a single DLL (d3d8.dll, d3d9.dll, or d3d10.dll)
function Install-DXVK {
    param(
        [string]$exePath
    )
    if (-not (Test-Path $exePath)) {
        Write-Log "Executable not found: $exePath"
        return
    }
    
    try {
        $bitness = Get-PEBitness -FilePath $exePath
        Write-Log "Detected application bitness: $bitness-bit"
    }
    catch {
        Write-Log "Error detecting bitness: $_"
        return
    }
    
    # Read the exe and detect DirectX version.
    $bytes = [System.IO.File]::ReadAllBytes($exePath)
    $content = [System.Text.Encoding]::ASCII.GetString($bytes)
    
    if ($content -match "d3d11\.dll") {
        $dxVersion = 11
    }
    elseif ($content -match "d3d10\.dll") {
        $dxVersion = 10
    }
    elseif ($content -match "d3d9\.dll") {
        $dxVersion = 9
    }
    elseif ($content -match "d3d8\.dll") {
        $dxVersion = 8
    }
    else {
        Write-Log "Could not detect any DirectX dependency in the executable. (Usually happens on unreal engine games)"
        return
    }
    Write-Log "Detected DirectX version: $dxVersion"
    
    if ($dxVersion -eq 12) {
        Write-Log "DirectX 12 is not supported by DXVK."
        return
    }
    
    # Determine the script folder.
    $scriptFolder = Split-Path -Parent Get-Location
    Write-Output $scriptFolder
    # Find a folder matching the pattern "dxvk-[version]" (e.g. dxvk-2.5.3, dxvk-3.1.0).
    $dxvkFolders = Get-ChildItem -Path $scriptFolder -Directory | Where-Object { $_.PSIsContainer -and $_.Name -match "^dxvk-\d+(\.\d+)*$" }
    if (-not $dxvkFolders) {
        Write-Log "No DXVK folder matching the pattern 'dxvk-[version]' was found in $scriptFolder"
        return
    }
    $baseDXVKFolder = $dxvkFolders[0].FullName
    Write-Log "Using DXVK folder: $($dxvkFolders[0].Name)"
    
    # Choose the architecture subfolder: x64 for 64-bit, x32 for 32-bit.
    if ($bitness -eq 64) {
        $archFolder = "x64"
    }
    else {
        $archFolder = "x32"
    }
    $dxvkFolder = Join-Path $baseDXVKFolder $archFolder
    
    # Map detected DirectX version to DLL base name.
    switch ($dxVersion) {
        8  { $dxDllBase = "d3d8" }
        9  { $dxDllBase = "d3d9" }
        10 { $dxDllBase = "d3d10" }
        11 { $dxDllBase = "d3d11" }  # For DX11 we'll copy three files.
    }
    
    $destinationFolder = Split-Path $exePath
    
    if ($dxVersion -eq 11) {
        # For DirectX 11, copy three DLL files.
        $filesToCopy = @("d3d10core.dll", "d3d11.dll", "dxgi.dll")
        foreach ($file in $filesToCopy) {
            $sourceFile = Join-Path $dxvkFolder $file
            $destinationFile = Join-Path $destinationFolder $file
            if (-not (Test-Path $sourceFile)) {
                Write-Log "Source file not found: $sourceFile"
                continue
            }
            Copy-Item -Path $sourceFile -Destination $destinationFile -Force
            Write-Log "Copied $sourceFile to $destinationFile"
        }
    }
    else {
        # For other DirectX versions, copy the single DLL file.
        $sourceFile = Join-Path $dxvkFolder ("$dxDllBase.dll")
        $destinationFile = Join-Path $destinationFolder ("$dxDllBase.dll")
        if (-not (Test-Path $sourceFile)) {
            Write-Log "Source file not found: $sourceFile"
            return
        }
        Copy-Item -Path $sourceFile -Destination $destinationFile -Force
        Write-Log "Copied $sourceFile to $destinationFile"
    }
}


# Function to remove DXVK DLLs from the game folder.
function Remove-DXVK {
    param([string]$gamePath)

    $dxvkFiles = @("d3d8.dll", "d3d9.dll", "d3d10.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll")

    foreach ($file in $dxvkFiles) {
        $targetFile = Join-Path $gamePath $file
        if (Test-Path $targetFile) {
            Remove-Item -Path $targetFile -Force
            Write-Log "Removed: $targetFile"
        }
    }
}

function Download-Dxvk {
    # Get the latest DXVK release from GitHub
    $LatestRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/doitsujin/dxvk/releases/latest"
    $Asset = $LatestRelease.assets | Select-Object -First 1
    
    # Download the release asset
    $downloadPath = Join-Path (Get-Location) $Asset.name
    Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $downloadPath
    Write-Log $Asset.name
    # Extract the archive to the current directory
    tar -xvzf $Asset.name -C .
    
    # Optionally, remove the downloaded archive after extraction
    Remove-Item -Path $downloadPath -Force
}


# -------------------
# Build the GUI
# -------------------

# Create the main form.
$form = New-Object System.Windows.Forms.Form
$form.Text = "DXVK Manager"
$form.Size = New-Object System.Drawing.Size(800,600)
$form.StartPosition = "CenterScreen"

# Label for Steam Library Path.
$lblLibrary = New-Object System.Windows.Forms.Label
$lblLibrary.Location = New-Object System.Drawing.Point(10,10)
$lblLibrary.Size = New-Object System.Drawing.Size(100,20)
$lblLibrary.Text = "Steam Library:"
$form.Controls.Add($lblLibrary)

# TextBox for Steam Library Path (defaulting to the typical Steam common folder).
$txtLibrary = New-Object System.Windows.Forms.TextBox
$txtLibrary.Location = New-Object System.Drawing.Point(120,10)
$txtLibrary.Size = New-Object System.Drawing.Size(500,20)
$txtLibrary.Text = "C:\Program Files (x86)\Steam\steamapps\common"
$form.Controls.Add($txtLibrary)

# Button to scan the library.
$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Location = New-Object System.Drawing.Point(630,10)
$btnScan.Size = New-Object System.Drawing.Size(140,20)
$btnScan.Text = "Scan Library"
$form.Controls.Add($btnScan)

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Location = New-Object System.Drawing.Point(160,350)
$btnRemove.Size = New-Object System.Drawing.Size(140,30)
$btnRemove.Text = "Remove DXVK"
$form.Controls.Add($btnRemove)

$btnDownload = New-Object System.Windows.Forms.Button
$btnDownload.Location = New-Object System.Drawing.Point(320,350)
$btnDownload.Size = New-Object System.Drawing.Size(140,30)
$btnDownload.Text = "Download DXVK"
$form.Controls.Add($btnDownload)

$btnDeveloper = New-Object System.Windows.Forms.Button
$btnDeveloper.Location = New-Object System.Drawing.Point(600,350)
$btnDeveloper.Size = New-Object System.Drawing.Size(140,30)
$btnDeveloper.Text = "Developer Info"
$form.Controls.Add($btnDeveloper)

# ListView to display found games.
$listView = New-Object System.Windows.Forms.ListView
$listView.Location = New-Object System.Drawing.Point(10,40)
$listView.Size = New-Object System.Drawing.Size(760,300)
$listView.View = "Details"
$listView.CheckBoxes = $true
$listView.FullRowSelect = $true
$listView.GridLines = $true
$listView.Columns.Add("Game Name",150)
$listView.Columns.Add("Path",600)
$form.Controls.Add($listView)

# Button to install DXVK into selected games.
$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Location = New-Object System.Drawing.Point(10,350)
$btnInstall.Size = New-Object System.Drawing.Size(140,30)
$btnInstall.Text = "Install DXVK"
$form.Controls.Add($btnInstall)

# Multi-line TextBox for log output.
$logTextBox = New-Object System.Windows.Forms.TextBox
$logTextBox.Location = New-Object System.Drawing.Point(10,390)
$logTextBox.Size = New-Object System.Drawing.Size(760,160)
$logTextBox.Multiline = $true
$logTextBox.ScrollBars = "Vertical"
$logTextBox.ReadOnly = $true
$form.Controls.Add($logTextBox)
$global:logTextBox = $logTextBox

# -------------------
# Define Event Handlers
# -------------------

# Event: Scan Library button click.
$btnScan.Add_Click({
    $listView.Items.Clear()
    $libraryPath = $txtLibrary.Text
    if (-not (Test-Path $libraryPath)) {
        [System.Windows.Forms.MessageBox]::Show("Library path not found.")
        return
    }
    Write-Log "Scanning library: $libraryPath"
    # Get subdirectories that contain at least one exe (recursively).
    $gameDirs = Get-ChildItem -Path $libraryPath -Directory | Where-Object {
        (Get-ChildItem -Path $_.FullName -Recurse -Filter *.exe -ErrorAction SilentlyContinue).Count -gt 0
    }
    foreach ($dir in $gameDirs) {
        $item = New-Object System.Windows.Forms.ListViewItem($dir.Name)
        $item.SubItems.Add($dir.FullName)
        $listView.Items.Add($item)
    }
    Write-Log "Scan complete. Found $($listView.Items.Count) games."
})

# Event: Install DXVK button click.
$btnInstall.Add_Click({
    if ($listView.CheckedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Please select at least one game.")
        return
    }
    foreach ($item in $listView.CheckedItems) {
        $gamePath = $item.SubItems[1].Text
        Write-Log "Processing game: $($item.Text) at $gamePath"
        # Find the first exe file in the game folder.
        $exeFile = Get-ChildItem -Path $gamePath -Recurse -Filter *.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $exeFile) {
            Write-Log "No executable found in $gamePath"
            continue
        }
        Write-Log "Using executable: $($exeFile.FullName)"
        Install-DXVK -exePath $exeFile.FullName
    }
    [System.Windows.Forms.MessageBox]::Show("DXVK installation complete for selected games.")
})

$btnRemove.Add_Click({
    if ($listView.CheckedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Please select at least one game.")
        return
    }
    foreach ($item in $listView.CheckedItems) {
        $gamePath = $item.SubItems[1].Text
        Write-Log "Removing DXVK from: $($item.Text) at $gamePath"
        
        # Remove DXVK DLLs from the selected game folder
        Remove-DXVK -gamePath $gamePath
    }
    [System.Windows.Forms.MessageBox]::Show("DXVK removal complete for selected games.")
})

$btnDownload.Add_Click({
    Write-Log "Downloading Dxvk latest version..."

    Download-Dxvk

[System.Windows.Forms.MessageBox]::Show("DXVK Download is completed!")
})


$btnDeveloper.Add_Click({

    [System.Windows.Forms.MessageBox]::Show("My developer name is Laezor and I am a powershell script user enthusiast.")
})


# Show the form.
[void]$form.ShowDialog()
