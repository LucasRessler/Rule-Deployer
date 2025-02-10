enum DeploymentStatus {
    InProgress
    Successful
    Failed
}

class ApiHandle {
    [Hashtable]$headers
    [Hashtable]$tenant_map
    [String]$refresh_token

    [String]$username
    [String]$password

    [String]$url_refresh_token
    [String]$url_deployments
    [String]$url_project_id
    [String]$url_items
    [String]$url_login
    
    ApiHandle ([Hashtable]$config) {
        $this.username = $config.api.credentials.username
        $this.password = $config.api.credentials.password
        $this.url_refresh_token = $config.api.urls.refresh_token
        $this.url_deployments = $config.api.urls.deployments
        $this.url_project_id = $config.api.urls.project_id
        $this.url_items = $config.api.urls.items
        $this.url_login = $config.api.urls.login
        $this.tenant_map = @{}
    }

    [Void]Init () {
        # get refresh token
        try {
            $body = @{
                username = $this.username
                password = $this.password
            } | ConvertTo-Json
            $response = Invoke-RestMethod $this.url_refresh_token -Method Post -ContentType "application/json" -Body $body -TimeoutSec 5
            $this.refresh_token = $response.refresh_token
        }
        catch {
            throw Format-Error -Message "Failed to obtain refresh token!" -Cause $_.Exception.Message -Hints @(
                "Ensure that you're connected to the Admin-LAN"
                "Ensure your username and password are valid"
            )
        }

        # get access token
        try {
            $body = @{
                refreshToken = $this.refresh_token
            } | ConvertTo-Json
            $response = Invoke-RestMethod $this.url_login -Method Post -ContentType "application/json" -Body $body
            $access_token = $response.token

            $this.headers = @{
                Authorization = "Bearer $access_token"
            }
        }
        catch {
            throw Format-Error -Message "Failed to obtain access token!" -Cause $_.Exception.Message -Hints @(
                "Ensure your connection is stable"
            )
        }
    }

    [String]TenantID ([String]$tenant) {
        [String]$failed = "-1"
        [String]$cached = $this.tenant_map[$tenant]
        if ($cached -eq $failed) { throw "Tenant $tenant cannot be accessed" }
        elseif ($cached) { return $this.tenant_map[$tenant] }

        # get project id
        try {
            $url = "$($this.url_project_id)?`$filter=name eq '$tenant'" 
            $response = Invoke-RestMethod $url -Method Get -Headers $this.headers
        }
        catch {
            $this.tenant_map[$tenant] = $failed
            throw Format-Error -Message "Failed to get project id for tenant '$tenant'!" -Cause $_.Exception.Message
        }

        if ($response.content.Length -eq 1) {
            [String]$id = $response.content[0].id
            $this.tenant_map[$tenant] = $id
            return $id
        }
        else {
            $this.tenant_map[$tenant] = $failed
            throw Format-Error -Message "Failed to get project id!" -Hints @(
                "Expected exactly 1 project with the given Tenant name, found $($response.content.Length)"
                "Maybe '$tenant' is not a valid tenant name?"
            )
        }
    }

    [Object] Get ([String]$url) {
        return Invoke-RestMethod $url -Method Get -Headers $this.headers
    }
    [Object] Post ([String]$url, [Hashtable]$body) {
        return Invoke-RestMethod $url -Method Post -ContentType "application/json" -Headers $this.headers -Body ($body | ConvertTo-Json)
    }

    [String] Deploy ([String]$name, [String]$tenant, [String]$catalog_id, [Hashtable]$inputs) {
        $body = @{
            projectId = $this.TenantID($tenant)
            deploymentName = $name
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
