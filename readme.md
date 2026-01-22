# Powershell Tools

Various powershell tools.

## OneBlink SDK Tool

**Get-BlinkMrcFiles.ps1**. Recursively finds all .blinkmrc.json files under a specified root directory, excluding specified directories. Display a list to the console, optionally in JSON or Object format. Optionally copy the files to a zip file, retaining their relative paths.

## Power Automate Flow Tools

**Get-FlowByDisplayName.ps1**. Lists Power Automate flows in an environment filtered by display name. Can do partial matches on display name. Useful if you've lost a flow, especially if you aren't a primary or co-owner of it, and the flow isn't in a solution.

**Restore-DeletedFlowByName.ps1**. Find and optionally restore deleted Power Automate cloud flows by DisplayName in a given Power Platform environment.

