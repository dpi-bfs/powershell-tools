function Get-FlowByDisplayName {
<#
.SYNOPSIS
    Lists Power Automate flows in an environment filtered by display name, including owner principals.

.DESCRIPTION
    Uses Get-AdminFlow to list flows and filters by DisplayName.
    Owner information is derived from CreatedBy and (if present) LastModifiedBy.
    Optionally resolves owner objectIds to display names/emails using Microsoft Graph, attempting:
      1) User
      2) Service principal (app)
      3) Group

.PARAMETER EnvironmentId
    The GUID of the Power Platform environment.

.PARAMETER DisplayName
    The full or partial display name of the flow.

.PARAMETER Contains
    Use a partial (contains) match instead of an exact match.

.PARAMETER IncludeDeleted
    Include deleted flows (if still within the restore window).

.PARAMETER ResolveOwners
    Resolve owner objectIds to display name/email/type using Microsoft Graph.

.EXAMPLE
    Get-FlowByDisplayName -EnvironmentId $envId -DisplayName "VvvAItoSharePointFlowNONPROD"

.EXAMPLE
    Get-FlowByDisplayName -EnvironmentId $envId -DisplayName "VvvAI" -Contains

.EXAMPLE
    Get-FlowByDisplayName -EnvironmentId $envId -DisplayName "VvvAI" -Contains -IncludeDeleted

.EXAMPLE
    Get-FlowByDisplayName -EnvironmentId $envId -DisplayName "VvvAI" -Contains -ResolveOwners

.EXAMPLE
    Get-FlowByDisplayName -EnvironmentId $envId -DisplayName "VvvAI" -Contains -ResolveOwners | Select DisplayName, FlowName, OwnerObjectIds, OwnerDisplayNames, OwnerEmails, OwnerTypes | Format-Table -AutoSize
#>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$EnvironmentId,

        [Parameter(Mandatory)]
        [string]$DisplayName,

        [switch]$Contains,

        [switch]$IncludeDeleted,

        [switch]$ResolveOwners
    )

    $flows = Get-AdminFlow -EnvironmentName $EnvironmentId -IncludeDeleted:$IncludeDeleted

    if ($Contains) {
        $flows = $flows | Where-Object { $_.DisplayName -like "*$DisplayName*" }
    }
    else {
        $flows = $flows | Where-Object { $_.DisplayName -eq $DisplayName }
    }

    # ---------------------------
    # Graph setup + resolver cache
    # ---------------------------
    $graphReady = $false
    $resolveCache = @{} # key: objectId, value: @{ Type=...; DisplayName=...; Email=... }

    if ($ResolveOwners) {
        try {
            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
            Import-Module Microsoft.Graph.Users -ErrorAction Stop
            Import-Module Microsoft.Graph.Groups -ErrorAction Stop
            Import-Module Microsoft.Graph.Applications -ErrorAction Stop

            $ctx = $null
            try { $ctx = Get-MgContext } catch { $ctx = $null }

            if (-not $ctx) {
                # You may need admin consent for these scopes depending on tenant policy
                Connect-MgGraph -Scopes @("User.Read.All","Group.Read.All","Application.Read.All") | Out-Null
            }

            $graphReady = $true
        }
        catch {
            Write-Warning ("ResolveOwners requested but Microsoft Graph isn't available/connected. Returning objectIds only. " + $_.Exception.Message)
            $graphReady = $false
        }
    }

    function Resolve-Principal {
        param(
            [Parameter(Mandatory)]
            [string]$ObjectId
        )

        if (-not $ObjectId) { return $null }

        if ($resolveCache.ContainsKey($ObjectId)) {
            return $resolveCache[$ObjectId]
        }

        $result = $null

        if ($graphReady) {
            # 1) Try User
            try {
                $u = Get-MgUser -UserId $ObjectId -Property "displayName,mail,userPrincipalName,id" -ErrorAction Stop
                $email = $null
                if ($u.Mail) { $email = $u.Mail } elseif ($u.UserPrincipalName) { $email = $u.UserPrincipalName }

                $result = @{
                    Type        = "User"
                    DisplayName = $u.DisplayName
                    Email       = $email
                }
            }
            catch {
                # ignore
            }

            # 2) Try Service Principal (Application)
            if (-not $result) {
                try {
                    $sp = Get-MgServicePrincipal -ServicePrincipalId $ObjectId -Property "displayName,appId,id" -ErrorAction Stop
                    $result = @{
                        Type        = "ServicePrincipal"
                        DisplayName = $sp.DisplayName
                        Email       = $null
                    }
                }
                catch {
                    # ignore
                }
            }

            # 3) Try Group
            if (-not $result) {
                try {
                    $g = Get-MgGroup -GroupId $ObjectId -Property "displayName,mail,id" -ErrorAction Stop
                    $result = @{
                        Type        = "Group"
                        DisplayName = $g.DisplayName
                        Email       = $g.Mail
                    }
                }
                catch {
                    # ignore
                }
            }
        }

        if (-not $result) {
            $result = @{
                Type        = $null
                DisplayName = $null
                Email       = $null
            }
        }

        $resolveCache[$ObjectId] = $result
        return $result
    }

    foreach ($flow in $flows) {

        # Owners as plain arrays (PS 5.1 safe)
        $owners = @()

        # CreatedBy is the primary owner signal in your tenant output
        if ($flow.CreatedBy -and $flow.CreatedBy.objectId) {
            $owners += [PSCustomObject]@{
                OwnerObjectId    = $flow.CreatedBy.objectId
                OwnerDisplayName = $null
                OwnerEmail       = $null
                OwnerType        = $null
                Source           = "CreatedBy"
            }
        }

        # LastModifiedBy as an object (if present and distinct)
        if ($flow.LastModifiedBy -and
            $flow.LastModifiedBy.objectId -and
            (-not $flow.CreatedBy -or -not $flow.CreatedBy.objectId -or ($flow.LastModifiedBy.objectId -ne $flow.CreatedBy.objectId))) {

            $owners += [PSCustomObject]@{
                OwnerObjectId    = $flow.LastModifiedBy.objectId
                OwnerDisplayName = $null
                OwnerEmail       = $null
                OwnerType        = $null
                Source           = "LastModifiedBy"
            }
        }

        # Optional Graph resolution (best-effort; may be user, service principal, or group)
        if ($graphReady -and $owners.Count -gt 0) {
            foreach ($o in $owners) {
                if (-not $o.OwnerObjectId) { continue }

                $r = Resolve-Principal -ObjectId $o.OwnerObjectId
                if ($r) {
                    $o.OwnerDisplayName = $r.DisplayName
                    $o.OwnerEmail = $r.Email
                    $o.OwnerType = $r.Type
                }
            }
        }

        # Flatten for table/CSV friendliness
        $ownerObjectIds    = ($owners | Where-Object OwnerObjectId    | ForEach-Object OwnerObjectId)    -join '; '
        $ownerDisplayNames = ($owners | Where-Object OwnerDisplayName | ForEach-Object OwnerDisplayName) -join '; '
        $ownerEmails       = ($owners | Where-Object OwnerEmail       | ForEach-Object OwnerEmail)       -join '; '
        $ownerTypes        = ($owners | Where-Object OwnerType        | ForEach-Object OwnerType)        -join '; '

        [PSCustomObject]@{
            DisplayName        = $flow.DisplayName
            FlowName           = $flow.FlowName
            Enabled            = $flow.Enabled
            State              = $flow.State
            Deleted            = $flow.Deleted
            CreatedTime        = $flow.CreatedTime
            LastModifiedTime   = $flow.LastModifiedTime
            OwnerObjectIds     = $ownerObjectIds
            OwnerDisplayNames  = $ownerDisplayNames
            OwnerEmails        = $ownerEmails
            OwnerTypes         = $ownerTypes
            Owners             = $owners
        }
    }
}
