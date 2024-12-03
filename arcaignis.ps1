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

[CmdletBinding()]
param (
    [String]$ConfigPath = "$HOME\arcaignis.json",
    [String]$Action
)

$TEST_PREFIX = "ArcaIgnis-Test---"


# Utils
function Join ([Object[]]$arr, [String]$delim) {
    [String]$s = ""
    foreach ($x in $arr) { if ($x) { $s += "$(if ($s) {$delim})$x" } }
    return $s
}

function Format-Error {
    param ([String]$message, [String]$cause, [String[]]$hints)
    if ($cause) { $message += "`n| Caused by: " + (Join $cause.Split([Environment]::NewLine) "`n| ")}
    foreach ($hint in $hints) { $message += "`n| ->> $hint" }
    return $message
}

function PrintDivider {
    Write-Host "------------------------"
}

function ShowPercentage ([Int]$i, [Int]$total) {
    Write-Host -NoNewline "...$([Math]::Floor(($i * 100 + 50) / $total))%`r"
}

function PluralityIn ([Int]$number, [String]$singular = "", [String]$plural = "s") {
    if ($number -eq 1) { $singular } else { $plural }
}

function Punctuate ([Int]$achieved, [Int]$total) {
    if ($achieved -gt $total -or $achieved -lt 0) { return "!? >:O"} # Impossible case
    if ($total -eq 0) { return "." }                                 # 0/0 case

    [Float]$ratio = [Math]::Round($achieved / $total, 2)
    if ($ratio -eq 1.00)     { return "! :D" }
    elseif ($ratio -ge 0.75) { return ". :)" }
    elseif ($ratio -ge 0.25) { return " :/" }
    else                     { return "... :(" }
}

function DeepCopy ([Hashtable]$source) {
   $copy = @{}
   foreach ($key in $source.Keys) {
    $value = $source[$key]
    if ($value -is [Hashtable]) { $copy[$key] = DeepCopy $value }
    else { $copy[$key] = $value }
   } 
   $copy
}

# Config
function Assert-Format ($x, [Hashtable]$format, $parent = $null) {
    foreach ($key in $format.Keys) {
        $fullname = Join @($parent, $key) "."
        if ($null -eq $x.$key) { throw "Missing field '$fullname'" }
        Assert-Format $x.$key $format.$key $fullname
    }
}

function Get-Config ([String]$conf_path) {
    $config = Get-Content $conf_path | ConvertFrom-Json
    Assert-Format $config @{
        api = @{
            base_url = @{}
            catalog_ids = @{ security_groups = @{}; services = @{}; rules = @{} }
            credentials = @{ username = @{}; password = @{}; tennant = @{} }
        }
        excel = @{
            filepath = @{}
            sheetnames = @{ security_groups = @{}; services = @{}; rules = @{} }
        }
    }

    $base_url = $config.api.base_url
    $regex_cidr = "([1-9]|[1-2][0-9]|3[0-2])"             # Decimal number from 1-32
    $regex_u8 = "([0-1]?[0-9]{1,2}|2([0-4][0-9]|5[0-5]))" # Decimal number from 0-255
    $regex_ip = "($regex_u8\.){3}$regex_u8"               # u8.u8.u8.u8
    $regex_u16 = "([0-5]?[0-9]{1,4}|6([0-4][0-9]{3}|5([0-4][0-9]{2}|5([0-2][0-9]|3[0-5]))))" # Decimal number from 0-65535
    $regex_u16_range = "$regex_u16(\s*-\s*$regex_u16)?"                                      # u16 or u16-u16

    @{
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
            groupname = "[A-Za-z0-9_-]+"
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

# Enums and Classes
enum DeploymentStatus {
    InProgress
    Successful
    Failed
}

enum ApiAction {
    Create
    Update
    Delete
}

class ExcelHandle {
    [__ComObject]$app
    [__ComObject]$workbook
    [Bool]$should_close
    
    ExcelHandle ([String]$file_path) {
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

    [Hashtable[]] GetSheetData ([Hashtable]$sheet_config) {
        [String]$sheet_name = $sheet_config.sheet_name
        [Int]$output_column = $sheet_config.format.Length + 1
        try { $sheet = $this.workbook.Worksheets.Item($sheet_name) }
        catch { throw Format-Error -Message "Sheet '$sheet_name' could not be opened" -Cause $_.Exception.Message }

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

    [Void] UpdateCreationStatus ([Hashtable]$sheet_config, [Int]$row_index, [String]$value, [Int]$color = 0) {
        [Int]$output_column = $sheet_config.format.Length + 1
        [String]$sheet_name = $sheet_config.sheet_name
        try { $sheet = $this.workbook.Worksheets.Item($sheet_name) }
        catch { throw Format-Error -Message "Sheet '$sheet_name' could not be opened" -Cause $_.Exception.Message }
        $cell = $sheet.Cells.Item($row_index, $output_column)
        if ($cell.Text -ne $value) {
            $cell.Value = Join @($cell.Text, $value) ", "
            $cell.Font.Color = $color
        }
    }
    
    [Void] Release () {
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
    
    ApiHandle ([Hashtable]$config) {
        $this.url_deployments = $config.api.urls.deployments
        $this.url_items = $config.api.urls.items
        $username = $config.api.credentials.username
        $password = $config.api.credentials.password
        $tennant = $config.api.credentials.tennant

        # get refresh token
        try {
            $body = @{
                username = $username
                password = $password
            } | ConvertTo-Json
            $response = Invoke-RestMethod $config.api.urls.refresh_token -Method Post -ContentType "application/json" -Body $body -TimeoutSec 5
            $refresh_token = $response.refresh_token
        } catch {
            throw Format-Error -Message "Failed to obtain refresh token!" -Cause $_.Exception.Message -Hints @(
                "Ensure that you're connected to the Admin-LAN"
                "Ensure your username and password are valid"
            )
        }

        # get access token
        try {
            $body = @{
                refreshToken = $refresh_token
            } | ConvertTo-Json
            $response = Invoke-RestMethod $config.api.urls.login -Method Post -ContentType "application/json" -Body $body
            $access_token = $response.token

            $this.headers = @{
                Authorization = "Bearer $access_token"
            }
        } catch {
            throw Format-Error -Message "Failed to obtain access token!" -Cause $_.Exception.Message -Hints @(
                "Ensure your connection is stable"
            )
        }

        # get project id
        try {
            $url = "$($config.api.urls.project_id)?`$filter=name eq '$tennant'" 
            $response = Invoke-RestMethod $url -Method Get -Headers $this.headers
        } catch {
            throw Format-Error -Message "Failed to get project id!" -Cause $_.Exception.Message
        }

        if ($response.content.Length -eq 1) {
            $this.project_id = $response.content[0].id
        } else {
            throw Format-Error -Message "Failed to get project id!" -Hints @(
                "Expected exactly 1 project with the given Tennant name, found $($response.content.Length)"
                "Maybe '$tennant' is not a valid tennant name?"
            )
        }
    }

    [Object] Get ([String]$url) {
        return Invoke-RestMethod $url -Method Get -Headers $this.headers
    }
    [Object] Post ([String]$url, [Hashtable]$body) {
        return Invoke-RestMethod $url -Method Post -ContentType "application/json" -Headers $this.headers -Body ($body | ConvertTo-Json)
    }

    [String] Deploy ([String]$name, [String]$catalog_id, [Hashtable]$inputs) {
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

    [DeploymentStatus] CheckDeployment ([String]$deployment_id) {
        $response = $this.Get("$($this.url_deployments)/$deployment_id")
        switch ($response.status) {
            "CREATE_INPROGRESS" { return [DeploymentStatus]::InProgress }
            "CREATE_SUCCESSFUL" { return [DeploymentStatus]::Successful }
            "CREATE_FAILED" { return [DeploymentStatus]::Failed }
        }
        throw "Received invalid response: $($response | ConvertTo-Json)"
    }

    [DeploymentStatus] WaitForDeployment ([String]$deployment_id) {
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
        $postparser = $format[$i]["postparser"]
        $regex_info = $format[$i]["regex_info"]
        $regex = if ($format[$i]["regex"]) { $format[$i]["regex"] } else { ".*" } # Match anything if no regex is provided

        function PerElementOperations ([String]$value) {
            if (-not [Regex]::IsMatch($value, "^$regex$")) {
                throw "Invalid ${dbg_name}: row $row, column ${col}: '$value'$(if ($regex_info) { " - $regex_info" })"
            }
            if ($subparser) {
                try { & $subparser $value }
                catch { throw "Invalid ${dbg_name}: row $row, column ${col}: $($_.Exception.Message)" }
            } else {
                $value
            }
        }

        $value = $data_cells[$i].Trim()
        if (-not $value) {
            if ($format[$i]["is_optional"]) { continue }
            else { throw "Missing ${dbg_name}: row $row, column $col" }
        }

        if ($format[$i]["is_unique"] -and $unique_check) {
            if ($unique_check[$field_name]) {
                if ($unique_check[$field_name][$value]) {
                    throw "Duplicate ${dbg_name}: row $row, column ${col}: '$value' was already used"
                } else {
                    $unique_check[$field_name][$value] = $true
                }
            } else {
                $unique_check[$field_name] = @{$value = $true}
            }
        }

        $value = if ($format[$i]["is_array"]) {
            $value.Split([Environment]::NewLine) | ForEach-Object { PerElementOperations $_.Trim() }
        } else {
            PerElementOperations $value
        }

        if ($postparser) {
            try { $value = & $postparser $value }
            catch { throw "Invalid ${dbg_name}: row $row, column ${col}: $($_.Exception.Message)" }
        }
        $body[$field_name] = $value
    }

    $body
}


# Sub- and Post-Parsers
function ParseIP ([String]$raw_input) {
    # This function expects a prevalidated ipv4 address
    # Either with or without CIDR
    # u8.u8.u8.u8 | u8.u8.u8.u8/cidr

    $ip = @{}
    $split_input = $raw_input.Split("/")
    $ip["address"] = $split_input[0]
    if ($split_input[1]) { $ip["net"] = $split_input[1] }

    $ip
}

function ParsePort ([String]$raw_input) {
    # This function expects a prevalidated word:port pair
    # Either with a single port address or a range
    # word:port | word:start-end
    # Checked here:
    # - `word` is a valid protocol
    # - `start` less than or equal to `end`

    $split_input = $raw_input.Split(":")
    $protocol = $split_input[0].Trim().ToUpper()

    if ($protocol -in @("ICMP", "ICMP4", "ICMPV4", "ICMP6", "ICMPV6")) {
        throw "Protocol $protocol not supported - Please use default ICMP services (i.e. 'ICMP ALL' or 'ICMP Echo Request')"
    }
    if ($protocol -notin @("TCP", "UDP")) {
        throw "Invalid Protocol: '$protocol' - Expected TCP or UDP"
    }

    $port = @{ protocol = $protocol }
    $port_addresses = $split_input[1].Split("-")
    $port["start"] = $port_addresses[0].Trim()
    $port["end"] = if ($port_addresses[1]) {
        $port_addresses[1].Trim()
    } else {
        $port_addresses[0].Trim()
    }

    if ([Int]($port["start"]) -gt [Int]($port["end"])) {
        throw "Invalid Range: '$($port["start"])-$($port["end"])'"
    }

    $port
}

function ParseArrayWithAny ([String[]]$array) {
    # This function
    # - returns the input array if it doesn't include "any"
    # - returns an empty array when the input is `@("any")` (case insensitive)
    # - throws in any other case

    if ("any" -notin $array) {
        $array
    } else {
        if ($array.Length -eq 1) { @() }
        else { throw "Can't have more than 1 element when using 'any'" }
    }
}

# Expanders and Converters
function ExpandRulesData ([Hashtable]$data_packet) {
    $gateways = @()
    $data = $data_packet.data
    if ($data.t0_internet) { $gateways += "T0 Internet" }
    if ($data.t1_payload -or -not $gateways.Length) { $gateways += "T1 Payload" }
    $gateways | ForEach-Object {
        $new_packet = DeepCopy $data_packet
        $new_packet.data.gateway = $_
        $new_packet
    }
}

function ConvertSecurityGroupsData ([Hashtable]$data, [ApiAction]$action) {
    $name = "$TEST_PREFIX$($data.name)"
    if ($action -eq [ApiAction]::Delete) {
        return @{
            action = "$action"
            elementsToDelete = @("$name (IPSET)")
        }
    }

    $body = @{
            action = "$action"
            name = $name
            groupType = "IPSET"
    }

    $body["ipAddress"] = Join @($data.addresses | ForEach-Object { Join @($_.address, $_.net) "/" }) ", "
    $comment = Join @((Join $data.servicerequest ", "), $data.hostname, $data.comment) " - "
    if ($comment) { $body["description"] = $comment }
    if ($action -eq [ApiAction]::Update) { $body["elementToUpdate"] = "$name (IPSET)" }
    $body
}

function ConvertServicesData ([Hashtable]$data, [ApiAction]$action) {
    $name = "$TEST_PREFIX$($data.name)"
    if ($action -eq [ApiAction]::Delete) {
        return @{
            action = "$action"
            elementsToDelete = @($name)
        }
    }

    $body =  @{
        action = "$action"
        name = $name
    }

    $used_protocols = @{}
    foreach ($portrange in $data.ports) {
        $protocol = $portrange.protocol.ToUpper()
        $portstring = $portrange.start
        if ($portrange.start -ne $portrange.end) {
            $portstring += "-$($portrange.end)"
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

    $comment = Join @((Join $data.servicerequest ", "), $data.comment) " - "
    if ($comment) { $body["description"] = $comment }
    if ($action -eq [ApiAction]::Update) { $body["elementToUpdate"] = $name }
    $body
}

function ConvertRulesData ([Hashtable]$data, [ApiAction]$action) {
    # TODO: Insert Jenkins ID?
    $name = Join @($data.servicerequest[0], $data.index, "Auto") "_"
    $name = "${TEST_PREFIX}$name"
    if ($action -eq [ApiAction]::Delete) {
        return @{
            action = "$action"
            gateway = $data.gateway
            elementsToDelete = @($name)
        } 
    }

    $body = @{
        action = "$action"
        name = $name
        gateway = $data.gateway
        firewallAction = "Allow"
        sourceType = if ($data.sources.Length) { "Group" } else { "Any" }
        destinationType = if ($data.destinations.Length) { "Group" } else { "Any" }
        serviceType = if ($data.services.Length) { "Service" } else { "Any" }
        sources = @($data.sources | ForEach-Object { "${TEST_PREFIX}$_ (IPSET)" })
        destinations = @($data.destinations | ForEach-Object { "${TEST_PREFIX}$_ (IPSET)" })
        services = @($data.services | ForEach-Object { "${TEST_PREFIX}$_" })
    }

    if ($data.comment) { $body["comment"] = $data.comment }
    if ($action -eq [ApiAction]::Update) { $body["elementToUpdate"] = $name }
    $body
}

# Data Configs
function Get-SecurityGroupsConfig ([Hashtable]$config) {
    @{
        format = @(
            @{
                dbg_name = "Group Name"
                field_name = "name"
                regex = $config.regex.groupname
                is_unique = $true
            }
            @{
                dbg_name = "IP-Address"
                field_name = "addresses"
                regex = $config.regex.ip_cidr
                is_array = $true
                subparser = "ParseIP"
            }
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
                dbg_name = "NSX-Servicerequest"
                field_name = "servicerequest"
                regex = $config.regex.servicerequest
                is_optional = $true
                is_array = $true
            }
        )
        resource_name = "Security Group"
        sheet_name = $config.excel.sheetnames.security_groups
        catalog_id = $config.api.catalog_ids.security_groups
        ddos_sleep_time = 1.0
        converter = {
            param ([Hashtable]$data, [ApiAction]$action)
            ConvertSecurityGroupsData $data $action
        }
    }
}

function Get-ServicesConfig ([Hashtable]$config) {
    @{
        format = @(
            @{
                dbg_name = "Group Name"
                field_name = "name"
                regex = $config.regex.groupname
                is_unique = $true
            }
            @{
                dbg_name = "Port"
                field_name = "ports"
                regex = $config.regex.port
                subparser = "ParsePort"
                is_array = $true
            }
            @{
                dbg_name = "Comment"
                field_name = "comment"
                is_optional = $true
            }
            @{
                dbg_name = "NSX-Servicerequest"
                field_name = "servicerequest"
                regex = $config.regex.servicerequest
                is_optional = $true
                is_array = $true
            }
        )
        resource_name = "Service"
        sheet_name = $config.excel.sheetnames.services
        catalog_id = $config.api.catalog_ids.services
        ddos_sleep_time = 1.0
        converter = {
            param ([Hashtable]$data, [ApiAction]$action)
            ConvertServicesData $data $action 
        }
    }
}

function Get-RulesConfig ([Hashtable]$config) {
    @{
        format = @(
            @{
                dbg_name = "NSX-Index"
                field_name = "index"
                regex = "[1-9][0-9]*"
                regex_info = "Index must be an integer greater than 0!"
                is_unique = $true
            }
            @{
                dbg_name = "NSX-Source"
                field_name = "sources"
                regex = $config.regex.groupname
                regex_info = "Please use a Security Group Name or 'any'"
                postparser = "ParseArrayWithAny"
                is_array = $true
            }
            @{
                dbg_name = "NSX-Destination"
                field_name = "destinations"
                regex = $config.regex.groupname
                regex_info = "Please use a Security Group Name or 'any'"
                postparser = "ParseArrayWithAny"
                is_array = $true
            }
            @{
                dbg_name = "NSX-Ports"
                field_name = "services"
                regex = $config.regex.groupname
                regex_info = "Please use a Service Name or 'any'"
                postparser = "ParseArrayWithAny"
                is_array = $true
            }
            @{
                dbg_name = "NSX-Description"
                field_name = "comment"
                is_optional = $true
            }
            @{
                dbg_name = "NSX-Servicerequest"
                field_name = "servicerequest"
                regex = $config.regex.servicerequest
                is_array = $true
            }
            @{
                dbg_name = "NSX-Customer FW"
                field_name = "customer_fw"
                is_optional = $true
            }
            @{
                dbg_name = "T0 Internet"
                field_name = "t0_internet"
                is_optional = $true
            }
            @{
                dbg_name = "T1 Payload"
                field_name = "t1_payload"
                is_optional = $true
            }
        )
        resource_name = "FW-Rule"
        sheet_name = $config.excel.sheetnames.rules
        catalog_id = $config.api.catalog_ids.rules
        additional_deploy_chances = 2
        ddos_sleep_time = 3.0
        expander = {
            param ([Hashtable]$data)
            ExpandRulesData $data
        }
        converter = {
            param ([Hashtable]$data, [ApiAction]$action)
            ConvertRulesData $data $action
        }
    }
}

function HandleDataSheet {
    param (
        [ExcelHandle]$excel_handle,
        [ApiHandle]$api_handle,
        [Hashtable]$sheet_config,
        [Hashtable]$config,
        [ApiAction[]]$actions
    )

    [String]$sheet_name = $sheet_config.sheet_name
    function NothingMoreToDo {
        Write-Host "Filled out creation status for $sheet_name."
        Write-Host "Nothing more to do!"
    }

    # Get Raw Data
    PrintDivider
    Write-Host "Loading data for $sheet_name..."
    [Hashtable[]]$raw_data = $excel_handle.GetSheetData($sheet_config)
    [Int]$num_data = $raw_data.Length
    if ($num_data -eq 0) { Write-Host "Nothing to do!"; return }

    # Parse Data
    [Hashtable]$unique_check_map = @{}
    [Hashtable[]]$to_deploy = @()
    Write-Host "Parsing data for $num_data resource$(PluralityIn $num_data)..."
    for ($i = 0; $i -lt $num_data; $i++) {
        ShowPercentage $i $num_data
        [Hashtable]$data = $raw_data[$i]

        try {
            $to_deploy += @{
                data = ParseDataSheet -data $data -format $sheet_config.format -unique_check $unique_check_map
                row_index = $data.row_index
            }
        } catch {
            $err_message = $_.Exception.Message
            $Host.UI.WriteErrorLine("->> Parse error in ${sheet_name}: $err_message")
            $excel_handle.UpdateCreationStatus($sheet_config, $data.row_index, $err_message.Split(":")[0], $config.color.parse_error)
        }
    }

    [Int]$num_to_deploy = $to_deploy.Length
    Write-Host "$num_to_deploy/$num_data parsed successfully$(Punctuate $num_to_deploy $num_data)"
    if ($num_to_deploy -eq 0) { NothingMoreToDo; return }

    # Expand Data
    if ($sheet_config.expander) {
        $to_deploy = $to_deploy | ForEach-Object { & $sheet_config.expander -data $_ }
        if ($to_deploy.Length -gt $num_to_deploy) {
            $num_to_deploy = $to_deploy.Length
            Write-Host "Expanded data to $num_to_deploy API calls!"
        }
    }

    [String]$last_action = $null
    foreach ($action in $actions) {
        [String]$action_verb = "$action".ToLower()
        if ($last_action) {
            [String]$adverb = if ("$action" -eq $last_action) { "again" } else { "instead" }
            Write-Host "I'll attempt to $action_verb the failed resource$(PluralityIn $num_to_deploy) $adverb."
        }

        $last_action = "$action"

        # Deploy requests
        [Hashtable[]]$deployed = @()
        Write-Host "Deploying $num_to_deploy ${action}-request$(PluralityIn $num_to_deploy)..."
        for ($i = 0; $i -lt $num_to_deploy; $i++) {
            ShowPercentage $i $num_to_deploy
            [Hashtable]$data = $to_deploy[$i].data
            [String]$deployment_name = "$action $($sheet_config.resource_name) - $(Get-Date -UFormat %s -Millisecond 0) - LR Automation"

            try {
                [Hashtable]$inputs = & $sheet_config.converter -data $data -action $action
                $deployed += @{
                    id = $api_handle.Deploy($deployment_name, $sheet_config.catalog_id, $inputs)
                    row_index = $to_deploy[$i].row_index 
                    preconverted = $data
                }
            } catch {
                $Host.UI.WriteErrorLine("->> Deploy error in ${sheet_name}: $($_.Exception.Message)")
                $excel_handle.UpdateCreationStatus($sheet_config, $to_deploy[$i].row_index, "Deployment Failed", $config.color.dploy_error)
            }

            Start-Sleep $sheet_config.ddos_sleep_time # Mandatory because of DDoS protection probably
        }
        
        [Int]$num_deployed = $deployed.Length
        Write-Host "$num_deployed/$num_to_deploy deployed$(Punctuate $num_deployed $num_to_deploy)"
        if ($num_deployed -eq 0) { NothingMoreToDo; return }

        # Await Deployments
        $to_deploy = @()
        Write-Host "Waiting for status of $num_deployed deployment$(PluralityIn $num_deployed)..."
        for ($i = 0; $i -lt $num_deployed; $i++) {
            ShowPercentage $i $num_deployed
            [Hashtable]$deployment = $deployed[$i]
            [DeploymentStatus]$status = $api_handle.WaitForDeployment($deployment.id)

            if ($status -eq [DeploymentStatus]::Successful) {
                $excel_handle.UpdateCreationStatus($sheet_config, $deployment.row_index, "$action Successful", $config.color.success)
            } else {
                $to_deploy += @{
                    data = $deployment.preconverted
                    row_index = $deployment.row_index
                }
            }
        }

        $num_to_deploy = $to_deploy.Length
        [Int]$num_successful = $num_deployed - $num_to_deploy
        Write-Host "$num_successful/$num_deployed ${action_verb}d successfully$(Punctuate $num_successful $num_deployed)"
        if ($num_to_deploy -eq 0) { NothingMoreToDo; return }
    }

    [String]$actions_str = Join @($actions | ForEach-Object { "$_" }) "/"
    [String]$requests_str = "$actions_str-request$(PluralityIn $actions.Length)"
    foreach ($failed in $to_deploy) {
        $row_index = $failed.row_index
        $Host.UI.WriteErrorLine("->> $requests_str for resource at row $row_index in $sheet_name failed")
        $excel_handle.UpdateCreationStatus($sheet_config, $row_index, "$actions_str Failed", $config.color.dploy_error)
    }

    NothingMoreToDo
}

function Main ([String]$conf_path, [String]$specific_action = "") {
    Write-Host "Loading config from $conf_path..."
    [Hashtable]$config = Get-Config $conf_path # might throw
    [Hashtable[]]$sheet_configs = @(
        (Get-SecurityGroupsConfig $config)
        (Get-ServicesConfig $config)
        (Get-RulesConfig $config)
    )

    [ApiAction[]]$default_actions = @([ApiAction]::Create, [ApiAction]::Update)
    [ApiAction[]]$actions = switch ($specific_action.ToLower()) {
        ""       { $default_actions }
        "create" { @([ApiAction]::Create) }
        "update" { @([ApiAction]::Update) }
        "delete" {
            [Array]::Reverse($sheet_configs)
            @([ApiAction]::Delete)
        }

        default {
            throw Format-Error -Message "Failed to parse specified action" -Hints @(
                "'$specific_action' is not a valid request-action"
                "Please use 'create', 'update' or 'delete'"
                "Leave blank to attempt both create and update requests"
            )
        }
    }

    Write-Host "Initialising communication with API..."
    # very dangerously disabling validating certification
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    [ApiHandle]$api_handle = [ApiHandle]::New($config) # might throw

    Write-Host "Opening Excel-instance..."
    [ExcelHandle]$excel_handle = [ExcelHandle]::New($config.excel.filepath) # might throw

    $actions_str = Join ($actions | ForEach-Object { "$_".ToLower() }) "/"
    $sheet_names_str = Join ($sheet_configs | ForEach-Object { $_.sheet_name }) ", "
    Write-Host "Request-Plan: $actions_str resources in $sheet_names_str."

    try {
        foreach ($sheet_config in $sheet_configs) {
            $handle_datasheet_params = @{
                actions = $actions + @($actions | ForEach-Object { @($_) * $sheet_config.additional_deploy_chances })
                excel_handle = $excel_handle
                api_handle = $api_handle
                sheet_config = $sheet_config
                config = $config
            }

            try { HandleDataSheet @handle_datasheet_params | Out-Null }
            catch { $Host.UI.WriteErrorLine($_.Exception.Message) }
        }
    } finally {
        PrintDivider
        Write-Host "Releasing Excel-Instance..."
        $excel_handle.Release()
    }
}

try { Main $ConfigPath $Action }
catch { $Host.UI.WriteErrorLine($_.Exception.Message); exit 666 }
Write-Host "Done!"
