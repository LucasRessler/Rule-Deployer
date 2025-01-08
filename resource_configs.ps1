using module ".\io_handle.psm1"

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
        excel_format = @(
            "name"
            "ip_addresses"
            "hostname"
            "comment"
            "all_servicerequests"
        )
        json_nesting = @("name")
        resource_name = "Security Group"
        field_name = "security_groups"
        excel_sheet_name = $config.excel.sheetnames.security_groups
        catalog_id = $config.api.catalog_ids.security_groups
        ddos_sleep_time = 1.0
        json_parser = {
            param ([DataPacket]$data_packet)
            SecurityGroupsDataFromJsonData $data_packet
        }
        excel_parser = {
            param ([DataPacket]$data_packet)
            SplitServicerequestsInExcelData $data_packet
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
        excel_format = @(
            "name"
            "ports"
            "comment"
            "all_servicerequests"
        )
        json_nesting = @("name")
        resource_name = "Service"
        field_name = "services"
        catalog_id = $config.api.catalog_ids.services
        excel_sheet_name = $config.excel.sheetnames.services
        ddos_sleep_time = 1.0
        json_parser = {
            param ([DataPacket]$data_packet)
            ServicesDataFromJsonData $data_packet
        }
        excel_parser = {
            param ([DataPacket]$data_packet)
            SplitServicerequestsInExcelData $data_packet
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
            unique_key = @{
                dbg_name = "Deployment Identifier"
                is_unique = $true
                generator = {
                    param([Hashtable]$data)
                    @($data.gateway, $data.servicerequest, $data.index) -join " - "
                }
            }
            name = @{
                dbg_name = "Rule Name"
                regex = $config.regex.resource_name
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
                    FailOnMatch $value $config.regex.ip_cidr (Format-Error `
                        -Message "Literal ip-addresses are not supported" `
                        -Hints @("Please use a Security Group Name or 'any'"))
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
                    FailOnMatch $value $config.regex.ip_cidr (Format-Error `
                        -Message "Literal ip-addresses are not supported" `
                        -Hints @("Please use a Security Group Name or 'any'"))
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
                    FailOnMatch $value $config.regex.ip_cidr (Format-Error `
                        -Message "Literal port-addresses are not supported" `
                        -Hints @("Please use a Service Name or 'any'"))
                }
            }
            comment = @{
                dbg_name = "NSX-Description"
                is_optional = $true
            }
            gateway = @{
                dbg_name = "Gateway"
                regex_info = "Must be one either 'T0 Internet' or 'T1 Payload'"
                regex = "T0 Internet|T1 Payload"
            }
            index = @{
                dbg_name = "NSX-Index"
                regex_info = "Must be an integer greater than 0"
                regex = "[1-9][0-9]*"
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
        excel_format = @(
            "index"
            "sources"
            "destinations"
            "services"
            "comment"
            "all_servicerequests"
            "customer_fw"
            "t0_internet"
            "t1_payload"
        )
        json_nesting = @("gateway", "servicerequest", "index")
        resource_name = "Firewall Rule"
        field_name = "rules"
        excel_sheet_name = $config.excel.sheetnames.rules
        catalog_id = $config.api.catalog_ids.rules
        additional_deploy_chances = 1
        ddos_sleep_time = 3.0
        json_parser = {
            param ([DataPacket]$data_packet)
            RulesDataFromJsonData $data_packet
        }
        excel_parser = {
            param ([DataPacket]$data_packet)
            RulesDataFromExcelData $data_packet
        }
        converter = {
            param ([Hashtable]$data, [ApiAction]$action)
            ConvertRulesData $data $action
        }
    }
}
