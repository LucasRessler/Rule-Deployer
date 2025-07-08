using module ".\logger.psm1"
using module ".\utils.psm1"

function merge {
    param ([Ref]$uk, [Ref]$ev, [Hashtable]$t, [Hashtable]$i, [String[]]$ks, [String]$p)
    foreach ($k in $t.Keys) {
        [String]$fk = "$p$k"
        if (-not $t[$k]) { if ($ev) { $ev.Value += $fk }; continue }
        if ($ks -and $fk -notin $ks) { if ($uk) { $uk.Value += $fk }; continue }
        if ($i[$k] -is [Hashtable] -xor $t[$k] -is [Hashtable]) { continue }
        if ($i[$k] -isnot [Hashtable]) { $i[$k] = $t[$k]; continue }
        merge -uk $uk -ev $ev -t $t[$k] -i $i[$k] -ks $ks -p "$fk."
    }
}

function register {
    param ([Ref]$ks, [Hashtable]$t, [String]$p)
    foreach ($k in $t.Keys) {
        [String]$fk = "$p$k"
        if ($fk -notin $ks.Value) { $ks.Value += $fk }
        if ($t[$k] -is [Hashtable]) { register $ks $t[$k] "$fk." }
    }
}

function find_empty_vals {
    param ([Ref]$rk, [Hashtable]$t, [String]$p)
    foreach ($k in $t.Keys) {
        [String]$fk = "$p$k"
        if ($t[$k] -is [Hashtable]) { find_empty_vals $rk $t[$k] "$fk." }
        elseif (-not $t[$k]) { $rk.Value += $fk }
    }
}

function Get-Config {
    param (
        [String]$config_path,
        [Hashtable]$fully_optional,
        [Hashtable]$overrides,
        [Hashtable]$defaults,
        [Logger]$logger
    )

    # Load config from file
    try { $file_config = Get-Content $config_path -ErrorAction Stop | ConvertFrom-Json | ConvertTo-Hashtable }
    catch { throw Format-Error -Message "The config could not be loaded" -cause $_.Exception.Message }

    # Keep track  of known keys
    [String[]]$known_keys = @()
    foreach ($table in @($fully_optional, $overrides, $defaults)) { register ([Ref]$known_keys) $table }

    # Merge config file values into defaults, keep track of unknown keys and empty values
    [String[]]$unknown_keys = @(); [String[]]$empty_values = @()
    merge -uk ([Ref]$unknown_keys) -ev ([Ref]$empty_values) -t $file_config -i $defaults -ks $known_keys

    # Merge cli overrides into defaults
    merge -t $overrides -i $defaults

    # Find empty values in defaults
    [String[]]$empty_required = @()
    find_empty_vals -rk ([Ref]$empty_required) -t $defaults

    # Warn about unknown keys and empty values
    foreach ($k in $unknown_keys) { $logger.Warn("Unknown key in ${config_path}: $k") }
    foreach ($k in $empty_values) { $logger.Warn("Empty value in ${config_path}: $k") }

    # Trhow on any empty required values
    if ($empty_required.Count) { throw Format-Error `
        -Message "Some config values were required but not defined or not scalar values" `
        -Hints $empty_required
    }

    # Merge fully optuional values into defaults
    merge -t $fully_optional -i $defaults
    return $defaults
}

function SaturateConfig {
    param ([Hashtable]$config)

    # Fetch Vra Credentials and Host Url
    [String]$VRAHostName = $config.VraHostName
    if ($null -eq (Get-Module -Name "shared_functions" -ErrorAction SilentlyContinue)) { Import-Module "$PSScriptRoot\shared_functions.ps1" }
    $catalogOptionsVraHostnames = Get-CatalogOptions -Scope "FCI_SHARED" -Query "/*/HOSTNAME" -ErrorAction Stop
    $catalogOptionsVraHostnameKey = ($catalogOptionsVraHostnames.raw.GetEnumerator() | Where-Object { $VRAHostName -match $_.KEY1 }).KEY1
    $catalogOptionsVra = Get-CatalogOptions -Scope "FCI_SHARED" -Query "/$catalogOptionsVraHostnameKey" -ErrorAction Stop
    $VraSpecs = [PSCustomObject]@{
	    svcname = $catalogOptionsVraHostnameKey     
	    vchost  = ($catalogOptionsVra.raw.GetEnumerator() | Where-Object { $_.KEY2 -eq 'HOSTNAME' }).VALUE		
        vcuser  = ($catalogOptionsVra.raw.GetEnumerator() | Where-Object { $_.KEY2 -eq 'XAUTO_USER' }).VALUE
	    sso_domain = ($catalogOptionsVra.raw.GetEnumerator() | Where-Object { $_.KEY2 -eq 'SSO_DOMAIN' }).VALUE 
    }
    if (!$VraSpecs.svcname) { throw "Unable to load FCI VRA specs for $VRAHostName from CatalogOptions. :-(" }
    $CmdbData = Get-CMDBService -ServiceName $($VraSpecs.svcname)
    if (!$CmdbData['0'].SVCID) { throw "Unable to get SVCID of FCI VRA $VRA HostName from CMDB. :-(" }
    $VraCredentials = Get-RMDBCredentials -CmdbId $CmdbData['0'].SVCID -XaUser $VraSpecs.vcuser
    if (!$VraCredentials.data.password) { throw "Unable to get password for $($VraSpecs.vcuser) from RMDB. :-(" }
    
    # Build up complete Config
    $base_url = "https://" + $VraSpecs.vchost
    $regex_cidr = "([1-9]|[1-2][0-9]|3[0-2])"             # Decimal number from 1-32
    $regex_u8 = "([0-1]?[0-9]{1,2}|2([0-4][0-9]|5[0-5]))" # Decimal number from 0-255
    $regex_ip = "($regex_u8\.){3}$regex_u8"               # u8.u8.u8.u8
    $regex_u16 = "([0-5]?[0-9]{1,4}|6([0-4][0-9]{3}|5([0-4][0-9]{2}|5([0-2][0-9]|3[0-5]))))" # Decimal number from 0-65535
    $regex_u16_range = "$regex_u16(\s*-\s*$regex_u16)?"                                      # u16 or u16-u16

    return @{
        nsx_image_path = $config.nsx_image_path
        log_directory = $config.log_directory
        excel_sheetnames = $config.excel_sheetnames
        api = @{
            catalog_ids = $config.catalog_ids
            credentials = @{
                username = $VraCredentials.data.username
                password = $VraCredentials.data.password
            }
            urls = @{
                refresh_token = "$base_url/csp/gateway/am/api/login?access_token"
                project_id = "$base_url/iaas/api/projects"
                login = "$base_url/iaas/api/login"
                items = "$base_url/catalog/api/items"
                deployments = "$base_url/deployment/api/deployments"
            }
        }
        regex = @{
            group_name = "[A-Za-z0-9_.-]+"
            service_reference = "[A-Za-z0-9, ()_.-]+"
            security_group_reference = "(?i)[a-z0-9_.-]+(\s*\((ipset|group|segment|vm)\))?"
            request_id = "[A-Za-z]+\d+"
            ip_addr = $regex_ip
            ip_cidr = "$regex_ip(/$regex_cidr)?"         # ip or ip/cidr
            port = "[A-Za-z0-9]+\s*:\s*$regex_u16_range" # word:u16-range - protocols checked in `ParsePort`
        }
    }
}
