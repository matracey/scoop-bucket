$ManifestQueue = New-Object System.Collections.Generic.Queue[string]
$PackageSet = New-Object System.Collections.Generic.HashSet[string]

$ManifestQueue.Enqueue('Microsoft.Graph') | Out-Null

while ($ManifestQueue.Count -gt 0) {
    $Name = $ManifestQueue.Dequeue()
    $PackageSet.Add($Name) | Out-Null
    $LowerName = $Name.ToLower()
    $Dependencies = PowerShellGet\Find-Module $Name -IncludeDependencies | Where-Object { $_.Name -ne "$Name" }
    $Dependencies | ForEach-Object { if (-not $PackageSet.Contains($_.Name)) { $ManifestQueue.Enqueue($_.Name) } }

    $TemplateObj = @{
        version     = '2.26.1'
        description = 'Consume Microsoft Graph resources directly from your PowerShell scripts'
        homepage    = 'https://github.com/microsoftgraph/msgraph-sdk-powershell'
        license     = 'MIT'
        url         = "https://psg-prod-eastus.azureedge.net/packages/$LowerName.2.26.1.nupkg"
        hash        = 'TODO'
        pre_install = 'Remove-Item "$dir\_rels", "$dir\package", "$dir\*Content_Types*.xml" -Recurse'
        psmodule    = @{ name = $Name }
        checkver    = @{ url = "https://www.powershellgallery.com/packages/$LowerName"; regex = '<h2>([\d\.]+)</h2>' }
        autoupdate  = @{ url = "https://psg-prod-eastus.azureedge.net/packages/$LowerName.`$version.nupkg" }
    }

    $TempFile = [System.IO.Path]::GetTempFileName()
    try {
        Invoke-WebRequest -Uri $TemplateObj.url -OutFile:$TempFile
    } catch {
        Write-Host "Failed to download $($TemplateObj.url) to $TempFile"
        continue
    }
    $TemplateObj.hash = (Get-FileHash $TempFile -Algorithm SHA256).Hash.ToLower()
    Remove-Item $TempFile

    if ($Dependencies) {
        $TemplateObj.depends = $Dependencies | ForEach-Object { $_.Name.ToLower() }
    }

    $OutputFile = [IO.Path]::Combine('..\bucket', "$LowerName.json")

    $TemplateObj | ConvertTo-Json | Out-File $OutputFile
    Write-Host "Created $OutputFile"
}
