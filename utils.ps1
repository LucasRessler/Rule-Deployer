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

function ConvertTo-Hashtable {
    [CmdletBinding()]
    param(
        [parameter(ValueFromPipeline)]
        [PSCustomObject]$input_object
    )

    process {
        function ConvertRecursive ([Object]$obj) {
            if ($obj -is [PSCustomObject]) {
                [Hashtable]$hash = @{}
                foreach ($key in $obj.PSObject.Properties.Name) { 
                    $hash[$key] = ConvertRecursive $obj.$key
                }
                return $hash
            } elseif ($obj -is [Array]) {
                return @($obj | ForEach-Object {
                    if ($_ -is [String] -or $_ -is [Boolean] -or $_ -is [Int] -or $_ -is [Double]) { $_ }
                    else { ConvertRecursive $_ }
                })
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