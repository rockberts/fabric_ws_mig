# Powershell - Power BI CMDLETS
# Read https://learn.microsoft.com/en-us/powershell/power-bi/overview?view=powerbi-ps 
# -Scope CurrentUser use this to install more local the powershell module
# Run this script with current priviligies
# Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass 
#Install-Module -Name MicrosoftPowerBIMgmt -Scope CurrentUser
 
#1. login to Power BI using a tenant id
Connect-PowerBIServiceAccount

#2. Define premium capacity name and export path for successful and failed workspaces
$CapacityName = ""

$NewCapacityName = ""

$PremiumWorkspacesCSV = "/home/system/migrarFabric/PremiumCapacityWorkspaces.csv"

$FailedWorkspacesCSV = "/home/system/migrarFabric/FailedWorkspaces.csv"

#$SharedCapacity="00000000-0000-0000-0000-000000000000" #Shared capacity ID if you want to send the workspace to shared capacity

#3. Get capacity ID of the given premium capacity
$CapID = (Get-PowerBICapacity -Scope Organization | Where-Object {$_.DisplayName -eq $CapacityName}).Id

#3.1. Get capacity ID of the new Fabric capacity
$CapIDNew = (Get-PowerBICapacity -Scope Organization | Where-Object {$_.DisplayName -eq $NewCapacityName}).Id

$FailedWorkspaces = [System.Collections.ArrayList]@()
#4. Retrieve the workspaces filtered by the Capacity ID

$PremiumCapWorkspaces = Get-PowerBIWorkspace -Scope Organization -All | Where-Object {$_.CapacityID -eq $CapID}
#5. per each workspace, change the capacity for the new specified
foreach ($Premiumworkspace in $PremiumCapWorkspaces) {
        Set-PowerBIWorkspace -Scope Organization -Id $Premiumworkspace.Id -CapacityId $CapIDNew
        if (-not $?){
            Write-Host "Error moving workspace $($Premiumworkspace.Name) to capacity $NewCapacityName"
            $FailedWorkspaces.Add($Premiumworkspace)
        }
}
#6. Move the workspace to other capacity 
$PremiumCapWorkspaces | Select-Object *,@{Name="NewCapacityName";Expression={$NewCapacityName}},@{Name="DateRetrieved";Expression={Get-Date}} | `
    Export-Csv $PremiumWorkspacesCSV -NoTypeInformation -Force
$FailedWorkspaces | Select-Object * | Export-Csv $FailedWorkspacesCSV -NoTypeInformation -Force
