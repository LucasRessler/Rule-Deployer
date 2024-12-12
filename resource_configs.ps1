function Get-SecurityGroupsConfig ([Hashtable]$config) {
    @{
        format = @{
            name = @{
                dbg_name = "Security Group Name"
                regex = $config.regex.resource_name
                is_unique = $true
            }
            ip_addresses = @{
                dbg_name = "IP-Address"
                regex = $config.regex.ip_cidr
                is_array = $true
                subparser = { param($value) ParseIP $value }
            }
            hostname = @{
                dbg_name = "Hostname"
                is_optional = $true
            }
            comment = @{
                dbg_name = "Security Group Comment"
                is_optional = $true
            }
            servicerequest = @{
                dbg_name = "Initial Servicerequest"
                regex = $config.regex.servicerequest
                is_optional = $true
            }
            updaterequests = @{
                dbg_name = "Update Servicerequest"
                regex = $config.regex.servicerequest
                is_optional = $true
                is_array = $true
            }
        }
        resource_name = "Security Group"
        field_name = "security_groups"
        excel_sheet_name = $config.excel.sheetnames.security_groups
        catalog_id = $config.api.catalog_ids.security_groups
        ddos_sleep_time = 1.0
        json_parser = {
            param ([Datapacket[]]$data_packet)
            SecurityGroupsDataFromJsonData
        }
        excel_parser = {
            param ([Datapacket[]]$data_packet)
            SecurityGroupsDataFromExcelData
        }
        converter = {
            param ([Hashtable]$data, [ApiAction]$action)
            ConvertSecurityGroupsData $data $action
        }
    }
}

function Get-ServicesConfig ([Hashtable]$config) {
    @{
        format = @{
            name = @{
                dbg_name = "Service Name"
                regex = $config.regex.resource_name
                is_unique = $true
            }
            ports = @{
                dbg_name = "Ports"
                regex = $config.regex.port
                is_array = $true
                subparser =  { param($value) ParsePort $value }
            }
            comment = @{
                dbg_name = "Service Comment"
                is_optional = $true
            }
            servicerequest = @{
                dbg_name = "Initial Servicerequest"
                regex = $config.regex.servicerequest
                is_optional = $true
            }
            updaterequests = @{
                dbg_name = "Update Servicerequest"
                regex = $config.regex.servicerequest
                is_optional = $true
                is_array = $true
            }
        }
        resource_name = "Service"
        field_name = "services"
        catalog_id = $config.api.catalog_ids.services
        excel_sheet_name = $config.excel.sheetnames.services
        ddos_sleep_time = 1.0
        json_parser = {
            param ([Datapacket[]]$data_packet)
            ServicesDataFromJsonData
        }
        excel_parser = {
            param ([Datapacket[]]$data_packet)
            ServicesDataFromExcelData
        }
        converter = {
            param ([Hashtable]$data, [ApiAction]$action)
            ConvertServicesData $data $action
        }
    }
}

function Get-RulesConfig ([Hashtable]$config) {
    @{
        format = @{
            name = @{
                dbg_name = "Rule Name"
                regex = $config.regex.resource_name
                is_unique = $true
                generator = {
                    param([Hashtable]$data)
                    @($data.servicerequest, $data.index, "Auto") -join "_"
                }
            }
            sources = @{
                dbg_name = "NSX-Source"
                regex_info = "Please use a Security Group Name or 'any'"
                regex = $config.regex.resource_name
                is_array = $true
                postparser = { param($value) ParseArrayWithAny $value }
                subparser = {
                    param($value)
                    FailOnMatch $value $config.regex.ip_cidr Format-Error `
                        -Message "Literal ip-addresses are not supported" `
                        -Hints @("Please use a Security Group Name or 'any'")
                }
            }
            destinations = @{
                dbg_name = "NSX-Destination"
                regex_info = "Please use a Security Group Name or 'any'"
                regex = $config.regex.resource_name
                is_array = $true
                postparser = { param($value) ParseArrayWithAny $value }
                subparser = {
                    param($value)
                    FailOnMatch $value $config.regex.ip_cidr Format-Error `
                        -Message "Literal ip-addresses are not supported" `
                        -Hints @("Please use a Security Group Name or 'any'")
                }
            }
            services = @{
                dbg_name = "NSX-Service"
                regex_info = "Please use a Service Name or 'any'"
                regex = $config.regex.resource_name
                is_array = $true
                postparser = { param($value) ParseArrayWithAny $value }
                subparser = {
                    param($value)
                    FailOnMatch $value $config.regex.ip_cidr Format-Error `
                        -Message "Literal ip-addresses are not supported" `
                        -Hints @("Please use a Service Name or 'any'")
                }
            }
            comment = @{
                dbg_name = "NSX-Description"
                is_optional = $true
            }
            gateway = @{
                dbg_name = "Gateway"
                regex = $config.regex.resource_name
            }
            index = @{
                dbg_name = "NSX-Index"
                regex = "[1-0][0-9]*"
                regex_info = "Must be an integer greater than 0!"
            }
            servicerequest = @{
                dbg_name = "Initial Servicerequest"
                regex = $config.regex.servicerequest
            }
            updaterequests = @{
                dbg_name = "Update Servicerequest"
                regex = $config.regex.servicerequest
                is_optional = $true
                is_array = $true
            }
        }
        resource_name = "Firewall Rule"
        field_name = "rules"
        excel_sheet_name = $config.excel.sheetnames.rules
        catalog_id = $config.api.catalog_ids.rules
        additional_deploy_chances = 1
        ddos_sleep_time = 3.0
        json_parser = {
            param ([Datapacket[]]$data_packet)
            RulesDataFromJsonData
        }
        excel_parser = {
            param ([Datapacket[]]$data_packet)
            RulesDataFromExcelData
        }
        converter = {
            param ([Hashtable]$data, [ApiAction]$action)
            ConvertRulesData $data $action
        }
    }
}