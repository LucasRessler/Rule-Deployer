$FILE_PATH = "$HOME\OneDrive - Deutsche Telekom AG\Dokumente\Input-Data\Kopie von FW rules TSA-v1.xlsx"
$SHEETNAME_PORTGROUPS = "TSA-Portgroups"
$SHEETNAME_SERVERGROUPS = "TSA-Servergroups"
$SHEETNAME_RULES = "TSA-Rules"
$MIN_OUTCOL_PORTGROUPS = 5
$MIN_OUTCOL_SERVERGROUPS = 6
$MIN_OUTCOL_RULES = 8

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
$COLOR_SUCCESS = 4697456 # Light Green

function ParseDataSheet {
    param(
        [hashtable]$data,
        [hashtable[]]$format
    )

    $data_cells = $data["cells"]
    $row = $data["row_index"]
    $body = @{}

    for ($i = 0; $i -lt $format.Length; $i++) {
        $col = [char]([int][char]'A' +  $i)
        $field_name = $format[$i]["field_name"]
        $dbg_name = $format[$i]["dbg_name"]
        $subparser = $format[$i]["subparser"]
        $regex = if (-not $format[$i]["regex"]) {
            ".*"
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
            foreach ($entry in $data_cells[$i].Split([Environment]::NewLine)) {
                if (-not [regex]::IsMatch($entry.Trim(), "^$regex$")) {
                    throw "Invalid $dbg_name in row $row, column ${col}: '" + $entry.Trim() + "'"
                }

                $body[$field_name] += if ($subparser) {
                    try {
                        & $subparser $entry.Trim()
                    } catch {
                        throw "Invalid $dbg_name in row $row, column ${col} - " + $_.Exception.Message
                    }
                } else {
                    $entry.Trim()
                }
            }
        } else {
            if (-not [regex]::IsMatch($data_cells[$i].Trim(), "^$regex$")) {
                throw "Invalid $dbg_name in row $row, column ${col}: '" + $data_cells[$i].Trim() + "'"
            }

            $body[$field_name] = if ($subparser) {
                try {
                    & $subparser $data_cells[$i].Trim()
                } catch {
                    throw "Invalid $dbg_name in row $row, column ${col} - " + $_.Exception.Message
                }
            } else {
                $data_cells[$i].Trim()
            }
        }
    }

    return $body | ConvertTo-Json
}

# Subparsers
function ParseIP([string]$raw_input) {
    $ip = @{}

    $split_input = $raw_input.Split("/")
    $ip["address"] = $split_input[0]
    if ($split_input[1]) {
        $ip["net"] = $split_input[1]
    }

    return $ip
}

function ParsePort([string]$raw_input) {
    $port = @{}

    $split_input = $raw_input.Split(":")
    $port["protocol"] = $split_input[0].Trim()

    $port_addresses = $split_input[1].Split("-")
    $port["start"] = $port_addresses[0].Trim()
    if ($port_addresses[1]) {
        $port["end"] = $port_addresses[1].Trim()
    }

    return $port
}

# Sheet Parsers
function ParseServergroupsData {
    param (
        [hashtable]$data
    )

    $format = @(
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
        }
    )

    return ParseDataSheet -data $data -format $format 
}

function ParsePortgroupsData {
    param (
        [hashtable]$data
    )

    $format = @(
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
        }
    )

    return ParseDataSheet -data $data -format $format
}

function ParseRulesData {
    param (
        [hashtable]$data
    )

    $format = @(
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
        },
        @{
            dbg_name = "NSX-Customer FW"
            field_name = "customer_fw"
            is_optional = $true
        }
    )

    return ParseDataSheet -data $data -format $format
}

function Update-CreationStatus {
    param (
        [System.__ComObject]$excel,
        [string]$sheet_name,
        [int]$min_output_column,
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

    $output_column = [math]::max($min_output_column, $sheet.UsedRange.Columns.Count)
    $cell = $sheet.Cells.Item($row, $output_column)
    $cell.Value = $value
    $cell.Font.Color = $color
}

function Get-ExcelData {
    param (
        [System.__ComObject]$excel,
        [int]$min_output_column,
        [string]$sheet_name
    )

    try {
        $sheet = $excel.Worksheets.Item($sheet_name)
    }
    catch {
        throw "Sheet '$sheet_name' could not be opened! :("
    }

    $num_rows = $sheet.UsedRange.Rows.Count
    $output_column = [math]::max($min_output_column, $sheet.UsedRange.Columns.Count)
    $data = @()

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

    return $data
}

function HandleDataSheet {
    param (
        [System.__ComObject]$excel,
        [string]$sheet_name,
        [int]$min_output_column,
        [string]$parse_function
    )

    Write-Output $DIVIDER
    Write-Output "Loading data for $sheet_name..."
    $sheet_data = Get-ExcelData -excel $excel -sheet_name $sheet_name -min_output_column $min_output_column
    $num_total = $sheet_data.Length
    $num_successful = 0
    
    Write-Output "Building and sending $num_total API calls for $sheet_name..."
    # TODO: Optimally, this for loop would be executed concurrently
    foreach ($data in $sheet_data) {
        try {
            $data_json = & $parse_function -data $data
        }
        catch {
            $Host.UI.WriteErrorLine("->> Parse error in $sheet_name : " + $_.Exception.Message)
            Update-CreationStatus -excel $excel -sheet_name $sheet_name -min_output_column $min_output_column -row $data["row_index"] -value "Parse Error" -color $COLOR_PARSE_ERROR
            Continue
        }

        Write-Output $data_json

        # TODO: Perform API-call, fill out creation status accordingly 
        # ----> $result = Invoke-RestMethod [...]

        Update-CreationStatus -excel $excel -sheet_name $sheet_name -min_output_column $min_output_column -row $data["row_index"] -value "Created Successfully" -color $COLOR_SUCCESS
        $num_successful += 1
    }

    if ($sheet_data.Length -gt 0) {
        Write-Output "$num_successful/$num_total created successfully!"
        Write-Output "Filled out Creation Status for $sheet_name!"
    } else {
        Write-Output "Nothing to do for $sheet_name!"
    }
}

function Main {
    [CmdletBinding()]
    param (
        [string]$file_path = $FILE_PATH,
        [string]$sheetname_servergroups = $SHEETNAME_SERVERGROUPS,
        [string]$sheetname_portgroups = $SHEETNAME_PORTGROUPS,
        [string]$sheetname_rules = $SHEETNAME_RULES,
        [int]$min_outcol_servergroups = $MIN_OUTCOL_SERVERGROUPS,
        [int]$min_outcol_portgroups = $MIN_OUTCOL_PORTGROUPS,
        [int]$min_outcol_rules = $MIN_OUTCOL_RULES

    )

    Write-Output "Opening Excel-Instance..."
    $excel = New-Object -ComObject Excel.Application
    # $excel.Visible = $true

    try {
        $excel.WorkBooks.Open($file_path) | Out-Null
    }
    catch {
        $Host.UI.WriteErrorLine("Failed to open '$file_path' :(")
        $Host.UI.WriteErrorLine("The file might not exist or it might currently be in use")
        exit 666
    }

    HandleDataSheet -excel $excel -sheet_name $sheetname_servergroups -min_output_column $min_outcol_servergroups -parse_function ParseServergroupsData
    HandleDataSheet -excel $excel -sheet_name $sheetname_portgroups -min_output_column $min_outcol_portgroups -parse_function ParsePortgroupsData
    HandleDataSheet -excel $excel -sheet_name $sheetname_rules -min_output_column $min_outcol_rules -parse_function ParseRulesData

    Write-Output $DIVIDER
    Write-Output "Done!"
    $excel.Visible = $true
    # $excel.Quit()
}

Main