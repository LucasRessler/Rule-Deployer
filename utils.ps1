function Join ([Object[]]$arr, [String]$delim) {
    [String]$s = ""
    foreach ($x in $arr) { if ($x) { $s += "$(if ($s) {$delim})$x" } }
    return $s
}

function Format-Error {
    param ([String]$message, [String]$cause, [String[]]$hints)
    if ($cause) { $message += "`n| Caused by: " + (Join $cause.Split([Environment]::NewLine) "`n| ")}
    foreach ($hint in $hints) { $message += "`n| ->> " + (Join $hint.Split([System.Environment]::NewLine) "`n|   ") }
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

function ConvertTo-Hashtable {
    [CmdletBinding()]
    param(
        [parameter(ValueFromPipeline)]
        [PSCustomObject]$input_object
    )

    process {
        function ConvertRecursive ([Object]$obj) {
            if ($obj -is [Array]) {
                return @($obj | ForEach-Object {
                    if ($_ -is [String] -or $_ -is [Boolean] -or $_ -is [Int] -or $_ -is [Double]) { $_ }
                    else { ConvertRecursive $_ }
                })
            } elseif ($obj -is [PSCustomObject]) {
                [Hashtable]$hash = @{}
                foreach ($key in $obj.PSObject.Properties.Name) {
                    $hash[$key] = ConvertRecursive $obj.$key
                }
                return $hash
            } else {
                return $obj
            }
        }
        ConvertRecursive $input_object
    }
}

function Assert-Format ($x, [Hashtable]$format, $parent = $null) {
    [String[]]$faults = @()
    foreach ($key in $format.Keys) {
        $fullname = Join @($parent, $key) "."
        if ($null -eq $x.$key) { $faults += "Missing field '$fullname'"; continue }
        if ("" -eq $x.$key) { $faults += "Field '$fullname' is empty"}
        $faults += Assert-Format $x.$key $format.$key $fullname
    }
    return $faults
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

function CollapseNested ($nested_obj, [String[]]$keys) {
    if ($keys.Count -gt 0 -and $nested_obj -is [Hashtable]) {
        $result = @()
        foreach ($val in $nested_obj.Keys) {
            $inner = $nested_obj[$val]
            $collapsed = if ($inner -is [Hashtable]) { CollapseNested $inner $keys[1..$keys.Count] } else { $inner }
            try { $result += $collapsed | ForEach-Object { $_[$keys[0]] = $val; $_ } }
            catch { return $nested_obj }
        }
        return $result
    } else { $nested_obj }
}

function ExpandCollapsed ($collapsed_obj, [String[]]$keys) {
    if (-not $keys.Count) { return $collapsed_obj }
    $f_map = @{}; $r_map = @{}
    foreach ($map in $collapsed_obj) {
        $vals = $map["$($keys[0])"]; $new_map = @{}
        foreach ($key in $map.Keys) { if ($key -ne $keys[0]) { $new_map[$key] = $map[$key] } }
        foreach ($val in $vals) {
            if ($f_map["$val"]) { $f_map["$val"] += $new_map }
            else { $f_map["$val"] = @($new_map) }
        }
    }
    foreach ($val in $f_map.Keys) { $r_map[$val] = ExpandCollapsed $f_map[$val] $keys[1..$keys.Count] }
    return $r_map
}

function CustomConvertToJson {
    param (
        $obj,
        [Int]$ilv = 0,
        [String]$ind = "    ",
        [String]$key = $null
    )

    [String]$out = $ind * $ilv
    if ($key) { $out += "`"$key`": " }
    switch ($true) {
        ($obj -is [Array]) {
            $out += "["; $comma = $false
            foreach ($sub in $obj) {
                if ($comma) { $out += ","} else { $comma = $true }
                $out += "`n" + (CustomConvertToJson $sub ($ilv + 1) $ind)
            }
            return "$out$(if ($comma) { "`n" + $ind * $ilv })]"
        }

        ($obj -is [Hashtable]) {
            [String[]]$keys = $obj.Keys
            [Array]::Sort($keys)
            $out += "{"; $comma = $false
            foreach ($key in $keys) {
                if ($comma) { $out += ","} else { $comma = $true }
                $out += "`n" + (CustomConvertToJson -key $key -obj $obj[$key] -ilv ($ilv + 1) -ind $ind)
            }
            return "${out}$(if ($comma) { "`n" + $ind * $ilv })}"
        }

        ($null -eq $obj) { return "${out}null"}

        default { return "${out}$($obj.ToString() | ConvertTo-Json -Depth 1)"}
    }
}
