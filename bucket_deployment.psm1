using module ".\shared_types.psm1"
using module ".\api_handle.psm1"
using module ".\io_handle.psm1"
using module ".\logger.psm1"
using module ".\utils.psm1"

class DeployBucket {
    [ApiAction[]]$actions
    [DataPacket[]]$to_deploy = @()
    [DataPacket[]]$deployed = @()
    [Int]$action_index = 0

    DeployBucket ([ApiAction[]]$actions) { $this.actions = $actions }
    DeployBucket ([ApiAction[]]$actions, [DataPacket[]]$to_deploy) {
        $this.to_deploy = $to_deploy
        $this.actions = $actions
    }

    [Void] NextAction () { $this.action_index++ }
    [Int] QueuedActions () { return $this.actions.Count - $this.action_index }
    [ApiAction] GetCurrentAction () { return $this.actions[$this.action_index] }
    [ApiAction] GetPreviousAction () { return $this.actions[$this.action_index - 1] }
}

function AlignBucket {
    param ([DeployBucket]$bucket, [IoHandle]$io_handle)
    [ApiAction]$action = $bucket.GetCurrentAction()
    [String]$k_sr = "request_id"; [String]$k_ur = "update_requests"; [String]$k_dt = "date_creation"

    foreach ($data_packet in $bucket.to_deploy) {
        [Hashtable]$data = $data_packet.data
        $data_packet.ClearCache()
        if ($action -eq [ApiAction]::Update -and ($img = $io_handle.GetImage($data_packet.GetImageKeys()))) {
            [String]$sr_cur = $data[$k_sr]; [String]$sr_img = $img[$k_sr]
            [Bool]$sr_changed = $sr_img -and $sr_img -ne $sr_cur
            [String[]]$ur_cur = $data[$k_ur]; [String[]]$ur_img = $img[$k_ur]
            [String[]]$ur_new = $ur_cur + $ur_img
            $data["__old.$k_sr"] = $data[$k_sr]
            $data["__old.$k_ur"] = $data[$k_ur]
            if ($sr_changed) { $ur_new += $sr_cur; $data[$k_sr] = $sr_img }
            $data[$k_ur] = NormalizeArray $ur_new
            $data[$k_dt] = $img[$k_dt]
        } else {
            if ($data["__old.$k_sr"]) { $data[$k_sr] = $data["__old.$k_sr"] }
            if ($data["__old.$k_ur"]) { $data[$k_ur] = $data["__old.$k_ur"] }
        }
    }
}

function DeploySingleBucket {
    param (
        [DeployBucket]$bucket,
        [ApiHandle]$api_handle,
        [IoHandle]$io_handle,
        [Logger]$logger
    )

    $bucket.deployed = @()
    [ApiAction]$action = $bucket.GetCurrentAction()
    [Int]$num_to_deploy = $bucket.to_deploy.Count
    if ($num_to_deploy -eq 0) { return 0 }
    if ($bucket.action_index -gt 0) {
        [ApiAction]$prev_action = $bucket.GetPreviousAction()
        [String]$pl = PluralityIn $num_to_deploy
        [String]$adverb = if ($action -eq $bucket.GetPreviousAction()) { "again" } else { "instead" }
        $logger.Info("$num_to_deploy $prev_action-request$pl previously failed, I'll attempt to $("$action".ToLower()) the resource$pl $adverb.")
    }

    $logger.Info("Deploying $num_to_deploy ${action}-request$(PluralityIn $num_to_deploy)...")
    for ($i = 0; $i -lt $num_to_deploy; $i++) {
        ShowPercentage $i $num_to_deploy
        [DataPacket]$data_packet = $bucket.to_deploy[$i]
        [Hashtable]$resource_config = $data_packet.resource_config
        [Hashtable]$inputs = $data_packet.GetApiConversion($action)
        [String]$name = $data_packet.GetApiConversion([ApiAction]::Create).name
        [String]$date = Get-Date -Format "yyy-MM-dd HH:mm:ss"
        [String]$deployment_name = "$action $(Join @($resource_config.resource_name, $name) " ") - $date - LR Automation"

        try {
            $logger.Debug("Deploying $action-request for $($data_packet.origin_info) over tenant $($data_packet.tenant): '$deployment_name'")
            $data_packet.deployment_id = $api_handle.Deploy($deployment_name, $data_packet.tenant, $resource_config.catalog_id, $inputs)
            $bucket.deployed += $data_packet
        } catch {
            [String]$short_info = "Deployment Failed"
            [String]$message = "Deploy error at $($data_packet.origin_info): $($_.Exception.Message)"
            [OutputValue]$val = [OutputValue]::New($message, $short_info, $data_packet.row_index)
            $io_handle.UpdateOutput($resource_config, $val)
            $logger.Error($message)
        }

        Start-Sleep $resource_config.ddos_sleep_time # Mandatory because of DDoS protection probably
    }

    [Int]$num_deployed = $bucket.deployed.Count
    $logger.Info("$num_deployed/$num_to_deploy deployed$(Punctuate $num_deployed $num_to_deploy)")
    return $num_deployed
}

function AwaitSingleBucket {
    param (
        [DeployBucket]$bucket,
        [ApiHandle]$api_handle,
        [IoHandle]$io_handle,
        [Hashtable]$summary,
        [Logger]$logger
    )

    $bucket.to_deploy = @()
    [ApiAction]$action = $bucket.GetCurrentAction()
    [String]$action_verb = "$action".ToLower()
    [Int]$num_deployed = $bucket.deployed.Count
    if ($num_deployed -eq 0) { return 0 }

    $logger.Info("Waiting for status of $num_deployed $action-request$(PluralityIn $num_deployed)...")
    for ($i = 0; $i -lt $num_deployed; $i++) {
        ShowPercentage $i $num_deployed
        [DataPacket]$deployment = $bucket.deployed[$i]
        [Hashtable]$resource_config = $deployment.resource_config
        [DeploymentStatus]$status = $api_handle.WaitForDeployment($deployment.deployment_id)

        if ($status -eq [DeploymentStatus]::Successful) {
            [String]$short_info = "$action Successful"
            [String]$message = "Resource at $($deployment.origin_info) was ${action_verb}d successfully"
            [String]$requests = @($deployment.data["request_id"]; $deployment.data["update_requests"]) -join "`r`n"
            [OutputValue]$val = [OutputValue]::New($message, $short_info, $deployment.row_index, @{ all_request_ids = $requests })
            $io_handle.UpdateOutput($resource_config, $val)
            $logger.Debug($message)
            if ($summary[$resource_config.resource_name]["successful"]) { $summary[$resource_config.resource_name]["successful"]++ }
            else { $summary[$resource_config.resource_name]["successful"] = 1 }
            [Hashtable]$image = $deployment.GetImageConversion()
            $io_handle.UpdateNsxImage($image, $action)
        } else {
            $logger.Debug("Deployment for resource at $($deployment.origin_info) finished with status Failed")
            $bucket.to_deploy += $deployment
        }
    }

    [Int]$num_successful = $num_deployed - $bucket.to_deploy.Count
    $logger.Info("$num_successful/$num_deployed ${action_verb}d sucessfully$(Punctuate $num_successful $num_deployed)")
    return $bucket.to_deploy.Count
}

function DeployAndAwaitBuckets {
    param (
        [DeployBucket[]]$deploy_buckets,
        [ApiHandle]$api_handle,
        [IoHandle]$io_handle,
        [Hashtable]$summary,
        [Logger]$logger
    )

    [Hashtable]$shared_params = @{
        api_handle = $api_handle
        io_handle  = $io_handle
        logger     = $logger
    }

    function NothingMoreToDo { $logger.Info("Nothing more to do.") }
    [String]$deployments_str = Format-List @($deploy_buckets | ForEach-Object {
        [Int]$n = $_.to_deploy.Count
        if ($n -gt 0) { "$n $($_.GetCurrentAction())-request$(PluralityIn $n)" }
    }); if (-not $deployments_str) { $deployments_str = "--" }
    $logger.section = "Deploy"
    $logger.Info("Queued deployments: $deployments_str")

    while (($deploy_buckets | ForEach-Object { $_.QueuedActions() } | Measure-Object -Sum).Sum -gt 0) {
        $logger.section = "Deploy"
        $deploy_buckets | ForEach-Object { AlignBucket -bucket $_ -io_handle $io_handle }
        if (($deploy_buckets | ForEach-Object {
            DeploySingleBucket -bucket $_ @shared_params
        } | Measure-Object -Sum).Sum -eq 0) { NothingMoreToDo; return }

        $logger.section = "Await"
        if (($deploy_buckets | ForEach-Object {
            AwaitSingleBucket -bucket $_ -summary $summary @shared_params
        } | Measure-Object -Sum).Sum -eq 0) { NothingMoreToDo; return }

        $deploy_buckets | ForEach-Object { $_.NextAction() }
    }

    foreach ($bucket in $deploy_buckets) {
        [String]$actions_str = Join @($bucket.actions | Select-Object -Unique | ForEach-Object { "$_" }) "/"
        [String]$requests_str = "$actions_str-request$(PluralityIn $bucket.actions.Length)"
        foreach ($failed_packet in $bucket.to_deploy) {
            [String]$short_info = "$actions_str Failed"
            [String]$message = Format-Error -Message "$requests_str for resource at $($failed_packet.origin_info) failed" `
                -Hints (DiagnoseFailure $io_handle $failed_packet $bucket.actions)
            [OutputValue]$val = [OutputValue]::New($message, $short_info, $failed_packet.row_index)
            $io_handle.UpdateOutput($failed_packet.resource_config, $val)
            $logger.Error($message)
        }
    }

    NothingMoreToDo
}
