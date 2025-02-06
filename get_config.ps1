function Get-Config ([String]$conf_path) {
    try { $config = Get-Content $conf_path -ErrorAction Stop | ConvertFrom-Json }
    catch { throw Format-Error -Message "The config could not be loaded" -cause $_.Exception.Message }
    $faults = Assert-Format $config @{
        nsx_image_path = @{}
        log_directory = @{}
        api = @{
            base_url = @{}
            catalog_ids = @{ security_groups = @{}; services = @{}; rules = @{} }
            credentials = @{ username = @{}; password = @{} }
        }
        excel = @{
            filepath = @{}
            sheetnames = @{ security_groups = @{}; services = @{}; rules = @{} }
        }
    }
    if ($faults) {
        throw Format-Error `
            -Message "The config didn't match the expected format" `
            -Hints $faults
    }

    $base_url = $config.api.base_url
    $regex_cidr = "([1-9]|[1-2][0-9]|3[0-2])"             # Decimal number from 1-32
    $regex_u8 = "([0-1]?[0-9]{1,2}|2([0-4][0-9]|5[0-5]))" # Decimal number from 0-255
    $regex_ip = "($regex_u8\.){3}$regex_u8"               # u8.u8.u8.u8
    $regex_u16 = "([0-5]?[0-9]{1,4}|6([0-4][0-9]{3}|5([0-4][0-9]{2}|5([0-2][0-9]|3[0-5]))))" # Decimal number from 0-65535
    $regex_u16_range = "$regex_u16(\s*-\s*$regex_u16)?"                                      # u16 or u16-u16

    @{
        nsx_image_path = $config.nsx_image_path
        log_directory = $config.log_directory
        excel = $config.excel
        api = @{
            catalog_ids = $config.api.catalog_ids
            credentials = $config.api.credentials
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
            servicerequest = "[A-Za-z]+\d+"
            ip_addr = $regex_ip
            ip_cidr = "$regex_ip(/$regex_cidr)?"         # ip or ip/cidr
            port = "[A-Za-z0-9]+\s*:\s*$regex_u16_range" # word:u16-range - protocols checked in `ParsePort`
        }
        color = @{
            parse_error = 255 # Red
            dploy_error = 192 # Dark Red
            success = 4697456 # Light Green
        }
    }
}
