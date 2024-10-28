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
$SHEETNAME_SERVERGROUPS = "TSA-Servergroups"
$SHEETNAME_PORTGROUPS = "TSA-Portgroups"
$SHEETNAME_RULES = "TSA-Rules"
$TEST_PREFIX = "ArcaIgnis-Test---"

# TODO: find a better way to get these...
# $USERNAME =
# $PASSWORD =
# $TENNANT =

function Get-Config {
    $url_vra8 = "https://cus.val001c002vie1x.c002.vie1.fci.ts-ian.net"

    $regex_cidr = "([1-9]|[1-2][0-9]|3[0-2])"             # Decimal number from 1-32
    $regex_u8 = "([0-1]?[0-9]{1,2}|2([0-4][0-9]|5[0-5]))" # Decimal number from 0-255
    $regex_ip = "($regex_u8\.){3}$regex_u8"               # u8.u8.u8.u8
    $regex_u16 = "([0-5]?[0-9]{1,4}|6([0-4][0-9]{3}|5([0-4][0-9]{2}|5([0-2][0-9]|3[0-5]))))" # Decimal number from 0-65535
    $regex_u16_range = "$regex_u16(\s*-\s*$regex_u16)?"                                      # u16 or u16-u16

    @{
        url = @{
            refresh_token = "$url_vra8/csp/gateway/am/api/login?access_token" 
            login = "$url_vra8/iaas/api/login"
            deployments = "$url_vra8/deployment/api/deployments"
            project_id = "$url_vra8/iaas/api/projects"
            items = "$url_vra8/catalog/api/items"
        }
        catalog = @{
            # TODO: where tf do these come from
            security_groups = "2414bfd4-f5a5-37d7-a7bc-936ee9b1df7b"
            services = "3e6534e8-f12d-38e3-8da4-987dda5c7c3e"
            fw_rules = "68f0139a-36b9-3b58-b5d5-754d7e3c93d0"
        }
        regex = @{
            groupname = "[A-Za-z0-9_-]+"
            servicerequest = "[A-Za-z0-9_-]+"
            ip_addr = $regex_ip
            ip_cidr = "$regex_ip(/$regex_cidr)?"           # ip or ip/cidr
            port_range = "[A-Za-z]+\s*:\s$regex_u16_range" # protocol:u16-range
        }
        color = @{
            parse_error = 255 # Red
            dploy_error = 192 # Dark Red
            success = 4697456 # Light Green
        }
    }
}


class ExcelHandle {
    [__ComObject]$app
    [__ComObject]$workbook
    [Bool]$should_close
    
    ExcelHandle([String]$file_path) {
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
        $this.app.Visible = $false
    }

    [Hashtable[]] GetSheetData([Hashtable]$sheet_config) {
        [String]$sheet_name = $sheet_config.sheet_name
        [Int]$output_column = $sheet_config.format.Length + 1
        try { $sheet = $this.workbook.Worksheets.Item($sheet_name) }
        catch { throw "Sheet '$sheet_name' could not be opened: $($_.Exception.Message)" }

        $num_rows = $sheet.UsedRange.Rows.Count
        [Hashtable[]]$data = @()

        for ($row = 1; $row -le $num_rows; $row++) {
            # Only include data if the output-cell is empty
            if (-not $sheet.Cells.Item($row, $output_column).Text) {
                $row_data = @{
                    cells = @()
                    row_index = $row
                }

                $is_empty = $true
                for ($col = 1; $col -lt $output_column; $col++) {
                    $cell_data = $sheet.Cells.Item($row, $col).Text
                    $is_empty = ($is_empty -and ($cell_data.Trim() -eq ""))
                    $row_data.cells += $cell_data
                }

                if (-not $is_empty) { $data += $row_data }
            }
        }

        return $data 
    }

    [Void] UpdateCreationStatus([Hashtable]$sheet_config, [Int]$row_index, [String]$value, [Int]$color = 0) {
        [Int]$output_column = $sheet_config.format.Length + 1
        [String]$sheet_name = $sheet_config.sheet_name
        try { $sheet = $this.workbook.Worksheets.Item($sheet_name) }
        catch { throw "Sheet '$sheet_name' could not be opened: $($_.Exception.Message)" }
        $cell = $sheet.Cells.Item($row_index, $output_column)
        $cell.Value = $value
        $cell.Font.Color = $color
    }
    
    [Void] Release() {
        $this.app.Visible = $this.initially_visible
        if ($this.should_close) {
            $this.workbook.Close($true)
            $this.app.Quit()
        }
        else { $this.app.Visible = $true }
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($this.workbook)
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($this.app)
        $this.workbook = $null
        $this.app = $null
        $this.Finalize()
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }
}

class ApiHandle {
    [String]$project_id
    [Hashtable]$headers

    [String]$url_deployments
    [String]$url_items
    
    ApiHandle([String]$username, [String]$password, [String]$tennant_name, [Hashtable]$config) {
        $this.url_deployments = $config.url.deployments
        $this.url_items = $config.url.items

        # very dangerously disabling validating certification
        # TODO: find out if there is a better way
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

        # get refresh token
        try {
            $body = @{
                username = $username
                password = $password
            } | ConvertTo-Json
            $response = Invoke-RestMethod $config.url.refresh_token -Method Post -ContentType "application/json" -Body $body
            $refresh_token = $response.refresh_token
        } catch {
            throw "Failed to obtain refresh token: $($_.Exception.Message)"
        }

        # get access token
        try {
            $body = @{
                refreshToken = $refresh_token
            } | ConvertTo-Json
            $response = Invoke-RestMethod $config.url.login -Method Post -ContentType "application/json" -Body $body
            $access_token = $response.token

            $this.headers = @{
                Authorization = "Bearer $access_token"
            }
        } catch {
            throw "Failed to obtain access token: $($_.Exception.Message)"
        }

        # get project id
        try {
            $url = "$($config.url.project_id)?`$filter=name eq '$tennant_name'" 
            $response = Invoke-RestMethod $url -Method Get -Headers $this.headers
        } catch {
            throw "Failed to get project id: $($_.Exception.Message)"
        }

        if ($response.content.Length -eq 1) {
            $this.project_id = $response.content[0].id
        } else {
            throw "Excpected exactly 1 project with the given tennant name, found $($response.content.Length)!"
        }
    }

    [Object] Get([String]$url) {
        return Invoke-RestMethod $url -Method Get -Headers $this.headers
    }
    [Object] Post([String]$url, [Hashtable]$body) {
        return Invoke-RestMethod $url -Method Post -ContentType "application/json" -Headers $this.headers -Body ($body | ConvertTo-Json)
    }

    [String] Deploy([String]$name, [String]$catalog_id, [Hashtable]$inputs) {
        $body = @{
            deploymentName = $name
            projectId = $this.project_id
            inputs = $inputs
        }
        $response = $this.Post("$($this.url_items)/$catalog_id/request", $body)
        $deployment_id = $response.deploymentId
        if ($null -eq $deployment_id) { throw "Received invalid response: $($response | ConvertTo-Json)" }
        return $deployment_id
    }

    [DeploymentStatus] CheckDeployment([String]$deployment_id) {
        $response = $this.Get("$($this.url_deployments)/$deployment_id")
        switch ($response.status) {
            "CREATE_INPROGRESS" { return [DeploymentStatus]::InProgress }
            "CREATE_SUCCESSFUL" { return [DeploymentStatus]::Successful }
            "CREATE_FAILED" { return [DeploymentStatus]::Failed }
        }
        throw "Received invalid response: $($response | ConvertTo-Json)"
    }

    [DeploymentStatus] WaitForDeployment([String]$deployment_id) {
        $status = $null
        $complete = $false
        $wait_time = 0
        while (-not $complete) {
            Start-Sleep $wait_time
            $status = $this.CheckDeployment($deployment_id)
            $complete = $status -ne [DeploymentStatus]::InProgress
            $wait_time++
        }
        return $status
    }
}
enum DeploymentStatus {
    InProgress
    Successful
    Failed
}


function ParseDataSheet {
    param(
        [Hashtable]$data,
        [Hashtable[]]$format,
        [Hashtable]$unique_check
    )

    $data_cells = $data["cells"]
    $row = $data["row_index"]
    $body = @{}

    for ($i = 0; $i -lt $format.Length; $i++) {
        $col = [Char]([Int][Char]'A' + $i)
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
                throw "Missing ${dbg_name}: row $row, column $col"
            }
        }

        if ($format[$i]["is_array"]) {
            $value = @()
            $entries = $data_cells[$i].Split([Environment]::NewLine) | ForEach-Object { $_.Trim() }
            foreach ($entry in $entries) {
                if (-not [Regex]::IsMatch($entry, "^$regex$")) {
                    throw "Invalid ${dbg_name}: row $row, column ${col}: '${entry}'"
                }

                $value += if ($subparser) {
                    try {
                        & $subparser $entry
                    } catch {
                        throw "Invalid ${dbg_name}: row $row, column ${col}: $($_.Exception.Message)"
                    }
                } else {
                    $entry
                }
            }
        } else {
            if (-not [Regex]::IsMatch($data_cells[$i].Trim(), "^$regex$")) {
                throw "Invalid ${dbg_name}q: row $row, column ${col}: '$($data_cells[$i].Trim())'"
            }

            $value = if ($subparser) {
                try {
                    & $subparser $data_cells[$i].Trim()
                } catch {
                    throw "Invalid ${dbg_name}: row $row, column ${col}: $($_.Exception.Message)"
                }
            } else {
                $data_cells[$i].Trim()
            }
        }

        if($format[$i]["is_unique"] -and $unique_check) {
            if ($unique_check[$field_name]) {
                if ($unique_check[$field_name][$value]) {
                    throw "Duplicate ${dbg_name}: row $row, column ${col}: '$($data_cells[$i].Trim())' was already used"
                } else {
                    $unique_check[$field_name][$value] = $true
                }
            } else {
                $unique_check[$field_name] = @{$value = $true}
            }
        }

        $body[$field_name] = $value
    }

    $body
}


# Subparsers
function ParseIP([String]$raw_input) {
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

function ParsePort([String]$raw_input) {
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

    if ([Int]($port["start"]) -gt [Int]($port["end"])) {
        throw "Invalid range: '$($port["start"])-$($port["end"])'"
    }

    $port
}


# Converters
function ConvertServergroupsData {
    param(
        [String]$action,
        [Hashtable]$data
    )
    $name = "$TEST_PREFIX$($data.name)"
    $body = @{
            action = $action
            name = $name
            groupType = "IPSET"
    }
    if ($action -eq "Update") {
        $body["elementToUpdate"] = "$name (IPSET)"
    }

    $addresses = ""
    foreach ($addr in $data.addresses) {
        if ($addresses -ne "") { $addresses += ", " }
        $addresses += $addr.address
        if ($addr.net) { $addresses += "/$($addr.net)" }
    }
    $body["ipAddress"] = $addresses
    if ($data.comment) { $body["description"] = $data.comment }

    $body
}

function ConvertPortgroupsData {
    param (
        [String]$action,
        [Hashtable]$data
    )

    $name = "$TEST_PREFIX$($data.name)"
    $body =  @{
        action = $action 
        name = $name
    }
    if ($action -eq "Update") {
        $body["elementToUpdate"] = $name
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
        $body["protocol$i"] = $protocol
        $body["sourcePorts$i"] = $portranges
        $body["destinationPorts$i"] = $portranges
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

    Write-Host ($data | ConvertTo-Json)
    throw "NOT YET IMPLEMENTED"
    # TODO
}


# Data Configs
function Get-ServergroupsConfig([Hashtable]$config) {
    @{
        format = @(
            @{
                dbg_name = "Group Name"
                field_name = "name"
                regex = $config.regex.groupname
                is_unique = $true
            },
            @{
                dbg_name = "IP-Address"
                field_name = "addresses"
                regex = $config.regex.ip_cidr
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
                regex = $config.regex.servicerequest
                is_optional = $true
                is_array = $true
            }
        )
        converter = "ConvertServergroupsData"
        sheet_name = $SHEETNAME_SERVERGROUPS
        resource_name = "Security Group"
        catalog_id = $config.catalog.security_groups
    }
}

function Get-PortgroupsConfig([Hashtable]$config) {
    @{
        format = @(
            @{
                dbg_name = "Group Name"
                field_name = "name"
                regex = $config.regex.groupname
                is_unique = $true
            },
            @{
                dbg_name = "Port"
                field_name = "ports"
                regex = $config.regex.port
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
                regex = $config.regex.servicerequest
                is_optional = $true
                is_array = $true
            }
        )
        converter = "ConvertPortgroupsData"
        sheet_name = $SHEETNAME_PORTGROUPS
        resource_name = "Service"
        catalog_id = $config.catalog.services
    }
        
}

function Get-RulesConfig([Hashtable]$config) {
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
                regex = $config.regex.nsx_endpoint
                is_array = $true
            },
            @{
                dbg_name = "NSX-Destination"
                field_name = "destination"
                regex = $config.regex.nsx_endpoint
                is_array = $true
            },
            @{
                dbg_name = "NSX-Ports"
                field_name = "ports"
                regex = $config.regex.groupname
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
                regex = $config.regex.servicerequest
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
        sheet_name = $SHEETNAME_RULES
        resource_name = "FW-Rule"
        catalog_id = $config.catalog.fw_rules
    }
}


# Utils
function PrintDivider {
    Write-Host "------------------------"
}
function ShowPercentage ([Int]$i, [Int]$total) {
    Write-Host -NoNewline "...$([Math]::Floor($i * 100 / $total))%`r"
}
function Punct ([Int]$achieved, [Int]$total) {
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


function HandleDataSheet {
    param (
        [ExcelHandle]$excel_handle,
        [ApiHandle]$api_handle,
        [Hashtable]$sheet_config,
        [Hashtable]$config
    )

    [String]$sheet_name = $sheet_config.sheet_name

    # Helper functions
    function PrematurelyDone {
        Write-Host "Filled out creation status for $sheet_name."
        Write-Host "Nothing more to do!"
    }

    function DeployRequests([Hashtable[]]$input_data, [String]$action) {
        [Int]$num_data = $input_data.Length
        [Hashtable[]]$deployed = @()

        Write-Host "Deploying $num_data $action-$(if($num_data -eq 1) {"request"} else {"requests"})..."
        for ($i = 0; $i -lt $num_data; $i++) {
            ShowPercentage $i $num_data
            $row_index = $input_data[$i].row_index
            $data = $input_data[$i].data
            $deployment_name = "$action $($sheet_config.resource_name) - $(Get-Date -UFormat %s -Millisecond 0) - LR Automation"

            try {
                $inputs = & $sheet_config.converter -action $action -data $data
                $deployed += @{
                    id = $api_handle.Deploy($deployment_name, $sheet_config.catalog_id, $inputs)
                    row_index = $row_index
                    preconverted = $data
                    action = $action
                }
            }
            catch {
                $Host.UI.WriteErrorLine("->> Deploy error in ${sheet_name}: $($_.Exception.Message)")
                $excel.UpdateCreationStatus($sheet_config, $row_index, "Deployment Failed", $config.color.dploy_error)
            }

            Start-Sleep 1 # Mandatory because of DDoS protection probably...
        }

        $deployed
    }

    function AwaitDeployments([Hashtable[]]$input_data, [Bool]$is_reattempt) {
        [Hashtable[]]$reattempt = @()
        [Int]$num_deployed = $input_data.Length
        [Int]$num_successful = 0

        Write-Host "Waiting for status of $num_deployed $(if($num_deployed -eq 1) {"deployment"} else {"deployments"})..."
        for ($i = 0; $i -lt $num_deployed; $i++) {
            ShowPercentage $i $num_deployed
            $deployment = $input_data[$i]
            $action = $deployment.action
            $row_index = $deployment.row_index
            $status = $api.WaitForDeployment($deployment.id)
            if ($status -eq [DeploymentStatus]::Successful) {
                $num_successful++
                $excel.UpdateCreationStatus($sheet_config, $row_index, "$action Successful", $config.color.success)
            } elseif ($is_reattempt) {
                $Host.UI.WriteErrorLine("->> Creation and attempted update of resource at row $row_index in $sheet_name failed")
                $excel.UpdateCreationStatus($sheet_config, $row_index, "Crate Failed", $config.color.dploy_error)
            } else {
                $reattempt += @{
                    data = $deployment.preconverted
                    row_index = $deployment.row_index
                }
            }
        }

        @{
            reattempt = $reattempt
            num_successful = $num_successful
        }
    }

    # Get Raw Data
    PrintDivider
    Write-Host "Loading data for $sheet_name..."
    [Hashtable[]]$raw_data = $excel_handle.GetSheetData($sheet_config)
    [Int]$num_data = $raw_data.Length
    if ($num_data -eq 0) { Write-Host "Nothing to do!"; return }

    # Parse Data
    [Hashtable]$unique_check = @{}
    [Hashtable[]]$parsed_data = @()
    [Int]$num_parsed

    Write-Host "Parsing data for $num_data $(if($num_data -eq 1) {"resource"} else {"resources"})..."
    for ($i = 0; $i -lt $num_data; $i++) {
    ShowPercentage $i $num_data
        $data = $raw_data[$i]

        try {
            $parsed_data += @{
                data = ParseDataSheet -data $data -format $sheet_config.format -unique_check $unique_check
                row_index = $data.row_index
            }
        } catch {
            $err_message = $_.Exception.Message
            $Host.UI.WriteErrorLine("->> Parse error in ${sheet_name}: $err_message")
            $excel.UpdateCreationStatus($sheet_config, $data.row_index, $err_message.Split(":")[0], $config.color.parse_error)
        }
    }
    $num_parsed = $parsed_data.Length
    Write-Host "$num_parsed/$num_data parsed sucessfully$(Punct $num_parsed $num_data)"
    if ($num_parsed -eq 0) { PrematurelyDone; return }

    # Deploy Creation Requests
    [Hashtable[]]$deployed_create = DeployRequests $parsed_data "Create"
    [Int]$num_deployed_create = $deployed_create.Length
    Write-Host "$num_deployed_create/$num_parsed deployed$(Punct $num_deployed_create $num_parsed)"
    if ($num_deployed_create -eq 0) { PrematurelyDone; return }

    # Wait For Create-Deployments
    [Hashtable]$await_result = AwaitDeployments $deployed_create
    [Int]$num_created = $await_result.num_successful
    [Hashtable[]]$to_update = $await_result.reattempt
    [Int]$num_to_update = $to_update.Length
    Write-Host "$num_created/$num_deployed_create created successfully$(Punct $num_created $num_deployed_create)"
    if ($num_to_update -eq 0) { PrematurelyDone; return }

    # Deploy Update Requests
    # TODO: Maybe updating should require explicit input
    Write-Host "The failed $(if ($num_to_update -eq 1) {"resource"} else {"resources"}) might already exist."
    Write-Host "I'll attempt to update $(if ($num_to_update -eq 1) {"it"} else {"them"}) instead."
    [Hashtable[]]$deployed_update = DeployRequests $to_update "Update"
    [Int]$num_deployed_update = $deployed_update.Length
    Write-Host "$num_deployed_update/$num_to_update deployed$(Punct $num_deployed_update $num_to_update)"
    if ($num_deployed_update -eq 0) { PrematurelyDone; return }

    # Wait For Update-Deployments
    [Int]$num_updated = (AwaitDeployments $deployed_update $true).num_successful
    Write-Host "$num_updated/$num_deployed_update updated successfully$(Punct $num_updated $num_deployed_update)"
    Write-Host "Filled out creation status for $sheet_name."
}

function Main {
    [CmdletBinding()]
    param (
        [String]$file_path,
        [String]$sheetname_servergroups = $SHEETNAME_SERVERGROUPS,
        [String]$sheetname_portgroups = $SHEETNAME_PORTGROUPS,
        [String]$sheetname_rules = $SHEETNAME_RULES
    )

    $config = Get-Config
    Write-Host "Initialising communication with API..."
    try { $api = [ApiHandle]::New($USERNAME, $PASSWORD, $TENNANT, $config) }
    catch { $Host.UI.WriteErrorLine("$($_.Exception.Message)"); exit 666 }

    Write-Host "Opening Excel-Instance..."
    try { $excel = [ExcelHandle]::new($file_path) }
    catch { $Host.UI.WriteErrorLine("Failed to open '$file_path' :("); exit 666 }

    $sheet_configs = @(
        Get-ServergroupsConfig $config
        Get-PortgroupsConfig $config
        Get-RulesConfig $config
    )

    foreach ($sheet_config in $sheet_configs) {
        try { HandleDataSheet -excel_handle $excel -api_handle $api -sheet_config $sheet_config -config $config | Out-Null }
        catch { $Host.UI.WriteErrorLine($_.Exception.Message) }
    }

    PrintDivider
    Write-Host "Releasing Excel-Instance..."
    $excel.Release()
    Write-Host "Done!"
}

$file_path = if($args[0]) {$args[0]} else {$DEFAULT_FILE_PATH}
Main -file_path $file_path
