###########################################################################
#   █████╗ ██████╗  ██████╗ █████╗     ██╗ ██████╗ ███╗   ██╗██╗███████╗  #
#  ██╔══██╗██╔══██╗██╔════╝██╔══██╗    ██║██╔════╝ ████╗  ██║██║██╔════╝  #
#  ███████║██████╔╝██║     ███████║    ██║██║  ███╗██╔██╗ ██║██║███████╗  #
#  ██╔══██║██╔══██╗██║     ██╔══██║    ██║██║   ██║██║╚██╗██║██║╚════██║  #
#  ██║  ██║██║  ██║╚██████╗██║  ██║    ██║╚██████╔╝██║ ╚████║██║███████║  #
#  ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝    ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚═╝╚══════╝  #
#        _           _                     ___           _                #
#       | |__ _  _  | |  _  _ __ __ _ ___ | _ \___ _____| |___ _ _        #
#       | '_ \ || | | |_| || / _/ _` (_-< |   / -_|_-<_-< / -_) '_|       #
#       |_.__/\_, | |____\_,_\__\__,_/__/ |_|_\___/__/__/_\___|_|         #
#             |__/                                                        #
###########################################################################
                                                                     
$DEFAULT_FILE_PATH = "https://telekom-my.sharepoint.de/personal/lucas_ressler_t-systems_com/Documents/Dokumente/Input-Data/Kopie von FW rules TSA-v1.xlsx"
$SHEETNAME_PORTGROUPS = "TSA-Portgroups"
$SHEETNAME_SERVERGROUPS = "TSA-Servergroups"
$SHEETNAME_RULES = "TSA-Rules"

# $USERNAME = 
# $PASSWORD = 
# $TENNANT = 

$URL_VRA8 = "https://cus.val001c002vie1x.c002.vie1.fci.ts-ian.net"
$URL_REFRESHTOKEN = "$URL_VRA8/csp/gateway/am/api/login?access_token"
$URL_LOGIN = "$URL_VRA8/iaas/api/login"
$URL_DEPLOYMENTS = "$URL_VRA8/deployment/api/deployments"
$URL_PROJECT_ID = "$URL_VRA8/iaas/api/projects"
$URL_ITEMS = "$URL_VRA8/catalog/api/items"

# TODO: where tf do these come from
$CATALOG_MANAGE_SECURITY_GROUPS_ID = "2414bfd4-f5a5-37d7-a7bc-936ee9b1df7b"
$CATALOG_MANAGE_SERVICES_ID = "3e6534e8-f12d-38e3-8da4-987dda5c7c3e"
$CATALOG_MANAGE_FW_RULES_ID = "68f0139a-36b9-3b58-b5d5-754d7e3c93d0"

$REGEX_GROUPNAME = "[A-Za-z0-9_-]+"
$REGEX_SERVICEREQUEST = "[A-Z]+[0-9]+"
$REGEX_CIDR = "([1-9]|[1-2][0-9]|3[0-2])"             # Decimal number from 1-32
$REGEX_U8 = "([0-1]?[0-9]{1,2}|2([0-4][0-9]|5[0-5]))" # Decimal number from 0-255
$REGEX_IP = "($REGEX_U8\.){3}$REGEX_U8"               # u8.u8.u8.u8
$REGEX_IP_CIDR = "$REGEX_IP(/$REGEX_CIDR)?"           # ip or ip/cidr
$REGEX_U16 = "([0-5]?[0-9]{1,4}|6([0-4][0-9]{3}|5([0-4][0-9]{2}|5([0-2][0-9]|3[0-5]))))" # Decimal number from 0-65535
$REGEX_U16_RANGE = "$REGEX_U16(\s*-\s*$REGEX_U16)?"                                      # u16 or u16-u16
$REGEX_PORT = "[A-Za-z]+\s*:\s*$REGEX_U16_RANGE"                                         # protocol:u16-range

$DIVIDER = "------------------------"
$COLOR_PARSE_ERROR = 255 # Red
$COLOR_DPLOY_ERROR = 192 # Dark Red
$COLOR_SUCCESS = 4697456 # Light Green

class ExcelHandle {
    [__ComObject]$app
    [__ComObject]$workbook
    [bool]$should_close
    [bool]$initially_visible

    ExcelHandle([string]$file_path) {
        try {
            $this.app = [Runtime.Interopservices.Marshal]::GetActiveObject('Excel.Application')
            foreach ($wb in $this.app.Workbooks) {
                if ($wb.FullName -eq $file_path) {
                    $this.workbook = $wb
                    break
                }
            }
            if (-not $this.workbook) { throw }
            $this.should_close = $false
            Write-Host "Attached to and hid running Excel-Instance."
        } catch {
            $this.app = New-Object -ComObject Excel.Application
            $this.workbook = $this.app.Workbooks.Open($file_path)
            $this.should_close = $true
            Write-Host "Created new Excel-Instance."
        }
        $this.initially_visible = $this.app.Visible
        $this.app.Visible = $false
    }

    [void]Release() {
        $this.app.Visible = $this.initially_visible
        if ($this.should_close) {
            $this.workbook.Close($true)
            $this.app.Quit()
        }
    }
}

function Get-APIConfig {
    param (
        [String]$username,
        [String]$password,
        [String]$tennant_name
    )

    # very dangerously disabling validating certification
    # TODO: find out if there is a better way
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

    # get refresh token
    try {
        $body = @{
            username = $username
            password = $password
        } | ConvertTo-Json
        $response = Invoke-RestMethod $URL_REFRESHTOKEN -Method Post -ContentType "application/json" -Body $body
        $refresh_token = $response.refresh_token
    } catch {
        throw "Failed to obtain refresh token!
->> Verify that you are logged in to the admin lan
->> Verify that your username and password are valid"
    }


    # get access token
    try {
        $body = @{
            refreshToken = $refresh_token
        } | ConvertTo-Json
        $response = Invoke-RestMethod $URL_LOGIN -Method Post -ContentType "application/json" -Body $body 
        $access_token = $response.token

        $auth_headers = @{
            Authorization = "Bearer $access_token"
        }
    } catch {
        throw "Failed to obtain access token!
->> Verify you are still connected to the admin lan"
    }
    
    # get project id
    try {
        $response = Invoke-RestMethod "${URL_PROJECT_ID}?`$filter=name eq '$tennant_name'" -Headers $auth_headers -Method Get
    } catch {
        throw "Failed to get project id!
->> Verify that you are still connected to the admin lan"
    }

    $project_id = if ($response.content.Length -eq 1) {
        $response.content[0].id
    } else {
        throw "Failed to get project id!
->> '$tennant_name' might not be a valid tennant"
    }


    @{
        auth_headers = $auth_headers
        project_id = $project_id
    }
}

function ParseDataSheet {
    param(
        [hashtable]$data,
        [hashtable[]]$format
    )

    $data_cells = $data["cells"]
    $row = $data["row_index"]
    $body = @{}

    for ($i = 0; $i -lt $format.Length; $i++) {
        $col = [char]([int][char]'A' + $i)
        $field_name = $format[$i]["field_name"]
        $dbg_name = $format[$i]["dbg_name"]
        $subparser = $format[$i]["subparser"]
        $regex = if (-not $format[$i]["regex"]) {
            ".*" # Match anything if no regex is provided
        } else {
            $format[$i]["regex"]
        }

        if (-not $data_cells[$i]) {
            if ($format[$i]["is_optional"]) {
                continue
            } else {
                throw "Missing $dbg_name in row $row, column $col"
            }
        }

        if ($format[$i]["is_array"]) {
            $body[$field_name] = @()
            $entries = $data_cells[$i].Split([Environment]::NewLine) | ForEach-Object { $_.Trim() }
            foreach ($entry in $entries) {
                if (-not [regex]::IsMatch($entry, "^$regex$")) {
                    throw "Invalid $dbg_name in row $row, column ${col}: '${entry}'"
                }

                $body[$field_name] += if ($subparser) {
                    try {
                        & $subparser $entry
                    } catch {
                        throw "Invalid $dbg_name in row $row, column ${col} - $($_.Exception.Message)"
                    }
                } else {
                    $entry
                }
            }
        } else {
            if (-not [regex]::IsMatch($data_cells[$i].Trim(), "^$regex$")) {
                throw "Invalid $dbg_name in row $row, column ${col}: '$($data_cells[$i].Trim())'"
            }

            $body[$field_name] = if ($subparser) {
                try {
                    & $subparser $data_cells[$i].Trim()
                } catch {
                    throw "Invalid $dbg_name in row $row, column ${col} - $($_.Exception.Message)"
                }
            } else {
                $data_cells[$i].Trim()
            }
        }
    }

    $body
}

# Subparsers
function ParseIP([string]$raw_input) {
    # This function expects a prevalidated ipv4 address
    # Either with or without CIDR
    # u8.u8.u8.u8 | u8.u8.u8.u8/cidr

    $ip = @{}

    $split_input = $raw_input.Split("/")
    $ip["address"] = $split_input[0]
    if ($split_input[1]) {
        $ip["net"] = $split_input[1]
    }

    $ip
}

function ParsePort([string]$raw_input) {
    # This function expects a prevalidated protocol:port pair
    # Either with a single port address or a range
    # protocol:port | protocol:start-end

    $port = @{}

    $split_input = $raw_input.Split(":")
    $port["protocol"] = $split_input[0].Trim()

    $port_addresses = $split_input[1].Split("-")
    $port["start"] = $port_addresses[0].Trim()
    $port["end"] = if ($port_addresses[1]) {
        $port_addresses[1].Trim()
    } else {
        $port_addresses[0].Trim()
    }

    if ([int]($port["start"]) -gt [int]($port["end"])) {
        throw "Invalid range: '$($port["start"])-$($port["end"])'"
    }

    $port
}

# Converters
function ConvertServergroupsData {
    param(
        [String]$action,
        [Hashtable]$data,
        [Hashtable]$api_config
    )

    $name = "ArcaIgnis-Test---$($data.name)"
    $body = @{
        deploymentName = "$action Security Group - $(Get-Date -UFormat %s -Millisecond 0) - LR Automation"
        projectId = $api_config["project_id"]
        inputs = @{
            action = $action
            name = $name
            groupType = "IPSET"
        }
    }
    if ($action -eq "Update") {
        $body.inputs["elementToUpdate"] = "$name (IPSET)"
    }

    $addresses = ""
    foreach ($addr in $data.addresses) {
        if ($addresses -ne "") { $addresses += ", " }
        $addresses += $addr.address
        if ($addr.net) { $addresses += "/$($addr.net)" }
    }
    $body.inputs["ipAddress"] = $addresses
    if ($data.comment) { $body.inputs["description"] = $data.comment }

    $body
}

function ConvertPortgroupsData {
    param (
        [String]$action,
        [Hashtable]$data,
        [Hashtable]$api_config
    )

    $name = "ArcaIgnis-Test---$($data.name)"
    $body = @{
        deploymentName = "$(Get-Date -UFormat %s -Millisecond 0) - $action Service - LR Automation"
        projectId = $api_config["project_id"]
        inputs = @{
            action = $action 
            name = $name
        }
    }
    if ($action -eq "Update") {
        $body.inputs["elementToUpdate"] = $name
    }

    $used_protocols = @{}
    foreach ($portrange in $data.ports) {
        $protocol = $portrange.protocol.ToUpper()
        $portstring = $portrange.start
        if ($portrange.start -ne $portrange.end) {
            $portstring += "-" + $portrange.end
        }
        if ($used_protocols[$protocol]) {
            $used_protocols[$protocol] += $portstring
        } else {
            $used_protocols[$protocol] = @($portstring)
        }
    }

    $i = 1
    foreach ($protocol in $used_protocols.Keys) {
        $portranges = $used_protocols[$protocol]
        $body.inputs["protocol$i"] = $protocol
        $body.inputs["sourcePorts$i"] = $portranges
        $body.inputs["destinationPorts$i"] = $portranges
        $i++
    }

    if ($data.comment) { $body["description"] = $data.comment }
    $body
}

function ConvertRulesData {
    param (
        [Hashtable]$data,
        [Hashtable]$api_config
    )

    # TODO
}

# Data Configs
function Get-ServergroupsConfig {
    @{
        format = @(
            @{
                dbg_name = "Group Name"
                field_name = "name"
                regex = $REGEX_GROUPNAME
            },
            @{
                dbg_name = "IP-Address"
                field_name = "addresses"
                regex = $REGEX_IP_CIDR
                subparser = "ParseIP"
                is_array = $true
            },
            @{
                dbg_name = "Host Name"
                field_name = "hostname"
                is_optional = $true
            }
            @{
                dbg_name = "Comment"
                field_name = "comment"
                is_optional = $true
            }
            @{
                dbg_name = "Servicerequest NSX"
                field_name = "servicerequest"
                regex = $REGEX_SERVICEREQUEST
                is_optional = $true
                is_array = $true
            }
        )
        converter = "ConvertServergroupsData"
        url = "$URL_ITEMS/$CATALOG_MANAGE_SECURITY_GROUPS_ID/request"
    }
}

function Get-PortgroupsConfig {
    @{
        format = @(
            @{
                dbg_name = "Group Name"
                field_name = "name"
                regex = $REGEX_GROUPNAME
            },
            @{
                dbg_name = "Port"
                field_name = "ports"
                regex = $REGEX_PORT
                subparser = "ParsePort"
                is_array = $true
            },
            @{
                dbg_name = "Comment"
                field_name = "comment"
                is_optional = $true
            },
            @{
                dbg_name = "Servicerequest NSX"
                field_name = "servicerequest"
                regex = $REGEX_SERVICEREQUEST
                is_optional = $true
                is_array = $true
            }
        )
        converter = "ConvertPortgroupsData"
        url = "$URL_ITEMS/$CATALOG_MANAGE_SERVICES_ID/request"
    }
        
}

function Get-RulesConfig {
    @{
        format = @(
            @{
                dbg_name = "NSX-Index"
                field_name = "index"
                regex = "[0-9]+"
            },
            @{
                dbg_name = "NSX-Source"
                field_name = "source"
                regex = "$REGEX_GROUPNAME|$REGEX_IP"
                is_array = $true
            },
            @{
                dbg_name = "NSX-Destination"
                field_name = "destination"
                regex = "$REGEX_GROUPNAME|$REGEX_IP"
                is_array = $true
            },
            @{
                dbg_name = "NSX-Ports"
                field_name = "ports"
                regex = $REGEX_GROUPNAME
                is_array = $true
            },
            @{
                dbg_name = "NSX-Description"
                field_name = "description"
                is_optional = $true
            },
            @{
                dbg_name = "NSX-Servicerequest"
                field_name = "servicerequest"
                regex = $REGEX_SERVICEREQUEST
                is_optional = $true
                is_array = $true
            },
            @{
                dbg_name = "NSX-Customer FW"
                field_name = "customer_fw"
                is_optional = $true
            }
        )
        converter = "ConvertRulesData"
        url = "$URL_ITEMS/$CATALOG_MANAGE_FW_RULES_ID"
    }
}

function Punct ([int]$total, [int]$achieved) {
    if ($total -eq 0) {
        return "."
    }

    [Float]$ratio = $achieved / $total
    if ($ratio -ge 1.0) {
        "! :D"
    } elseif ($ratio -ge 0.75) {
        ". :)"
    } elseif ($ratio -ge 0.25) {
        " :/"
    } else {
        "... :("
    }
}

function Update-CreationStatus {
    param (
        [__ComObject]$excel,
        [string]$sheet_name,
        [int]$output_column,
        [int]$row,
        [string]$value,
        [double]$color = 0
    )

    try {
        $sheet = $excel.Worksheets.Item($sheet_name)
    }
    catch {
        throw "Sheet '$sheet_name' could not be opened! :("
    }

    $cell = $sheet.Cells.Item($row, $output_column)
    $cell.Value = $value
    $cell.Font.Color = $color
}

function Get-ExcelData {
    param (
        [__ComObject]$excel,
        [int]$output_column,
        [string]$sheet_name
    )

    try {
        $sheet = $excel.Worksheets.Item($sheet_name)
    }
    catch {
        throw "Sheet '$sheet_name' could not be opened! :("
    }

    $num_rows = $sheet.UsedRange.Rows.Count
    [Hashtable[]]$data = @()

    for ($row = 1; $row -le $num_rows; $row++) {
        # Only include data if the output-cell is empty
        if (-not $sheet.Cells.Item($row, $output_column).Text) {
            $row_data = @{
                cells = @()
                row_index = $row
            }

            for ($col = 1; $col -lt $output_column; $col++) {
                $row_data.cells += $sheet.Cells.Item($row, $col).Text
            }

            $data += $row_data
        }
    }

    $data
}

function DeployResource {
    param (
        [String]$url,
        [String]$body,
        [Hashtable]$api_config
    )

    $response = Invoke-RestMethod $url -Method Post -ContentType "application/json" -Headers $api_config.auth_headers -Body $body
    $deployment_id = $response.deploymentId
    if ($null -eq $deployment_id) { throw "Received invalid response: $($response | ConvertTo-Json)" }

    $deployment_id
}

function WaitForDeployments([Hashtable[]]$deployments) {
    $num_created = 0
    $num_deployments = $deployments.Length
    $deploy_again = @()

    Write-Host "Waiting for completion status of $num_deployments $(if ($num_deployments -eq 1) {"deployment"} else {"deployments"})..."
    for($i = 0; $i -lt $num_deployments; $i++) {
        Write-Host -NoNewline "...$([Math]::Floor($i * 100 / $num_total))%`r"
        $data = $deployments[$i]
        $id = $data.id

        $complete = $false
        while(-not $complete) {
            $response = Invoke-RestMethod "$URL_DEPLOYMENTS/$id" -Headers $api_config.auth_headers -Method Get
            $complete = ($response.status -ne "CREATE_INPROGRESS")
            Start-Sleep 1
        }

        if ($response.status -eq "CREATE_SUCCESSFUL") {
            Update-CreationStatus -excel $excel -sheet_name $sheet_name -output_column $output_column -row $data.row_index -value "Created Successfully" -color $COLOR_SUCCESS
            $num_created++
        } else {
            $Host.UI.WriteErrorLine("->> Creation of resource at row $($data.row_index) in $sheet_name failed")
            if ($data.second_attempt) {
                $deploy_again += @{
                    body = $data.second_attempt
                    row_index = $data.row_index
                }
            } else {
                Update-CreationStatus -excel $excel -sheet_name $sheet_name -output_column $output_column -row $data.row_index -value "Creation Failed" -color $COLOR_DPLOY_ERROR
            }
        }
    }

    Write-Host "$num_created/$num_deployments created successfully$(Punct $num_deployments $num_created)"
    $deploy_again
}

function HandleDataSheet {
    param (
        [__ComObject]$excel,
        [string]$sheet_name,
        [Hashtable]$config,
        [Hashtable]$api_config
    )

    Write-Host $DIVIDER
    Write-Host "Loading data for $sheet_name..."
    $format = $config.format
    $output_column = $format.Length + 1
    [Hashtable[]]$sheet_data = Get-ExcelData -excel $excel -sheet_name $sheet_name -output_column $output_column
    $num_total = $sheet_data.Length
    if ($num_total -eq 0) {
        Write-Host "Nothing to do!"
        return
    }

    $deployment_data = @()
    Write-Host "Building and sending $num_total API $(if($num_total -eq 1) {"call"} else {"calls"}) for $sheet_name..."
    for($i = 0; $i -lt $num_total; $i++) {
        Write-Host -NoNewline "...$([Math]::Floor($i * 100 / $num_total))%`r"
        $data = $sheet_data[$i]

        try {
            $data_body = ParseDataSheet -data $data -format $format
            $data_body_create = &($config.converter) -action "Create" -data $data_body -api_config $api_config | ConvertTo-Json
            $data_body_update = &($config.converter) -action "Update" -data $data_body -api_config $api_config | ConvertTo-Json
        } catch {
            $Host.UI.WriteErrorLine("->> Parse error in ${sheet_name}: $($_.Exception.Message)")
            Update-CreationStatus -excel $excel -sheet_name $sheet_name -output_column $output_column -row $data.row_index -value "Parse Error" -color $COLOR_PARSE_ERROR
            Continue
        }

        try {
            # TODO: See if you can handle this with a bulk request instead
            $deployment_data += @{
                id = (DeployResource -url $config.url -body $data_body_create -api_config $api_config)
                row_index = $data.row_index
                second_attempt = $data_body_update 
            }
            Start-Sleep 1 # Mandatory because of DDOS protection probably?
        } catch {
            $Host.UI.WriteErrorLine("->> Deploy error in ${sheet_name}: $($_.Exception.Message)")
            Update-CreationStatus -excel $excel -sheet_name $sheet_name -output_column $output_column -row $data.row_index -value "Deployment Failed" -color $COLOR_DPLOY_ERROR
            Continue
        }
    }

    $num_deployments = $deployment_data.Length
    Write-Host "$num_deployments/$num_total deployed$(Punct $num_total $num_deployments)"
    if($num_deployments -eq 0) {
        Write-Host "Filled out Creation Status for $sheet_name."
        Write-Host "Nothing more to do."
        return
    }

    [Hashtable[]]$update_data = WaitForDeployments $deployment_data
    $num_to_update = $update_data.Length
    $deployment_data = @()
    if ($num_to_update -gt 0) { Write-Host "Trying to update the $num_to_update remaining $(if ($num_to_update -eq 1) {"resource"} else {"resources"})..." }
    for ($i = 0; $i -lt $num_to_update; $i++) {
        Write-Host -NoNewline "...$([Math]::Floor($i * 100 / $num_to_update))%`r"
        [Hashtable]$data = $update_data[$i]
        [String]$data_body = $data.body

        try {
            $deployment_data += @{
                id = (DeployResource -url $config.url -body $data_body -api_config $api_config)
                row_index = $data.row_index
            }
            Start-Sleep 1 # Mandatory because of DDOS protection probably?
        } catch {
            $Host.UI.WriteErrorLine("->> Deploy error in ${sheet_name}: $($_.Exception.Message)")
            Update-CreationStatus -excel $excel -sheet_name $sheet_name -output_column $output_column -row $data.row_index -value "Deployment Failed" -color $COLOR_DPLOY_ERROR
            Continue
        }
    }

    $num_deployments = $deployment_data.Length
    Write-Host "$num_deployments/$num_to_update deployed$(Punct $num_to_update $num_deployments)"
    if($num_deployments -eq 0) {
        Write-Host "Filled out Creation Status for $sheet_name."
        Write-Host "Nothing more to do."
        return
    }

    WaitForDeployments $deployment_data | Out-Null
    Write-Host "Filled out Creation Status for $sheet_name!"
}

function Main {
    [CmdletBinding()]
    param (
        [string]$file_path,
        [string]$sheetname_servergroups = $SHEETNAME_SERVERGROUPS,
        [string]$sheetname_portgroups = $SHEETNAME_PORTGROUPS,
        [string]$sheetname_rules = $SHEETNAME_RULES
    )

    Write-Host "Initialising communication with API..."
    try {
        $api_config = Get-APIConfig -username $USERNAME -password $PASSWORD -tennant_name $TENNANT
    } catch {
        $Host.UI.WriteErrorLine("$($_.Exception.Message)")
        exit 666
    }

    Write-Host "Opening Excel-Instance..."
    try {
        $excel = [ExcelHandle]::new($file_path)
    } catch {
        $Host.UI.WriteErrorLine("Failed to open '$file_path' :(
->> The file might not exist or it might be in use
->> If the file's location is on a sharepoint, use the URL-format for the path (https://...)")
        exit 666
    } 

    HandleDataSheet -excel $excel.app -api_config $api_config -sheet_name $sheetname_servergroups -config (Get-ServergroupsConfig)
    HandleDataSheet -excel $excel.app -api_config $api_config -sheet_name $sheetname_portgroups -config (Get-PortgroupsConfig)
    HandleDataSheet -excel $excel.app -api_config $api_config -sheet_name $sheetname_rules -config (Get-RulesConfig)

    Write-Host $DIVIDER
    Write-Host "Releasing Excel-Instance..."
    $excel.Release()
    Write-Host "Done!"
}

$file_path = if($args[0]) {$args[0]} else {$DEFAULT_FILE_PATH}
Main -file_path $file_path
