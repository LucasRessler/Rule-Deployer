using module ".\shared_types.psm1"
using module ".\parsing.psm1"
using module ".\utils.psm1"

function Get-SecurityGroupsConfig ([Hashtable]$config) {
    @{
        id = [ResourceId]::SecurityGroup
        format = @{
            name = @{
                dbg_name = "Security Group Name"
                regex = $config.regex.group_name
                required_for_delete = $true
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
            request_id = @{
                dbg_name = "Initial Request ID"
                regex = $config.regex.request_id
                is_optional = $true
            }
            update_requests = @{
                dbg_name = "Update Request IDs"
                regex = $config.regex.request_id
                is_optional = $true
                is_array = $true
                postparser = { param($value) NormalizeArray $value }
            }
        }
        excel_format = @(
            "name"
            "ip_addresses"
            "hostname"
            "comment"
            "all_request_ids"
        )
        json_nesting = @("name")
        resource_name = "Security Group"
        field_name = "security_groups"
        excel_sheet_name = $config.excel_sheetnames.security_groups
        catalog_id = $config.api.catalog_ids.security_groups
        ddos_sleep_time = 1.0
    }
}

function Get-ServicesConfig ([Hashtable]$config) {
    @{
        id = [ResourceId]::Service
        format = @{
            name = @{
                dbg_name = "Service Name"
                regex = $config.regex.group_name
                required_for_delete = $true
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
            request_id = @{
                dbg_name = "Initial Request ID"
                regex = $config.regex.request_id
                is_optional = $true
            }
            update_requests = @{
                dbg_name = "Update Request IDs"
                regex = $config.regex.request_id
                is_optional = $true
                is_array = $true
                postparser = { param($value) NormalizeArray $value }
            }
        }
        excel_format = @(
            "name"
            "ports"
            "comment"
            "all_request_ids"
        )
        json_nesting = @("name")
        resource_name = "Service"
        field_name = "services"
        catalog_id = $config.api.catalog_ids.services
        excel_sheet_name = $config.excel_sheetnames.services
        ddos_sleep_time = 1.0
    }
}

function Get-RulesConfig ([Hashtable]$config) {
    @{
        id = [ResourceId]::Rule
        format = @{
            unique_key = @{
                dbg_name = "Resource Identifier"
                is_unique = $true
                generator = {
                    param([Hashtable]$data)
                    Join @($data.gateway, $data.cis_id, $data.index) " - "
                }
            }
            name = @{
                dbg_name = "Rule Name"
                regex = $config.regex.group_name
                generator = {
                    param([Hashtable]$data)
                    "IDC$($data.cis_id)_$($data.index)"
                }
            }
            sources = @{
                dbg_name = "NSX-Source"
                regex_info = "Please use a Security Group Name or 'any'"
                regex = $config.regex.security_group_reference
                is_array = $true
                postparser = { param($value) ParseArrayWithAny $value }
                subparser = {
                    param($value)
                    ParseSecgroupReference (FailOnMatch $value $config.regex.ip_cidr (Format-Error `
                        -Message "Literal ip-addresses are not supported" `
                        -Hints @("Please use a Security Group Name or 'any'")))
                }
            }
            destinations = @{
                dbg_name = "NSX-Destination"
                regex_info = "Please use a Security Group Name or 'any'"
                regex = $config.regex.security_group_reference
                is_array = $true
                postparser = { param($value) ParseArrayWithAny $value }
                subparser = {
                    param($value)
                    ParseSecgroupReference (FailOnMatch $value $config.regex.ip_cidr (Format-Error `
                        -Message "Literal ip-addresses are not supported" `
                        -Hints @("Please use a Security Group Name or 'any'")))
                }
            }
            services = @{
                dbg_name = "NSX-Service"
                regex_info = "Please use a Service Name or 'any'"
                regex = $config.regex.service_reference
                is_array = $true
                postparser = { param($value) ParseArrayWithAny $value }
                subparser = {
                    param($value)
                    FailOnMatch $value $config.regex.port (Format-Error `
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
                regex_info = "Must be either 'T0 Internet' or 'T1 Payload'"
                regex = "(T0 Internet|T1 Payload)"
                required_for_delete = $true
            }
            index = @{
                dbg_name = "NSX-Index"
                regex_info = "Must be an integer greater than 0"
                regex = "[1-9][0-9]*"
                required_for_delete = $true
            }
            request_id = @{
                dbg_name = "Initial Request ID"
                regex = $config.regex.request_id
                is_optional = $true
            }
            cis_id = @{
                dbg_name = "CIS ID"
                regex = "\d{4,8}"
                required_for_delete = $true
            }
            update_requests = @{
                dbg_name = "Update Request IDs"
                regex = $config.regex.request_id
                is_optional = $true
                is_array = $true
                postparser = { param($value) NormalizeArray $value }
            }
        }
        excel_format = @(
            "index"
            "sources"
            "destinations"
            "services"
            "comment"
            "all_request_ids"
            "cis_id"
            "t0_internet"
            "t1_payload"
        )
        json_nesting = @("gateway", "cis_id", "index")
        resource_name = "Firewall Rule"
        field_name = "rules"
        excel_sheet_name = $config.excel_sheetnames.rules
        catalog_id = $config.api.catalog_ids.rules
        additional_deploy_chances = 1  # Rules run into API collisions shockingly often
        ddos_sleep_time = 3.0
    }
}
