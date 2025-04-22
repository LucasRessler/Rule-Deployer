using module ".\shared_types.psm1"

class NsxApiHandle {
    [String]$base_url
    [Hashtable]$headers

    NsxApiHandle ([String]$base_url) {
        if (-not $base_url)         { throw "NSX Host Domain was not provided" }
        if (-not $env:nsx_user)     { throw "NSX Username was not provided" }
        if (-not $env:nsx_password) { throw "NSX Password was not provided" }
        [Byte[]]$bytes = [System.Text.Encoding]::UTF8.GetBytes("${env:nsx_user}:${env:nsx_password}")
        [String]$encoded = [Convert]::ToBase64String($bytes) 
        $this.base_url = $base_url
        $this.headers = @{
            Authorization = "Basic $encoded"
        }
    }

    [PSCustomObject] ApiGet ([String]$path) {
        [String]$url = "$($this.base_url)/api/v1/$path"
        return Invoke-RestMethod -Method Get -Uri $url -Headers $this.headers
    }
    [String] SecurityGroupPath ([String]$tenant, [String]$name) {
        return "infra/domains/default/groups/${tenant}_grp-ips-${name}"
    }
    [String] ServicePath ([String]$tenant, [String]$name) {
        return "infra/services/${tenant}_svc-${name}"
    }
    [String] RulePath ([String]$tenant, [String]$gateway, [String]$name) {
        [String]$policy = "${tenant}_Customer_Perimeter_${gateway}_Section01"
        return "infra/domains/default/security-policies/${policy}/rules/${tenant}_pfwpay-${name}_dfw"
    }
    [String] ResourcePath ([DataPacket]$data_packet) {
        [String]$tenant = $data_packet.tenant
        [String]$name = $data_packet.GetApiConversion([ApiAction]::Create).name
        [String]$gateway = $data_packet.data.gateway -replace '^\S+\s*', ""
        switch ($data_packet.resource_config.id) {
            ([ResourceId]::SecurityGroup) { return $this.SecurityGroupPath($tenant, $name)  }
            ([ResourceId]::Service)       { return $this.ServicePath($tenant, $name)        }
            ([ResourceId]::Rule)          { return $this.RulePath($tenant, $gateway, $name) }
        }
        return $null
    }
    [Boolean] ResourceExists ([DataPacket]$data_packet) {
        try { return $null -ne $this.ApiGet($this.ResourcePath($data_packet)) }
        catch [System.Net.WebException] {
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq 404) { return $false }
            else { throw $_.Exception }
        }
    }
}
