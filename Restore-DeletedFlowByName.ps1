<#
.SYNOPSIS
  Find and optionally restore deleted Power Automate cloud flows by DisplayName
  in a given Power Platform environment.

.DESCRIPTION
  This script:
   - Enumerates flows using Get-AdminFlow -IncludeDeleted $true
   - Uses Internal.properties.state to detect deleted flows (state = Deleted)
   - Matches flows by DisplayName (exact or contains)
   - Restores flows using Restore-AdminFlow (requires FlowName GUID)

.PARAMETER EnvironmentId
  The GUID of the Power Platform environment.

.PARAMETER DisplayName
  The DisplayName of the flow as shown in Power Automate / Admin Center.

.PARAMETER Contains
  Perform a wildcard (*DisplayName*) match instead of exact match.

.PARAMETER DeletedOnly
  Restrict search to flows whose Internal.properties.state indicates deletion.

.PARAMETER RestoreAll
  Restore all matching flows if more than one is found.

.PARAMETER ListOnly
  List matching flows only; do not restore.

.PARAMETER PreviewCount
  Number of flows to preview if no matches are found.

.EXAMPLE
  .\Restore-DeletedFlowByName.ps1 -EnvironmentId "<ENVIRONMENT-GUID>" -DisplayName "zzVvvAItoSharePointFlowPROD" -DeletedOnly -ListOnly

.EXAMPLE
  .\Restore-DeletedFlowByName.ps1 -EnvironmentId "<ENVIRONMENT-GUID>" -DisplayName "zzVvvAItoSharePointFlowPROD" -DeletedOnly

.NOTES
  - Requires Environment Admin / Power Platform Admin / Global Admin.
  - Deleted flows are recoverable only within Microsoft’s retention window.
  - Restored flows may return disabled and need re-enabling in the UI.
#>


[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
  [Parameter(Mandatory=$true)]
  [ValidateNotNullOrEmpty()]
  [string]$EnvironmentId,

  [Parameter(Mandatory=$true)]
  [ValidateNotNullOrEmpty()]
  [string]$DisplayName,

  [switch]$Contains,
  [switch]$DeletedOnly,
  [switch]$RestoreAll,
  [switch]$ListOnly,
  [int]$PreviewCount = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-AdminModule {
  $modName = 'Microsoft.PowerApps.Administration.PowerShell'
  if (-not (Get-Module -ListAvailable -Name $modName)) {
    Install-Module $modName -Scope CurrentUser -Force -AllowClobber
  }
  Import-Module $modName -Force
}

function Ensure-Login {
  Add-PowerAppsAccount | Out-Null
}

function A($x) { @($x) } # force array
function C($x) { (@($x) | Measure-Object).Count } # safe count under StrictMode
function N([object]$v) {
  if ($null -eq $v) { return '' }
  return (($v.ToString() -replace '\s+', ' ').Trim())
}

function Get-State([object]$flow) {
  try { return (N $flow.Internal.properties.state) } catch { return '' }
}

function Get-Flows([string]$envId) {
  return A (Get-AdminFlow -EnvironmentName $envId -IncludeDeleted $true)
}

function Find-ByName([object[]]$flows, [string]$name, [switch]$containsMatch) {
  $target = N $name
  if ($containsMatch) {
    $pattern = "*$target*"
    return A ($flows | Where-Object { (N $_.DisplayName) -like $pattern })
  } else {
    return A ($flows | Where-Object { (N $_.DisplayName) -eq $target })
  }
}

# ---------------- main ----------------

Ensure-AdminModule
Ensure-Login

Write-Host ("EnvironmentId : {0}" -f $EnvironmentId)
Write-Host ("DisplayName   : {0}" -f $DisplayName)
Write-Host ("Match mode    : {0}" -f ($(if ($Contains) { 'Contains' } else { 'Exact' })))
Write-Host ("DeletedOnly   : {0}" -f $DeletedOnly)
Write-Host ""

Write-Host "Fetching flows (IncludeDeleted=$true)..."
$all = Get-Flows $EnvironmentId
Write-Host ("Total flows returned: {0}" -f (C $all))
Write-Host ""

# NOTE: In practice, "Stopped" often indicates a disabled flow, not a deleted flow.
# We keep a broad list, but you should tighten it once you discover the exact deleted state in your tenant.
$deletedLikeStates = @('Deleted','Removed','Trash','Suspended','Stopped')

if ($DeletedOnly) {
  $searchSet = A ($all | Where-Object { $deletedLikeStates -contains (Get-State $_) })
  Write-Host ("Deleted-like flows (by Internal.properties.state) found: {0}" -f (C $searchSet))

  if ((C $searchSet) -eq 0) {
    Write-Warning "No flows matched the deleted-like state list. We may need the exact deleted state string in your tenant."
  }
} else {
  $searchSet = $all
}

Write-Host ""
$matches = Find-ByName -flows $searchSet -name $DisplayName -containsMatch:$Contains

if ((C $matches) -eq 0) {
  Write-Warning ("No flows matched '{0}' in the searched set." -f $DisplayName)
  Write-Host ""
  Write-Host ("Previewing up to {0} flows (DisplayName, FlowName, State):" -f $PreviewCount)
  $searchSet |
    Sort-Object DisplayName |
    Select-Object -First $PreviewCount `
      @{n='DisplayName';e={$_.DisplayName}}, `
      @{n='FlowName';e={$_.FlowName}}, `
      @{n='State';e={Get-State $_}}, `
      Enabled |
    Format-Table -AutoSize
  return
}

Write-Host ("Matches found: {0}" -f (C $matches))
$matches |
  Select-Object `
    DisplayName, `
    FlowName, `
    @{n='State';e={Get-State $_}}, `
    Enabled, `
    CreatedTime, `
    LastModifiedTime |
  Format-Table -AutoSize

if ($ListOnly) {
  Write-Host ""
  Write-Host "ListOnly specified: not restoring anything."
  return
}

if (-not $RestoreAll -and (C $matches) -gt 1) {
  Write-Warning "Multiple matches found. Re-run with -RestoreAll, or tighten the name (or use -Contains with a more specific fragment)."
  return
}

foreach ($m in A $matches) {
  $flowGuid = $m.FlowName
  $flowDisp = $m.DisplayName

  if ($PSCmdlet.ShouldProcess(("Restore flow '{0}' ({1})" -f $flowDisp, $flowGuid), "Restore-AdminFlow")) {
    Restore-AdminFlow -EnvironmentName $EnvironmentId -FlowName $flowGuid
    Write-Host ("Restore attempted: {0} ({1})" -f $flowDisp, $flowGuid)
  }
}

Write-Host ""
Write-Host "Done."
Write-Host "If the flow comes back disabled, re-enable it in the maker portal / admin center."
