using module ".\shared_types.psm1"
using module ".\utils.psm1"

class NsxApiHandle {
    [String]$base_url
    [Hashtable]$headers
    [Hashtable]$cache = @{}

    NsxApiHandle ([String]$base_url) {
        Assert-EnvVars -dbg @("NSX Username", "NSX Password"   ) `
                       -var @("nsx_user",     "nsx_password"   ) `
                       -val @($env:nsx_user,  $env:nsx_password)
        $this.headers = Get-BasicAuthHeader -user $env:nsx_user -pswd $env:nsx_password
        $this.base_url = $base_url
    }

    [PSCustomObject] ApiGet ([String]$path) {
        if ($null -eq $this.cache[$path]) {
            [String]$url = "$($this.base_url)/api/v1/$path"
            $this.cache[$path] = Invoke-RestMethod -Method Get -Uri $url -Headers $this.headers
        }; return $this.cache[$path]
    }
    [PSCustomObject[]]ApiGetPaging ([String]$path) {
        [String]$paged_path = "PAGED:::$path"
        if ($this.cache[$paged_path]) { return $this.cache[$paged_path] }
        [PSCustomObject]$response = $this.ApiGet($path)
        [PSCustomObject[]]$results = $response.results
        while ($response.cursor) {
            $response = $this.ApiGet("${path}?cursor=$($response.cursor)")
            $results += $response.results
        };  $this.cache[$paged_path] = $results
        return $results
    }

    [String] QualifiedSecurityGroupName ([String]$secgroup_name, [String]$tenant) {
        [String]$type_indicator = "ips"
        if ($secgroup_name -match '(\S+)\s*\((IPSET|GROUP|SEGMENT|VM)\)') {
            switch ($Matches[2]) {
                ("SEGMENT") { $type_indicator = "nsm" }
                ("GROUP")   { $type_indicator = "nest" }
                ("VM")      { $type_indicator = "vm" }
            }
            $secgroup_name = $Matches[1]
        };  return "${tenant}_grp-$type_indicator-$secgroup_name"
    }
    [String] QualifiedServiceName ([String]$service_name, [String]$tenant) {
        return "${tenant}_svc-$service_name"
    }
    [String] QualifiedRuleName ([String]$rule_name, [String]$tenant, [String]$gateway) {
        [String]$onset = switch ($gateway) {
            "Payload"  { "pfwpay" }
            "Internet" { "pfwinet" }
            default    { throw "Unknown Gateway" }
        };  return "${tenant}_${onset}-${rule_name}" 
    }

    [String] SecurityGroupsPath () { return "infra/domains/default/groups" }
    [String] ServicesPath () { return "infra/services" }
    [String] PolicyRulesPath ([String]$tenant, [String]$gateway) {
        [String]$policy = "${tenant}_Customer_Perimeter_${gateway}_Section01"
        return "infra/domains/default/security-policies/${policy}/rules"
    }
    [String] NaiveResourcePath ([DataPacket]$data_packet) {
        [String]$tenant = $data_packet.tenant
        [String]$name = $data_packet.GetApiConversion([ApiAction]::Create).name
        [String]$gateway = $data_packet.data.gateway -replace '^\S+\s*', ""
        switch ($data_packet.resource_config.id) {
            ([ResourceId]::SecurityGroup) { return "$($this.SecurityGroupsPath())/$($this.QualifiedSecurityGroupName($name, $tenant))"                  }
            ([ResourceId]::Service)       { return "$($this.ServicesPath())/$($this.QualifiedServiceName($name, $tenant))"                              }
            ([ResourceId]::Rule)          { return "$($this.PolicyRulesPath($tenant, $gateway))/$($this.QualifiedRuleName($tenant, $gateway, $name))"   }
        };  return $null
    }

    [Boolean] SecurityGroupExists ([String]$secgroup_name, [String]$tenant) {
        [PSCustomObject[]]$matches = $this.ApiGetPaging($this.SecurityGroupsPath()) `
        | Where-Object { $_.display_name -eq $this.QualifiedSecurityGroupName($secgroup_name, $tenant) }
        return $matches.Count -gt 0
    }
    [Boolean] ServiceExists ([String]$service_name, [String]$tenant) {
        [PSCustomObject[]]$matches = $this.ApiGetPaging($this.ServicesPath()) | Where-Object {
            ($_.is_default -and $_.display_name -eq $service_name) `
            -or $_.display_name -eq $this.QualifiedServiceName($service_name, $tenant)
        };  return $matches.Count -gt 0
    }
    [Boolean] RuleExists ([String]$rule_name, [String]$tenant, [String]$gateway) {
        [PSCustomObject[]]$matches = $this.ApiGetPaging($this.PolicyRulesPath($tenant, $gateway)) `
        | Where-Object { $_.display_name -eq $this.QualifiedRuleName($rule_name, $tenant, $gateway) }
        return $matches.Count -gt 0
    }
    [Boolean] ResourceExists ([DataPacket]$data_packet) {
        [String]$tenant = $data_packet.tenant
        [String]$name = $data_packet.GetApiConversion([ApiAction]::Create).name
        [String]$gateway = $data_packet.data.gateway -replace '^\S+\s*', ""
        switch ($data_packet.resource_config.id) {
            ([ResourceId]::SecurityGroup) { return $this.SecurityGroupExists($name, $tenant)  }
            ([ResourceId]::Service)       { return $this.ServiceExists($name, $tenant)        }
            ([ResourceId]::Rule)          { return $this.RuleExists($name, $tenant, $gateway) }
        }
        return $false
    }
}
