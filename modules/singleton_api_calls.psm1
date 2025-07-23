using module ".\utils.psm1"

function Get-CMDBService {
    param([String]$ServiceName)
    Assert-EnvVars -dbg @("CMDB Username", "CMDB Password"   ) `
                   -var @("cmdb_user",     "cmdb_password"   ) `
                   -val @($env:cmdb_user,  $env:cmdb_password)
    Initialize-SessionSecurity
    [SecureString]$passwd = $env:cmdb_password | ConvertTo-SecureString -AsPlainText -Force 
    $creds = New-Object System.Management.Automation.PSCredential ($env:cmdb_user, $passwd)
    $url = "https://cmdbws.int.neonet.at/v_1_5/REST/REST.php/crud/SERVICE/SERVER/TBLSERVICE/$($ServiceName.ToUpper())"
    try { $response = Invoke-WebRequest -Uri $url -Credential $creds -UseBasicParsing }
    catch { throw HintAtUnauthorized -exception $_.Exception -portal_name "CMDB" }
    return $response.Content | ConvertFrom-Json | Select-Object SVCCOMMENT, SVCNAME, SVCID 
}

function Get-RMDBCredentials {
    param([String]$CmdbId, [String]$XaUser, [String]$Justification)
    Assert-EnvVars -dbg @("RMDB Username", "RMDB Password"   ) `
                   -var @("rmdb_user",     "rmdb_password"   ) `
                   -val @($env:rmdb_user,  $env:rmdb_password)
    Initialize-SessionSecurity
    if (-not $Justification)     { $Justification = ($MyInvocation.ScriptName -split '\\')[-2..-1] -join '\' }
    $part_a = "https://rmdb.int.neonet.at/api/rest/credential"
    $part_b = if ($CmdbId.StartsWith('A')) { "service/svcid" } else { "host/hostid" }
    $part_c = if ($CmdbId.StartsWith('A')) { "APP" } else { "OS" }
    $url = "$part_a/$part_b/$CmdbId/username/$XaUser/type/${part_c}?version=2&justification=$Justification"
    $headers = Get-BasicAuthHeader -user $env:rmdb_user -pswd $env:rmdb_password
    try { $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -UseBasicParsing }
    catch { throw HintAtUnauthorized -exception $_.Exception -portal_name "RMDB" }
    return $response
}

function Get-CatalogOptions {
    param([String]$Scope, [String]$Query)
    Assert-EnvVars -dbg @("CatalogDB Username", "CatalogDB Password"   ) `
                   -var @("catalogdb_user",     "catalogdb_password"   ) `
                   -val @($env:catalogdb_user,  $env:catalogdb_password)
    Initialize-SessionSecurity
    $url = "https://cmdb.int.neonet.at/Applikation/DelegatedCatalogOptions/v1/rest.php/options"
    $headers = Get-BasicAuthHeader -user $env:catalogdb_user -pswd $env:catalogdb_password
    try { $response = Invoke-RestMethod -Uri "$url/$Scope/$Query" -Headers $headers -Method Get }
    catch { throw HintAtUnauthorized -exception $_.Exception -portal_name "CataolgDB" }
    return [PSCustomObject]@{
        scope = $Scope;
        query = $Query.Split('/');
        raw = @($response)
    }
}
