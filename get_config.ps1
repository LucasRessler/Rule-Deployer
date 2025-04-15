function Get-Config ([String]$conf_path) {
    # Assert that the config file has the right format
    try { $config = Get-Content $conf_path -ErrorAction Stop | ConvertFrom-Json }
    catch { throw Format-Error -Message "The config could not be loaded" -cause $_.Exception.Message }
    $faults = Assert-Format $config @{
        nsx_image_path = @{}
        catalog_ids = @{ security_groups = @{}; services = @{}; rules = @{} }
        excel_sheetnames = @{ security_groups = @{}; services = @{}; rules = @{} }
    }
    if ($faults) {
        throw Format-Error `
            -Message "The config didn't match the expected format" `
            -Hints $faults
    }

    # Fetch Vra Credentials and Host Url 
    if ($null -eq (Get-Module -Name "functions" -ErrorAction SilentlyContinue)) { Import-Module "$PSScriptRoot\shared_functions.ps1" }
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
            request_id = "[A-Za-z]+\d+"
            ip_addr = $regex_ip
            ip_cidr = "$regex_ip(/$regex_cidr)?"         # ip or ip/cidr
            port = "[A-Za-z0-9]+\s*:\s*$regex_u16_range" # word:u16-range - protocols checked in `ParsePort`
        }
    }
}
