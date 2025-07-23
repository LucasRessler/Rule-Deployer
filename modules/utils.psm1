function Join ([Object[]]$arr, [String]$delim) {
    return ($arr | Where-Object { $_ }) -join $delim
}

function Format-List ([Object[]]$arr, [String]$con = "and") {
    [Int]$end = $arr.Count - 1
    [Int]$part_end = [Math]::Max(0, $arr.Count - 2)
    [String]$part = if ($end -gt 0) { Join $arr[0..$part_end] ", " }
    return Join @($part, $arr[$arr.Count - 1]) " $con "
}

function Format-Error {
    param ([String]$message, [String]$cause, [String[]]$hints)
    if ($cause) { $message += "`r`n  Caused by: " + (Join $cause.Split([Environment]::NewLine) "`r`n  ")}
    foreach ($hint in $hints) { $message += "`r`n  ->> " + (Join $hint.Split([System.Environment]::NewLine) "`r`n    ") }
    return $message
}

function PrintDivider {
    Write-Host "------------------------"
}

function ForEachWithPercentage {
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        $InputObject,
        [Parameter(Mandatory, Position = 0)]
        [scriptBlock]$Process
    )
    begin { [Array]$items = @() }
    process { $items += $InputObject }
    end {
        [Int]$count = $items.count
        for ($i = 0; $i -lt $count; $i++) {
            Write-Host -NoNewline "...$([Math]::Floor(($i * 100 + 50) / $count))%`r"
            & $Process $items[$i]
        }
    }
}

function PluralityIn ([Int]$number, [String]$singular = "", [String]$plural = "s") {
    if ($number -eq 1) { $singular } else { $plural }
}

function Punctuate ([Int]$achieved, [Int]$total) {
    if ($achieved -gt $total -or $achieved -lt 0) { return "!? >:O" } # Impossible case
    if ($total -eq 0) { return "." }                                  # 0/0 case

    [Float]$ratio = [Math]::Round($achieved / $total, 2)
    if ($ratio -eq 1.00)     { return "! :D" }
    elseif ($ratio -ge 0.75) { return ". :)" }
    elseif ($ratio -ge 0.25) { return " :/" }
    else                     { return "... :(" }
}

function NormalizeArray ([String[]]$array) {
    return @($array | Where-Object { $_ } | Select-Object -Unique)
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
            $collapsed = CollapseNested $nested_obj[$val] $keys[1..$keys.Count]
            try { $result += $collapsed | ForEach-Object { $_[$keys[0]] = $val; $_["__o"] = ".${val}$($_["__o"])"; $_ } }
            catch { return $nested_obj }
        }
        return $result
    } elseif ($keys.Count -gt 0) { $i = 0; $nested_obj | ForEach-Object { if ($_ -is [Hashtable]) { $_["__o"] = "[$i]" }; $i++; $_ } }
    else { $nested_obj }
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

function UrlDecode ([String]$url) {
    [String[]]$secs = $url.Split("%")
    [String]$decode = $secs[0]
    [Byte[]]$bytes = @()
    foreach ($sec in $secs[1..$secs.Length]) {
        $bytes += [Byte]"0x$($sec.SubString(0, 2))"
        $rem = $sec.SubString(2, $sec.Length - 2)
        if ($rem) { $decode += [System.Text.Encoding]::UTF8.GetString($bytes) + $rem; $bytes = @() }
    }
    return $decode + [System.Text.Encoding]::UTF8.GetString($bytes) 
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
                $out += "`r`n" + (CustomConvertToJson $sub ($ilv + 1) $ind)
            }
            return "$out$(if ($comma) { "`r`n" + $ind * $ilv })]"
        }

        ($obj -is [Hashtable]) {
            [String[]]$keys = $obj.Keys
            [Array]::Sort($keys)
            $out += "{"; $comma = $false
            foreach ($key in $keys) {
                if ($comma) { $out += ","} else { $comma = $true }
                $out += "`r`n" + (CustomConvertToJson -key $key -obj $obj[$key] -ilv ($ilv + 1) -ind $ind)
            }
            return "${out}$(if ($comma) { "`r`n" + $ind * $ilv })}"
        }

        ($null -eq $obj) { return "${out}[]"}

        default { return "${out}$($obj.ToString() | ConvertTo-Json -Depth 1)"}
    }
}

function Assert-EnvVars {
    param([String[]]$dbg, [String[]]$var, [String[]]$val)
    [String[]]$missing_vals = @()
    for ($i = 0; $i -lt $val.Count; $i++) {
        if (!$val[$i]) { $missing_vals += Format-Error -Message "$($dbg[$i]) was not provided" -Hints "Set the $($var[$i]) environment variable" }
    };  if ($missing_vals.Count) { throw Format-Error -Message "Some required values were not provided" -Hints $missing_vals }
}

function HintAtUnauthorized {
    param ($exception, [String]$portal_name)
    [String[]]$hints = if ($exception.Response.StatusCode -eq 401) { @("Make sure your $portal_name credentials are valid") } else { @() }
    return Format-Error -Message $exception.Message -Hints $hints
}

function Get-BasicAuthHeader {
    param([String]$user, [String]$pswd)
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("${user}:${pswd}")
    return @{ Authorization = "Basic $([Convert]::ToBase64String($bytes))" }
}

# Sadly necessary for many of our internal APIs
function Initialize-SessionSecurity {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not ("TrustAllCertsPolicy" -as [type])) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
}
