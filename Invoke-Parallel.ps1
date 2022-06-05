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

    .PARAMETER Timeout
        [int]
        The timeout amount, in milliseconds, before the thread gets discarded

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
        $ThreadSafe,

        [Parameter(Mandatory = $false)]
        [int]
        $Timeout = 6000
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

        $Stopwatch = [System.Diagnostics.Stopwatch]::new()
        $RunspacePool = [RunspaceFactory]::CreateRunspacePool(
            [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        )
        [void]$RunspacePool.SetMaxRunspaces([System.Environment]::ProcessorCount)

        # The Thread will create and enter a multithreaded apartment.
        # DCOM communication requires STA ApartmentState!
        $RunspacePool.ApartmentState = [System.Threading.ApartmentState]::MTA
        # UseNewThread for local Runspace, ReuseThread for local RunspacePool, server settings for remote Runspace and RunspacePool
        $RunspacePool.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::Default
        $RunspacePool.Open()
    }

    process {
        try {
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
                            # Handle errors here
                            return [PSCustomObject]@{
                                Key1         = $Pipeline[0]
                                Key2         = $Pipeline[1]
                                ErrorMessage = $_.Exception.Message
                            }
                        }
                        finally {
                            # Handle object disposal here
                        }
                    }, $true) #Setting UseLocalScope to $true fixes scope creep with variables in RunspacePool

                [void]$PowerShell.AddParameters($Parameters)
                $jobDictionary = [System.Collections.Generic.Dictionary[[string], [object]]]::new()
                [void]$jobDictionary.Add('PowerShell', $PowerShell)
                [void]$jobDictionary.Add('Handle', $PowerShell.BeginInvoke())
                [void]$jobsList.Add($jobDictionary)
            }
        }
        catch {
            throw
        }
    }

    end {
        $Stopwatch.Start()
        while ($jobsList.Handle.IsCompleted -eq $false) {
            if ($jobsList.Where({$_.Handle.IsCompleted -eq $true}).Count -gt 0) {
                $jobsList.Where({
                    $_.Handle.IsCompleted -eq $true
                }).ForEach({
                    [void]$ResultList.Add($_.PowerShell.EndInvoke($_.Handle))
                    $_.PowerShell.Dispose()
                    [void]$jobsList.Remove($_)
                })
            }

            if ($Stopwatch.Elapsed.Milliseconds -ge $Timeout) {
                $jobsList.ForEach({
                    # Starts an asynchronous call to stop the powershell thread
                    # This will discard any eventual return data
                    # fairly certain it'll also not dispose of the thread
                    # maybe call Dispose() directly (?)
                    $_.PowerShell.StopAsync($_.Handle)
                    [void]$jobsList.Remove($_)
                })
                break
            }

            [System.Threading.Thread]::Sleep(50)
        }

        $Stopwatch.Stop()
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
