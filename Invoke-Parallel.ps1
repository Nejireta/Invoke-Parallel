function Invoke-Parallel {
    <#
    .SYNOPSIS
        Template function for multithreading

    .DESCRIPTION
        Parallel iteration function which uses CreateRunspacePool to execute code and return values

    .PARAMETER Array
        [string[]]
        Array of which should be iterated through

    .PARAMETER Arg2
        [string]
        Placeholder parameter to express functionality

    .PARAMETER ThreadSafe
        [switch]
        If the function should switch to threadsafe collections

    .OUTPUTS
        [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]
        Or
        [System.Collections.Generic.List[PSCustomObject]]

    .EXAMPLE
        $result = Invoke-Parallel -Array (1..10) -Arg2 "asd"
#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]
        $Array,

        [Parameter(Mandatory = $false)]
        [string]
        $Arg2,

        [Parameter(Mandatory = $false)]
        [switch]
        $ThreadSafe
    )

    begin {
        if ($ThreadSafe) {
            $Parameters = [System.Collections.Concurrent.ConcurrentDictionary[[string], [array]]]::new()
            $jobsList = [System.Collections.Concurrent.ConcurrentBag[System.Collections.Generic.Dictionary[[string], [object]]]]::new()
            $ResultList = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
        }
        else {
            $Parameters = [System.Collections.Generic.Dictionary[[string], [array]]]::new(1)
            $jobsList = [System.Collections.Generic.List[System.Collections.Generic.Dictionary[[string], [object]]]]::new($Array.Count)
            $ResultList = [System.Collections.Generic.List[PSCustomObject]]::new($Array.Count)
        }

        $RunspacePool = [RunspaceFactory]::CreateRunspacePool(
            [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        )
        [void]$RunspacePool.SetMaxRunspaces([System.Environment]::ProcessorCount)
        $RunspacePool.ApartmentState = [System.Threading.ApartmentState]::MTA
        $RunspacePool.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
        $RunspacePool.Open()
    }

    process {
        foreach ($Item in $Array) {
            $Parameters.Pipeline = @($Item, $Arg2)
            $PowerShell = [PowerShell]::Create()
            $PowerShell.RunspacePool = $RunspacePool

            [void]$PowerShell.AddScript({
                    Param (
                        $Pipeline
                    )

                    # Adds array iteration to variable
                    #$Arg1 = $Pipeline[0]
                    # Adds Arg2 Parameter to variable
                    #$Arg2 = $Pipeline[1]
                    try {
                        # Insert some code here and return desired result as a PSCustomObject
                        return [PSCustomObject]@{
                            Key1         = $Pipeline[0]
                            Key2         = $Pipeline[1]
                            ErrorMessage = 'NULL'
                        }
                    }
                    catch {
                        return [PSCustomObject]@{
                            Key1         = $Pipeline[0]
                            Key2         = $Pipeline[1]
                            ErrorMessage = $_.Exception.Message
                        }
                    }
                }, $true) #Setting UseLocalScope to $True fixes scope creep with variables in RunspacePool

            [void]$PowerShell.AddParameters($Parameters)
            $jobDictionary = [System.Collections.Generic.Dictionary[[string], [object]]]::new()
            $jobDictionary.Add('PowerShell', $PowerShell)
            $jobDictionary.Add('Handle', $PowerShell.BeginInvoke())
            [void]$jobsList.Add($jobDictionary)
        }
    }

    end {
        While ($jobsList.handle.IsCompleted -eq $False) {
            [System.Threading.Thread]::Sleep(50)
        }

        foreach ($job in $jobsList) {
            $ResultList.Add($job['PowerShell'].EndInvoke($job['Handle']))
            $job['PowerShell'].Dispose()
        }

        $jobDictionary.Clear()
        $RunspacePool.Close()
        $RunspacePool.Dispose()
        $jobsList.clear()
        $Parameters.Clear()
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        [System.GC]::Collect()
        return $ResultList
    }
}
