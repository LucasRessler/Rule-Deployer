using module ".\utils.psm1"

function Get-CMDBService {
    param([String]$ServiceName)
    Initialize-SessionSecurity
    [SecureString]$passwd = $env:cmdb_password | ConvertTo-SecureString -AsPlainText -Force 
    $creds = New-Object System.Management.Automation.PSCredential ($env:cmdb_user, $passwd)
    $url = "https://cmdbws.int.neonet.at/v_1_5/REST/REST.php/crud/SERVICE/SERVER/TBLSERVICE/$($ServiceName.ToUpper())"
    $response = Invoke-WebRequest -Uri $url -Credential $creds -UseBasicParsing
    return $response.Content | ConvertFrom-Json | Select-Object SVCCOMMENT, SVCNAME, SVCID 
}

function Get-RMDBCredentials {
    param([String]$CmdbId, [String]$XaUser, [String]$Justification)
    Initialize-SessionSecurity
    if (-not $Justification) { $Justification = ($MyInvocation.ScriptName -split '\\')[-2..-1] -join '\' }
    $part_a = "https://rmdb.int.neonet.at/api/rest/credential"
    $part_b = if ($CmdbId.StartsWith('A')) { "service/svcid" } else { "host/hostid" }
    $part_c = if ($CmdbId.StartsWith('A')) { "APP" } else { "OS" }
    $url = "$part_a/$part_b/$CmdbId/username/$XaUser/type/${part_c}?version=2&justification=$Justification"
    $headers = Get-BasicAuthHeader -user $env:rmdb_user -pswd $env:rmdb_password
    return Invoke-RestMethod -Uri $url -Headers $headers -Method Get -UseBasicParsing
}

function Get-CatalogOptions {
    param([String]$Scope, [String]$Query)
    Initialize-SessionSecurity
    $url = "https://cmdb.int.neonet.at/Applikation/DelegatedCatalogOptions/v1/rest.php/options"
    $headers = Get-BasicAuthHeader -user $env:catalogdb_user -pswd $env:catalogdb_password
    $response = Invoke-RestMethod -Uri "$url/$Scope/$Query" -Headers $headers -Method Get
    return [PSCustomObject]@{
        scope = $Scope;
        query = $Query.Split('/');
        raw = @($response)
    }
}
