# Load required assemblies for Windows Forms and Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Global log textbox (will be created later)
$global:logTextBox = $null

function Write-Log {
    param([string]$message)
    if ($global:logTextBox -ne $null) {
        $global:logTextBox.AppendText("$message`r`n")
    } else {
        Write-Output $message
    }
}

function Get-PEBitness {
    param ([string]$FilePath)
    $fs = [System.IO.File]::OpenRead($FilePath)
    $br = New-Object System.IO.BinaryReader($fs)
    $mz = $br.ReadBytes(2)
    if ([System.Text.Encoding]::ASCII.GetString($mz) -ne "MZ") {
         throw "Not a valid PE file."
    }
    $fs.Seek(0x3C, [System.IO.SeekOrigin]::Begin) | Out-Null
    $peHeaderOffset = $br.ReadInt32()
    $fs.Seek($peHeaderOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
    $peSignature = $br.ReadBytes(4)
    if (!($peSignature[0] -eq 80 -and $peSignature[1] -eq 69 -and $peSignature[2] -eq 0 -and $peSignature[3] -eq 0)) {
         throw "Not a valid PE file."
    }
    $fs.Seek(20, [System.IO.SeekOrigin]::Current) | Out-Null
    $magic = $br.ReadUInt16()
    $fs.Close()

    if ($magic -eq 0x10B) {
       return 32
    } elseif ($magic -eq 0x20B) {
       return 64
    } else {
       throw "Unknown PE format."
    }
}

function Install-DXVK {
    param([string]$exePath)
    if (-not (Test-Path $exePath)) {
        Write-Log "Executable not found: $exePath"
        return
    }

    try {
        $bitness = Get-PEBitness -FilePath $exePath
        Write-Log "Detected application bitness: $bitness-bit"
    } catch {
        Write-Log "Error detecting bitness: $_"
        return
    }

    $bytes = [System.IO.File]::ReadAllBytes($exePath)
    $content = [System.Text.Encoding]::ASCII.GetString($bytes)

    if ($content -match "d3d11\.dll") {
        $dxVersion = 11
    } elseif ($content -match "d3d10\.dll") {
        $dxVersion = 10
    } elseif ($content -match "d3d9\.dll") {
        $dxVersion = 9
    } elseif ($content -match "d3d8\.dll") {
        $dxVersion = 8
    } else {
        Write-Log "Could not detect any DirectX dependency in the executable. (Usually happens on unreal engine games)"
        return
    }

    Write-Log "Detected DirectX version: $dxVersion"
    if ($dxVersion -eq 12) {
        Write-Log "DirectX 12 is not supported by DXVK."
        return
    }

    $scriptFolder = Split-Path -Parent (Get-Location)
    $dxvkFolders = Get-ChildItem -Path $scriptFolder -Directory | Where-Object { $_.PSIsContainer -and $_.Name -match "^dxvk-\d+(\.\d+)*$" }

    if (-not $dxvkFolders) {
        Write-Log "No DXVK folder matching the pattern 'dxvk-[version]' was found in $scriptFolder"
        return
    }

    $baseDXVKFolder = $dxvkFolders[0].FullName
    Write-Log "Using DXVK folder: $($dxvkFolders[0].Name)"
    $archFolder = if ($bitness -eq 64) { "x64" } else { "x32" }
    $dxvkFolder = Join-Path $baseDXVKFolder $archFolder
    $destinationFolder = Split-Path $exePath

    switch ($dxVersion) {
        8  { $dxDllBase = "d3d8" }
        9  { $dxDllBase = "d3d9" }
        10 { $dxDllBase = "d3d10" }
        11 { $dxDllBase = "d3d11" }
    }

    if ($dxVersion -eq 11) {
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
    } else {
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

function Remove-DXVK {
    param([string]$exePath)

    if ([string]::IsNullOrWhiteSpace($exePath)) {
        Write-Log "Empty or null executable path passed to Remove-DXVK. Skipping..."
        return
    }

    $exeDir = Split-Path $exePath -Parent
    if (-not (Test-Path $exeDir)) {
        Write-Log "Executable path directory does not exist: $exeDir"
        return
    }

    $dxvkFiles = @(
        "d3d8.dll", "d3d9.dll", "d3d10.dll", "d3d10core.dll", 
        "d3d11.dll", "d3d12.dll", "dxgi.dll"
    )

    foreach ($dll in $dxvkFiles) {
        $target = Join-Path $exeDir $dll
        if (Test-Path $target) {
            try {
                Remove-Item $target -Force
                Write-Log "Removed: $target"
            } catch {
                Write-Log "Failed to remove ${target}: $_"
            }
        } else {
            Write-Log "Not found: $target"
        }
    }
}


function Download-Dxvk {
    $LatestRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/doitsujin/dxvk/releases/latest"
    $Asset = $LatestRelease.assets | Select-Object -First 1
    $downloadPath = Join-Path (Get-Location) $Asset.name
    Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $downloadPath
    Write-Log $Asset.name
    tar -xvzf $Asset.name -C .
    Remove-Item -Path $downloadPath -Force
}

# GUI
$form = New-Object System.Windows.Forms.Form
$form.Text = "DXVK Manager"
$form.Size = New-Object System.Drawing.Size(800,600)
$form.StartPosition = "CenterScreen"

$lblLibrary = New-Object System.Windows.Forms.Label
$lblLibrary.Location = New-Object System.Drawing.Point(10,10)
$lblLibrary.Size = New-Object System.Drawing.Size(100,20)
$lblLibrary.Text = "Steam Library:"
$form.Controls.Add($lblLibrary)

$txtLibrary = New-Object System.Windows.Forms.TextBox
$txtLibrary.Location = New-Object System.Drawing.Point(120,10)
$txtLibrary.Size = New-Object System.Drawing.Size(500,20)
$txtLibrary.Text = "C:\Program Files (x86)\Steam\steamapps\common"
$form.Controls.Add($txtLibrary)

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

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Location = New-Object System.Drawing.Point(10,350)
$btnInstall.Size = New-Object System.Drawing.Size(140,30)
$btnInstall.Text = "Install DXVK"
$form.Controls.Add($btnInstall)

$logTextBox = New-Object System.Windows.Forms.TextBox
$logTextBox.Location = New-Object System.Drawing.Point(10,390)
$logTextBox.Size = New-Object System.Drawing.Size(760,160)
$logTextBox.Multiline = $true
$logTextBox.ScrollBars = "Vertical"
$logTextBox.ReadOnly = $true
$form.Controls.Add($logTextBox)
$global:logTextBox = $logTextBox

# Events
$btnScan.Add_Click({
    $listView.Items.Clear()
    $libraryPath = $txtLibrary.Text
    if (-not (Test-Path $libraryPath)) {
        [System.Windows.Forms.MessageBox]::Show("Library path not found.")
        return
    }
    Write-Log "Scanning library: $libraryPath"
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

$btnInstall.Add_Click({
    if ($listView.CheckedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Please select at least one game.")
        return
    }
    foreach ($item in $listView.CheckedItems) {
        $gamePath = $item.SubItems[1].Text
        Write-Log "Processing game: $($item.Text) at $gamePath"
        $exeFiles = Get-ChildItem -Path $gamePath -Recurse -Filter *.exe -ErrorAction SilentlyContinue

        if ($exeFiles.Count -eq 0) {
            Write-Log "No executable found in $gamePath"
            continue
        }

        # Try to auto-detect Unreal Engine shipping EXE
        $shippingExe = $exeFiles | Where-Object {
            $_.FullName -match "\\Binaries\\Win64\\.*-Win64-Shipping\.exe$"
        } | Select-Object -First 1

        if ($shippingExe) {
            $selectedExe = $shippingExe.FullName
            Write-Log "Auto-detected Unreal Engine shipping executable: $selectedExe"
        }
        elseif ($exeFiles.Count -eq 1) {
            $selectedExe = $exeFiles[0].FullName
            Write-Log "Using single executable: $selectedExe"
        }
        else {
            $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
            $fileDialog.InitialDirectory = $gamePath
            $fileDialog.Title = "Select the main executable for $($item.Text)"
            $fileDialog.Filter = "Executable Files (*.exe)|*.exe"
            $fileDialog.Multiselect = $false
            if ($fileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $selectedExe = $fileDialog.FileName
                Write-Log "User selected executable: $selectedExe"
            } else {
                Write-Log "User canceled selection for $($item.Text)"
                continue
            }
        }

        Install-DXVK -exePath $selectedExe
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
        Write-Log "Processing game for DXVK removal: $($item.Text) at $gamePath"
        $exeFiles = Get-ChildItem -Path $gamePath -Recurse -Filter *.exe -ErrorAction SilentlyContinue

        if ($exeFiles.Count -eq 0) {
            Write-Log "No executable found in $gamePath"
            continue
        }

        # Try to auto-detect Unreal Engine shipping EXE
        $shippingExe = $exeFiles | Where-Object {
            $_.FullName -match "\\Binaries\\Win64\\.*-Win64-Shipping\.exe$"
        } | Select-Object -First 1

        if ($shippingExe) {
            $selectedExe = $shippingExe.FullName
            Write-Log "Auto-detected Unreal Engine shipping executable: $selectedExe"
        }
        elseif ($exeFiles.Count -eq 1) {
            $selectedExe = $exeFiles[0].FullName
            Write-Log "Using single executable: $selectedExe"
        }
        else {
            $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
            $fileDialog.InitialDirectory = $gamePath
            $fileDialog.Title = "Select the main executable for $($item.Text)"
            $fileDialog.Filter = "Executable Files (*.exe)|*.exe"
            $fileDialog.Multiselect = $false
            if ($fileDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                $selectedExe = $fileDialog.FileName
                Write-Log "User selected executable: $selectedExe"
            } else {
                Write-Log "User canceled selection for $($item.Text)"
                continue
            }
        }

        if (![string]::IsNullOrWhiteSpace($selectedExe)) {
            Remove-DXVK -exePath $selectedExe
}       else {
            Write-Log "No valid executable selected for $($item.Text), skipping DXVK removal."
}

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

[void]$form.ShowDialog()
