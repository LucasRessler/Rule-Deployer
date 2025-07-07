using module ".\io_handle.psm1"
using module ".\logger.psm1"

# Sub- and Post-Parsers
function FailOnMatch ([String]$value, [String]$regex, [String]$fail_message) {
    if ([Regex]::IsMatch($value, "^$regex$")) { throw $fail_message }
    else { $value }
}

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

function ParseSecgroupReference ([String]$raw_input) {
    # formats security groups references to look like <Secgroup-Name> (<TYPE>)

    if ($raw_input -eq "any") { return $raw_input }
    if ($raw_input -match '(?i)^(\S+)(\s*\((ipset|group|segment|vm)\))?$') {
        if ($null -eq $Matches[2]) { return "$($Matches[1]) (IPSET)" }
        else { return "$($Matches[1]) ($($Matches[3].ToUpper()))" }
    }; return $raw_input
}

function ParseArrayWithAny ([String[]]$array) {
    # returns the input array if it doesn't include "any"
    # returns an empty array when the input is `@("any")` (case insensitive)
    # throws in any other case

    if ("any" -notin $array) { return $array }
    elseif ($array.Length -eq 1) { return @() }
    else { throw "Can't have more than 1 element when using 'any'" }
}

# General Parser
function ParseIntermediate {
    param(
        [DataPacket]$data_packet,
        [Hashtable]$unique_check_map,
        [Bool]$only_deletion,
        [Logger]$logger
    )

    [String[]]$errors = @()
    [Hashtable]$format = $data_packet.resource_config.format
    [DataPacket]$parsed_packet = [DataPacket]::New($data_packet, @{})

    foreach ($key in $format.Keys) {
        $dbg_name = $format[$key]["dbg_name"]
        $is_array = $format[$key]["is_array"]
        $generator = $format[$key]["generator"]
        $subparser = $format[$key]["subparser"]
        $postparser = $format[$key]["postparser"]
        $regex_info = $format[$key]["regex_info"]
        $regex = ` # If no regex is specified, use '.*' to match anything
            if ($format[$key]["regex"]) { $format[$key]["regex"] }
            else { ".*" }
        $value = ` # If generator is specified, use it to create the value
            if ($generator) { & $generator -data $data_packet.data }
            else { $data_packet.data[$key] }

        if (-not $value) {
            [Bool]$optional_for_delete = -not $format[$key]["required_for_delete"] 
            [Bool]$optional = $format[$key]["is_optional"] -or ($only_deletion -and $optional_for_delete)
            if (-not $optional) {
                $hint = if ($generator) { "generated from other values" }
                # Check if an origin string has been created for the value
                elseif ($data_packet.value_origins[$key]) { "Ensure that $($data_packet.value_origins[$key]) is not empty" }
                # Otherwise, use the fieldname
                else { "Ensure that field '$key' is not empty" } 
                $errors += Format-Error -Message "Missing $dbg_name" -Hints @($hint)
            }
            continue
        }

        $value = $value.Trim()
        if (-not $is_array) { $value = $value -join "`r`n" }
        if ($format[$key]["is_unique"] -and $unique_check_map) {
            if ($unique_check_map[$key]) {
                if ($unique_check_map[$key][$value]) {
                    $errors += Format-Error -Message "Duplicate ${dbg_name}" -Hints @(
                        "'$value' was already used"
                        "Ensure that each ${dbg_name} is unique"
                    )
                } else { $unique_check_map[$key][$value] = $true }
            } else { $unique_check_map[$key] = @{ $value = $true } }
        }

        $value = @($value) | ForEach-Object {
            [String]$sub_value = $_
            if (-not [Regex]::IsMatch($sub_value, "^$regex$")) {
                $hints = if ($regex_info) { @($regex_info) }
                $errors += Format-Error -Message "Invalid ${dbg_name}: '$sub_value'" -Hints $hints
            }
            if ($subparser) {
                try { & $subparser $sub_value }
                catch {
                    $errors += Format-Error -Message "Invalid ${dbg_name}: '$sub_value'" -Cause $_.Exception.Message
                    continue
                }
            } else { $_ }
        }

        if ($postparser) {
            try { $value = & $postparser $value }
            catch { $errors += Format-Error -Message "Invalid ${dbg_name}" -Cause $_.Exception.Message }
        }

        $parsed_packet.data[$key] = $value
    }

    if ($errors.Count -gt 1) { throw Format-Error -Message "Multiple Faults" -Hints $errors }
    elseif ($errors.Count -eq 1) { throw $errors[0] }
    foreach ($k in $format.Keys) { $data_packet.data.Remove($k) }
    foreach ($k in $data_packet.data.Keys) {
        [String]$v = $data_packet.data[$k]
        if ($v) { $logger.Warn("Unused value at $($data_packet.origin_info): {'$k': '$v'} will be ignored!") }
    }
    $logger.Debug("Resource at $($data_packet.origin_info) parsed successfully")
    return $parsed_packet
}
