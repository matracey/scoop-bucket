<#
.SYNOPSIS
    Generates scoop manifests for PowerShell modules.
.DESCRIPTION
    This script generates scoop manifests for PowerShell modules and their dependencies.
.PARAMETER RootModule
    The root module for which to generate the scoop manifests.
.OUTPUTS
    A JSON file representing the scoop manifest for the module, written to the bucket directory.
.EXAMPLE
    .\generatepsmodulemanifests.ps1 -RootModule 'Microsoft.Graph'
    This command generates a scoop manifest for the Microsoft.Graph module and its dependencies.
#>

param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
    [string]$RootModule
)

function Get-ScoopName {
    <#
    .SYNOPSIS
        Converts a module name to a scoop name.
    .DESCRIPTION
        Converts a module name to a scoop name by replacing '.' with '-'.
    .PARAMETER Name
        The module name to convert.
    .OUTPUTS
        A string representing the scoop name.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Name
    )
    process { return $Name.ToLower().Replace('.', '-') }
}

function Get-ModuleDependencies {
    <#
    .SYNOPSIS
        Gets the dependencies of a module.
    .DESCRIPTION
        Gets the dependencies of a module by using Find-Module from PowerShellGet.
    .PARAMETER Name
        The name of the module to get dependencies for.
    .OUTPUTS
        A hashtable containing the module and its dependencies.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Name
    )

    process {
        $AllModules = PowerShellGet\Find-Module $Name -IncludeDependencies
        return @{
            Self         = ($AllModules | Where-Object { $_.Name -eq $Name })
            Dependencies = ($AllModules | Where-Object { $_.Name -ne $Name })
        }
    }
}

function Get-FileUrlHash {
    <#
    .SYNOPSIS
        Gets the SHA256 hash of a file from a URL.
    .DESCRIPTION
        Gets the SHA256 hash of a module by downloading it to a temporary file and calculating the hash.
    .PARAMETER Uri
        The URI of the module to download and hash.
    .OUTPUTS
        A string representing the SHA256 hash of the file.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$Uri
    )

    process {
        $TempFile = [System.IO.Path]::GetTempFileName()
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $TempFile
        } catch {
            Write-Host "Failed to download $Uri to $TempFile"
            return
        }

        try {
            $Sha256Hash = Get-FileHash $TempFile -Algorithm SHA256
        } catch {
            Write-Host "Failed to calculate hash for $TempFile"
            return
        }
        Remove-Item $TempFile

        return $Sha256Hash.Hash.ToLower()
    }
}

$BucketDir = [IO.Path]::Combine($PSScriptRoot, '..\bucket') | Resolve-Path
$ManifestQueue = New-Object System.Collections.Generic.Queue[string]
$ManifestQueue.Enqueue($RootModule) | Out-Null
$PackageSet = New-Object System.Collections.Generic.HashSet[string]
$Activity = "Generating scoop manifests for $RootModule and its dependencies"

while ($ManifestQueue.Count -gt 0) {
    $Name = $ManifestQueue.Dequeue()
    $LowerName = $Name.ToLower()
    $ScoopName = $Name | Get-ScoopName
    $PackageSet.Add($Name) | Out-Null
    $Status = "$Name (Module $($PackageSet.Count) of $($PackageSet.Count + $ManifestQueue.Count))"

    Write-Progress -Activity:$Activity -Status:$Status -CurrentOperation 'Finding dependencies'
    $Module = $Name | Get-ModuleDependencies
    $Module.Dependencies | ForEach-Object { if (-not $PackageSet.Contains(($_.Name | Get-ScoopName))) { $ManifestQueue.Enqueue($_.Name) } }

    $Status = "$Name (Module $($PackageSet.Count) of $($PackageSet.Count + $ManifestQueue.Count))"

    Write-Progress -Activity:$Activity -Status:$Status -CurrentOperation "Creating manifest for `"$ScoopName`""
    $TemplateObj = [ordered]@{
        version       = $Module.Self.Version.ToString()
        description   = $Module.Self.Description
        homepage      = $Module.Self.ProjectUri
        license       = $Module.Self.LicenseUri.AbsoluteUri
        depends       = $Module.Self.Dependencies | ForEach-Object { $_.Name | Get-ScoopName }
        pre_install   = 'Remove-Item "$dir\_rels", "$dir\package", "$dir\*Content_Types*.xml" -Recurse'
        pre_uninstall = @(
            '$InstalledDeps = $manifest.depends | Where-Object { Test-Path "$(appdir $_)\current" }',
            'if ($InstalledDeps.Count -le 0) { return }',
            'if ($global) { scoop uninstall --global $InstalledDeps }',
            'else { scoop uninstall $InstalledDeps }'
        )
        checkver      = [ordered]@{ regex = '<h2>([\d\.]+)</h2>'; url = "https://www.powershellgallery.com/packages/$LowerName"; }
        autoupdate    = [ordered]@{ url = "https://www.powershellgallery.com/api/v2/package/$Name/`$version#/$Name.nupkg" }
        hash          = 'TODO'
        url           = "https://www.powershellgallery.com/api/v2/package/$Name/" + $Module.Self.Version.ToString()
        psmodule      = [ordered]@{ name = $Name }
    }

    if ($TemplateObj.depends.Count -le 0) {
        $TemplateObj.Remove('depends')
        $TemplateObj.Remove('pre_uninstall')
    }

    Write-Progress -Activity:$Activity -Status:$Status -CurrentOperation 'Downloading module to calculate hash'

    $TemplateObj.hash = $TemplateObj.url | Get-FileUrlHash

    if ($null -eq $TemplateObj.hash) {
        continue
    }

    $OutputFile = [IO.Path]::Combine($BucketDir, "$ScoopName.json")

    Write-Progress -Activity:$Activity -Status:$Status -CurrentOperation "Writing manifest to `"$OutputFile`""

    $TemplateObj | ConvertTo-Json | Out-File $OutputFile
    . "$PSScriptRoot\formatjson.ps1" -App:$ScoopName
}

Write-Progress -Activity:$Activity -Completed
