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
    .PARAMETER Timeout
        [int]
        The timeout amount, in milliseconds, before the thread gets discarded
    .PARAMETER ScriptSleep
        [int]
        The time in milliseconds during which the thread will sleep for
    .OUTPUTS
        [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]
    .EXAMPLE
        $result = Invoke-Parallel -Array (1..10) -Arg2 "asd" -Timeout 100 -ScriptSleep 120
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
        [int]
        $Timeout = 6000,

        [Parameter(Mandatory = $true)]
        [int]
        $ScriptSleep
    )

    begin {
        $Parameters = [System.Collections.Concurrent.ConcurrentDictionary[[string], [array]]]::new()
        $jobsList = [System.Collections.Concurrent.ConcurrentBag[System.Collections.Concurrent.ConcurrentDictionary[[string], [object]]]]::new()
        $ResultList = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

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
                $Parameters.Pipeline = @($Item, $Arg2, $Timeout, $ScriptSleep)
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
                            [System.Threading.Thread]::Sleep($Pipeline[3])
                            return [PSCustomObject]@{
                                Item        = $Pipeline[0]
                                Arg2        = $Pipeline[1]
                                Timeout     = $Pipeline[2]
                                ScriptSleep = $Pipeline[3]
                            }
                        }
                        catch {
                            # Handle errors here
                            return [PSCustomObject]@{
                                Item         = $Pipeline[0]
                                Arg2         = $Pipeline[1]
                                Timeout      = $Pipeline[2]
                                ScriptSleep  = $Pipeline[3]
                                ErrorMessage = $_.Exception.Message
                            }
                        }
                        finally {
                            # Handle object disposal here
                        }
                    }, $true) #Setting UseLocalScope to $true fixes scope creep with variables in RunspacePool

                [void]$PowerShell.AddParameters($Parameters)
                $jobDictionary = [System.Collections.Concurrent.ConcurrentDictionary[[string], [object]]]::new()
                $cancellationTokenSource = [System.Threading.CancellationTokenSource]::new($Timeout)
                [void]$jobDictionary.TryAdd('PowerShell', $PowerShell)
                [void]$jobDictionary.TryAdd('Handle', $PowerShell.BeginInvoke())
                [void]$jobDictionary.TryAdd('CancellationToken', $cancellationTokenSource.Token)
                [void]$jobsList.Add($jobDictionary)
            }
        }
        catch {
            throw
        }
    }

    end {
        try {
            <#
            foreach ($job in $jobsList) {
                $Flag = 'static','nonpublic','instance'
                $_Worker = $job.PowerShell.GetType().GetField('_worker',$Flag)
                $Worker = $_Worker.GetValue($job.PowerShell)
                $_CRP = $worker.GetType().GetProperty('CurrentlyRunningPipeline',$Flag)
                $CRP = $_CRP.GetValue($Worker)
                $CRP.Runspace.CloseAsync()
            }
            #>

            while ($true) {
                # This will require a threadsafe collection
                [System.Linq.Enumerable]::Where(
                    $jobsList,
                    [Func[System.Collections.Concurrent.ConcurrentDictionary[[string], [object]], bool]] {
                        param($job) $job.Handle.IsCompleted -eq $true
                    }).ForEach({
                        # Adding the output from scriptblock into $ResultList
                        [void]$ResultList.Add($_.PowerShell.EndInvoke($_.Handle))
                        $_.PowerShell.Dispose()
                        # Clear the dictionary entry.
                        # A better way would be to completely remove it from the list, but ConcurrentBag...
                        [void]$_.Clear()
                    })

                [System.Linq.Enumerable]::Where(
                    $jobsList,
                    [Func[System.Collections.Concurrent.ConcurrentDictionary[[string], [object]], bool]] {
                        param($job) $job.CancellationToken.IsCancellationRequested -eq $true -and $job.Handle.IsCompleted -ne $true
                    }).ForEach({
                        # If calling dispose() on the thread while stopping it.
                        # Will either throw an error or lock up the thread while waiting for the underlying process to finish
                        $Flags = 'Static','NonPublic','Instance' #Private
                        $_Worker = $_.PowerShell.GetType().GetField('_worker', $Flags)
                        $Worker = $_Worker.GetValue($_.PowerShell)
                        $_CRP = $worker.GetType().GetProperty('CurrentlyRunningPipeline', $Flags)
                        $CRP = $_CRP.GetValue($Worker)
                        $CRP.Runspace.DisconnectAsync()
                        $CRP.Runspace.CloseAsync()
                        #[void]$_.PowerShell.StopAsync($null, $_.Handle) # Only works on PS 7
                        #[void]$_.PowerShell.EndStop($_.PowerShell.BeginStop($null, $_.Handle))
                        #$_.PowerShell.Dispose()
                        # Clear the dictionary entry.
                        # A better way would be to completely remove it from the list, but ConcurrentBag...
                        [void]$_.Clear()
                    })

                if ($jobsList.Keys.Count -eq 0) {
                    # Breaks out of the loop to start cleanup
                    break
                }

                <#
                foreach ($job in $jobsList) {
                    if ($job.Handle.IsCompleted -eq $true ) {
                        [void]$ResultList.Add($job.PowerShell.EndInvoke($job.Handle))
                        $job.PowerShell.Dispose()
                        [void]$job.Clear()
                        continue
                    }
                    if ($job.CancellationToken.IsCancellationRequested -eq $true) {
                        $job.PowerShell.StopAsync($null, $job.Handle) # If called dispose while stopping it will either throw an error or the thread will wait for the task to complete
                        #$job.PowerShell.EndStop($job.PowerShell.BeginStop($null, $job.Handle))
                        #$job.PowerShell.Dispose() # Will wait for the underlying task to complete
                        [void]$job.Clear()
                    }
                }
                if ($jobsList.Keys.Count -eq 0) {
                    break
                }
                #>
            }
            return $ResultList
        }
        catch {
            throw
        }
        finally {
            $cancellationTokenSource.Dispose()
            $jobDictionary.Clear()
            $RunspacePool.Close()
            $RunspacePool.Dispose()
            $jobsList.clear()
            $Parameters.Clear()
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            [System.GC]::Collect()
        }
    }
}

Invoke-Parallel -Array (1..3) -Arg2 "asd" -Timeout 100 -ScriptSleep 120000 > $null