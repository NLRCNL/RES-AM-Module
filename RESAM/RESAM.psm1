
#region HelperFunctions

# Invokes a query on the RES AM Database.
function Invoke-SQLQuery
{
    [CmdletBinding()]
    [OutputType([int])]
    Param
    (
        # Param1 help description
        [Parameter(Mandatory=$true,
                   ValueFromPipelineByPropertyName=$true,
                   Position=0)]
        $Query,

        [Parameter(Mandatory=$False,
                   ValueFromPipeline = $false,
                   Position=1)]
        [string]
        $Type,

        [bool]
        $Full = $true
    )

    Begin
    {
        If (!$RESAM_DB_Connection)
        {
            Throw "No connection to a RES Automation Manager database detected. Run command Connect-RESAMDatabase first."
        }
        elseif ($RESAM_DB_Connection.State -eq 'Closed')
        {
            Write-Verbose 'Connection to the database is closed. Re-opening connection...'
            try
            {
                $RESAM_DB_Connection.Open()
            }
            catch
            {
                Write-Verbose "Error re-opening connection. Removing connection variable."
                Remove-Variable -Scope Global -Name RESAM_DB_Connection
                throw "Unable to re-open conection to the database. Please reconnect using the Connect-RESAMDatabase commandlet. Error is $($_.exception)."
            }
        }
    }
    Process
    {
        $command = $RESAM_DB_Connection.CreateCommand()
        $command.CommandText = $Query

        Write-Verbose "Running SQL query '$query'"
        $result = $command.ExecuteReader()
        $CustomTable = new-object "System.Data.DataTable"
        try{
            $CustomTable.Load($result)
        }
        catch{
            $_
        }
        If ($Type)
        {
            $CustomTable | ConvertTo-RESAMObject -Type $Type -Full:$Full
        }
        else
        {
            $CustomTable | ConvertTo-RESAMObject -Full:$Full
        }

        $result.close()
    }
    End
    {
        Write-Verbose "Finished running SQL query."
    }
}

# Converts a SQL query result object to a RES AM object.
function ConvertTo-RESAMObject
{
    [CmdletBinding()]
    [OutputType([int])]
    Param
    (
        # Param1 help description
        [Parameter(Mandatory=$true,
                   ValueFromPipeline = $true,
                   Position=0)]
        $InputObject,
        
        [Parameter(Mandatory=$False,
                   ValueFromPipeline = $false,
                   Position=1)]
        [string]
        $Type,

        [bool]
        $Full = $true

    )

    Process
    {
        Write-Verbose "Creating custom object for output."
        $Properties = $InputObject | Get-Member -MemberType Property |
         select -ExpandProperty Name
        $ht = @{}
        foreach ($Property in $Properties)
        {
            $NewProp = $Property -replace '^(str|lng|ysn|dtm|img)',''
            $Value = $InputObject.$Property
            If ($NewProp -eq 'Status')
            {
                switch ($Value)
                {
                    '0' {$Value = 'Offline'}
                    '1' {$Value = 'Online'}
                }
            }
            if ($InputObject.$Property.GetType().Name -eq 'Byte[]')
            {
                If ($Full)
                {
                    $Value = ConvertFrom-ByteArray $Value
                }
                else
                {
                    $Value = "Use '-Full' parameter for details"
                }
            }
            If ($Property -eq 'imgWho')
            {
                $NewProp = 'WhoGUID'
            }
            If ($InputObject.$Property -is [datetime])
            {
                $Value = ConvertTo-LocalTime $Value
            }
            Write-Verbose "Creating output object."
            $ht.Add($NewProp,$Value)
        }
        $Object = New-Object -TypeName psobject -Property $ht
        If ($Type)
        {
            $Object.PSObject.TypeNames.Insert(0,"RES.AutomationManager.$Type")
        }
        $Object
    }
}

# Converts a ByteArray to text characters.
function ConvertFrom-ByteArray
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true,
        ValueFromPipeline=$true,
        Position=0)]
        [System.Byte[]]
        $ByteArray
    )
    
    Write-Verbose "Processing Byte Array..."
    $NewArray = $ByteArray | ?{$_ -ne 0}
    $Text = [System.Text.Encoding]::ASCII.GetString($NewArray)
    Try {
        [xml]$XML = $Text
        $Object = New-Object -TypeName psobject
        $Properties = $XML | Get-Member -MemberType Property | ?{$_.Name -ne 'xml'}
        foreach ($Property in $Properties)
        {
            $Name = $Property.Name
            Write-Verbose "Adding property $Name to object."
            $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $XML.$Name
        }
    }
    Catch {
        Write-Verbose "Not able to convert array to XML object."
        $Object = Try{
            Write-Verbose "Attempting to cast object as GUID."
            If ($Text -as [guid])
            {
                Write-Verbose "Object is indeed a GUID."
            }
            else
            {
                Write-Verbose "Object is not a GUID."
                Write-Verbose "Casting object as a string value."
                $Text
            }
        }
        catch {
            throw 'Unknown error occurred.'
        }
    }
    $Object
    Write-Verbose "Finished processing array."
}

# Translates a folder guid to a name and adds the name to an object.
function Add-RESAMFolderName
{
    [CmdletBinding()]
    Param (
    [Parameter(ValueFromPipeline=$true)]
    $InputObject)


    process
    {
        If ($InputObject.FolderGuid)
        {
            $Folder = $InputObject.FolderGuid | Get-RESAMFolder
            $InputObject | Add-Member -MemberType NoteProperty -Name FolderName -Value $Folder.Name
        }
        $InputObject
    }
}

# Optimizes an agent object.
function Optimize-RESAMAgent
{
    [CmdletBinding()]
    Param (
    [Parameter(ValueFromPipeline=$true)]
    [ValidateScript({
            If ($_.PSObject.TypeNames -contains 'RES.AutomationManager.Agent' -or
             $_ -is [guid])
             {
                $true
             }
             else
             {
                throw "Object type should be 'RES.AutomationManager.Agent'."
             }
        })]
    $Agent
    )

    Process
    {
        Write-Verbose "Optimizing agent $($Agent.Name)."
        
        If ($Agent.PrimaryTeamGUID)
        {
            Write-Verbose "Adding PrimaryTeam member."
            $Query = "select strName from dbo.tblTeams WHERE GUID = '$($Agent.PrimaryTeamGUID)'"
            $PrimaryTeam = Invoke-SQLQuery $Query
            $Agent | Add-Member -MemberType NoteProperty -Name PrimaryTeam -Value $PrimaryTeam.Name
        }

        Write-Verbose "Adding Teams member."
        $Query = "select TeamGUID from dbo.tblTeamAgents WHERE AgentGUID = '$($Agent.WUIDAgent)'"
        $Teams = Invoke-SQLQuery $Query | %{
            $Query = "select strName from dbo.tblTeams WHERE GUID = '$($_.TeamGUID)'"
            Invoke-SQLQuery $Query
        }
        $Agent | Add-Member -MemberType NoteProperty -Name Teams -Value $Teams.Name

        Write-Verbose "Checking agent for duplicates."
        $Query = "SELECT strName, COUNT(strName) AS #Duplicates
                  FROM dbo.tblAgents
                  group by strName
                  having COUNT(strName) > 1"
        $Duplicates = Invoke-SQLQuery $Query
        If ($Duplicates.Name -contains $Agent.Name)
        {
            $Agent | Add-Member -MemberType NoteProperty -Name HasDuplicates -Value $True
        }
        else
        {
            $Agent | Add-Member -MemberType NoteProperty -Name HasDuplicates -Value $False
        }
        $Agent
    }
}

# Optimizes a folder object, gives meaning to number values.
function Optimize-RESAMFolder
{
    [CmdletBinding()]
    Param (
    [Parameter(ValueFromPipeline=$true)]
    $Folder)


    process
    {
        $Folder.Name = $Folder.Name.Trim()
        switch ($Folder.FolderType)
        {
            1 {$Folder.FolderType = 'Module'}
            2 {$Folder.FolderType = 'Resource'}
            3 {$Folder.FolderType = 'Project'}
            5 {$Folder.FolderType = 'RunBook'}
            6 {$Folder.FolderType = 'Team'}
        }
        If ($Folder.ParentFolderGUID.tostring())
        {
            $Query = "select * from dbo.tblFolders WHERE FolderGUID = '$($Folder.ParentFolderGUID.tostring())'"
            $ParentFolder = Invoke-SQLQuery $Query
            $Folder | Add-Member -MemberType NoteProperty -Name ParentFolderName -Value $ParentFolder.Name.trim()
        }
        $Folder
    }
}

# Optimizes a connector object, gives meaning to number values.
function Optimize-RESAMConnector
{
    [CmdletBinding()]
    Param (
    [Parameter(ValueFromPipeline=$true)]
    $Connector)


    process
    {
        switch ($Connector.Type)
        {
            1 {
                $Connector | Add-Member -MemberType NoteProperty -Name ConnectorFor -Value 'Database Servers'
                switch ($Connector.Flags)
                {
                    1  {$Connector.Type = 'Microsoft SQL Server'}
                    2  {$Connector.Type = 'Oracle'}
                    3  {$Connector.Type = 'Microsoft SQL Server;Oracle'}
                    4  {$Connector.Type = 'IBM DB2'}
                    5  {$Connector.Type = 'Microsoft SQL Server;IBM DB2'}
                    6  {$Connector.Type = 'Oracle;IBM DB2'}
                    7  {$Connector.Type = 'Microsoft SQL Server;Oracle;IBM DB2'}
                    8  {$Connector.Type = 'MySQL'}
                    9  {$Connector.Type = 'Microsoft SQL Server;MySQL'}
                    10 {$Connector.Type = 'Oracle;MySQL'}
                    11 {$Connector.Type = 'Microsoft SQL Server;Oracle;MySQL'}
                    12 {$Connector.Type = 'IBM DB2;MySQL'}
                    13 {$Connector.Type = 'Microsoft SQL Server;IBM DB2;MySQL'}
                    14 {$Connector.Type = 'Oracle;IBM DB2;MySQL'}
                    15 {$Connector.Type = 'Microsoft SQL Server;Oracle;IBM DB2;MySQL'}
                }
              }
            2 { 
                $Connector | Add-Member -MemberType NoteProperty -Name ConnectorFor -Value 'Virtualization Hosts'
                switch ($Connector.Flags)
                {
                    1 {$Connector.Type = 'VMWare ESX/vSphere'}
                }
              }
            3 { 
                $Connector | Add-Member -MemberType NoteProperty -Name ConnectorFor -Value 'Mail Servers'
                switch ($Connector.Flags)
                {
                    1 {$Connector.Type = 'Microsoft Exchange'}
                }
              }
            4 { 
                $Connector | Add-Member -MemberType NoteProperty -Name ConnectorFor -Value 'Directory Servers'
                switch ($Connector.Flags)
                {
                    1 {$Connector.Type = 'Microsoft Active Directory'}
                }
              }
            5 { 
                $Connector | Add-Member -MemberType NoteProperty -Name ConnectorFor -Value 'Remote Hosts'
                switch ($Connector.Flags)
                {
                    1 {$Connector.Type = 'Secure Shell'}
                }
              }
            6 { 
                $Connector | Add-Member -MemberType NoteProperty -Name ConnectorFor -Value 'Small Business Servers'
                switch ($Connector.Flags)
                {
                    0 {$Connector.Type = ''}
                }
              }
            7 { 
                $Connector | Add-Member -MemberType NoteProperty -Name ConnectorFor -Value 'Web Service Hosts'
                switch ($Connector.Flags)
                {
                    0 {$Connector.Type = 'Web Service'}
                }
              }
        }

        $Connector
    }
}

# Converts UTC to local time.
Function ConvertTo-LocalTime
{
    Param(
        [DateTime]
        $UTCTime
    )

    $strCurrentTimeZone = (Get-WmiObject win32_timezone).StandardName
    $TZ = [System.TimeZoneInfo]::FindSystemTimeZoneById($strCurrentTimeZone)
    [System.TimeZoneInfo]::ConvertTimeFromUtc($UTCTime, $TZ)
}

# Optimizes the job object, gives meaning to number values.
function Optimize-RESAMJob
{
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline=$true,
                   Position = 0)]
        $InputObject
    )
    process
    {
        Write-Verbose "Processing Job Invoker..."
        switch ($InputObject.JobInvoker)
        {
            1  {
                If (!$InputObject.JobInvokerInfo.ToString())
                    {
                        $InputObject.JobInvokerInfo = 'User'
                    }
                }
            2  {$InputObject.JobInvokerInfo = 'Recurring schedule'}
            5  {$InputObject.JobInvokerInfo = 'RES Workspace Manager'}
            7  {$InputObject.JobInvokerInfo = 'New Agent'}
            8  {$InputObject.JobInvokerInfo = 'Boot'}
            9  {$InputObject.JobInvokerInfo = 'Runbook'}
        }
        Write-Verbose "Job Invoker is '$($InputObject.JobInvokerInfo)'."

        Write-Verbose "Processing status..."
        switch ($InputObject.Status)
        {
            -1        {$InputObject.Status = 'On Hold'}
            'Offline' {$InputObject.Status = 'Scheduled'}
            'Online'  {$InputObject.Status = 'Active'}
            2         {$InputObject.Status = 'Aborting'}
            3         {$InputObject.Status = 'Aborted'}
            4         {$InputObject.Status = 'Completed'}
            5         {$InputObject.Status = 'Failed'}
            6         {$InputObject.Status = 'Failed Halted'}
            7         {$InputObject.Status = 'Cancelled'}
            8         {$InputObject.Status = 'Completed with Errors'}
            9         {$InputObject.Status = 'Skipped'}
        }
        Write-Verbose "Status is '$($InputObject.Status)'"
        #Write-Verbose "Converting dates to local time."
        #$InputObject.StartDateTime = ConvertTo-LocalTime $InputObject.StartDateTime
        #$InputObject.StopDateTime = ConvertTo-LocalTime $InputObject.StopDateTime
        $InputObject
    }
}

# Invokes a method using the REST Api
function Invoke-RESAMRestMethod {
    [CmdletBinding()]
	param(
        [Parameter(Mandatory=$True)]
	    [string]
        $Uri,

        [Parameter(Mandatory=$True)]
        [ValidateSet("GET","PUT","POST")] 
	    [string]
        $Method,

        [Parameter(Mandatory=$True)]
        $Credential,
	    
        [System.Object]
        $Body
	)
	begin
    {
        If ($Credential) {
            Write-Verbose "Processing credentials."
            $Message = "Please enter RES Automation Manager credentials to connect to the Dispatcher."
            switch ($Credential.GetType().Name)
            {
                'PSCredential' {}
                'String' {$Credential = Get-Credential $Credential -Message $Message}
            }
        }
    }
	process {
		$Splat = @{
			Uri = $Uri
			Credential = $Credential
			Method = $Method
			ContentType = "application/json"
			SessionVariable = "Script:ResAMSession"
		}
		if($Body){
			$Splat.Add("Body",$Body)
		}
		
		Invoke-RestMethod @Splat
	}
}

# Retreives only used parameters using the webapi
function Get-RESAMInputParameter {
    [CmdletBinding()]
	param(
        [Parameter(Mandatory=$True)]
		[String]
        $Dispatcher,

        [Parameter(Mandatory=$True)]
	    $Credential,

        [Parameter(Mandatory=$True,
                   ValueFromPipeline=$True)]
		[PSObject]
        $What,

        [Switch]
        $Raw = $false
	)
	begin
    {
        If ($Credential) {
            Write-Verbose "Processing credentials."
            $Message = "Please enter RES Automation Manager credentials to connect to the Dispatcher."
            switch ($Credential.GetType().Name)
            {
                'PSCredential' {}
                'String' {$Credential = Get-Credential $Credential -Message $Message}
            }
        }
    }
	process {
		$endPoint = "Dispatcher/SchedulingService/what"
        $Type = $What.PSObject.TypeNames | ?{$_ -like 'RES*'}
		$uri = "http://$Dispatcher/$($endPoint)/$($Type.Split('.')[-1])s/$($What.GUID)/inputparameters"
		$pREST = @{
			Uri = $Uri
			Method = "GET"
			Credential = $Credential
		}
#
# Only parameters that are actually used in any of the module tasks will be returned !
#
		$result = Invoke-RESAMRestMethod @pREST
        if($Raw){$result}
        else{$result.JobParameters}
	}
}

#endregion HelperFunctions

<#
.Synopsis
    Connect to RES Automation Manager SQL Database.
.DESCRIPTION
    Sets up a connection to a RES Automation Manager SQL Database. The connection is saved in a
    variable called RESAM_DB_Connection. You can only connect to one database at a time. 
.PARAMETER Datasource
    Name of the SQL datasource to connect to
.PARAMETER DatabaseName
    Name of the RES Automation Manager Database.
.PARAMETER Credential
    Credentials for the connection. Accepts PSCredentials or a username. The user must have 
    read privileges on the database. If omitted, the default credentials will be used.
.PARAMETER PassThru
    Returns the connection object.
.EXAMPLE
    Connect-RESAMDatabase -DataSource SRV-SQL-01 -DatabaseName RES-AM -Credential RES-AM
    Sets up a connection to database 'RES-AM' on the default SQL Instance on 'SRV-SQL-01'.
    A credential prompt will appear to ask for the password of user 'RES-AM'.
.EXAMPLE
    $Cred = Get-Credential
    C:\PS>Connect-RESAMDatabase -DataSource SRV-SQL-01\RES -DatabaseName RES-AM -Credential $Cred -Passthru
    
      
    Sets up a connection to database 'RES-AM' on the 'RES' Instance on SQL server 'SRV-SQL-01'.
    The connection object will be displayed.
.NOTES
    Author        : Michaja van der Zouwen
    Version       : 1.0
    Creation Date : 25-6-2015
.LINK
   http://itmicah.wordpress.com
#>
function Connect-RESAMDatabase
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true,
                   Position=0)]
        [string]
        $DataSource,
        [Parameter(Mandatory=$true,
                   Position=1)]
        [Alias('DBName')]
        [string]
        $DatabaseName,
        [Parameter(Mandatory=$false,
                   Position=2)]
        $Credential,

        [switch]
        $PassThru
    )

    If ($Credential) {
        Write-Verbose "Processing credentials."
        $Message = "Please enter credentials to connect to database '$DatabaseName'."
        switch ($Credential.GetType().Name)
        {
            'PSCredential' {}
            'String' {$Credential = Get-Credential $Credential -Message $Message}
        }
    }

    Write-Verbose "Connecting to database $DatabaseName on $DataSource..."
    $connectionString = "Server=$dataSource;Database=$DatabaseName"
    If ($Credential)
    {
        $connectionString = "$connectionString;uid=$($Credential.username);pwd=$($Credential.GetNetworkCredential().password);Integrated Security=False;"
    }
    else
    {
        $connectionString = "$connectionString;Integrated Security=sspi;"
    }
    $global:RESAM_DB_Connection = New-Object System.Data.SqlClient.SqlConnection
    $RESAM_DB_Connection.ConnectionString = $connectionString
    $RESAM_DB_Connection.Open()
    Write-Verbose 'Connection established'

    If ($PassThru)
    {
        $RESAM_DB_Connection
    }
}

<#
.Synopsis
    Disconnect from RES Automation Manager Database.
.DESCRIPTION
    Closes the connection to a RES Automation Manager Database.
.PARAMETER Connection
    Name of the SQL datasource to connect to.
.EXAMPLE
    Disconnect-RESAMDatabase
    Closes connection to the currently connected database.
.NOTES
    Author        : Michaja van der Zouwen
    Version       : 1.0
    Creation Date : 25-6-2015
.LINK
   http://itmicah.wordpress.com
#>
function Disconnect-RESAMDatabase
{
    Param (
        [System.Data.SqlClient.SqlConnection]
        $Connection
    )
    If ($Connection)
    {
        Write-Verbose ""
        $connection.Close()
    }
    ElseIf ($RESAM_DB_Connection)
    {
        $RESAM_DB_Connection.Close()
    }
    Remove-Variable -Scope Global -Name RESAM_DB_Connection
}

<#
.Synopsis
    Get RES Automation Manager Agent objects.
.DESCRIPTION
    Get RES Automation Manager Agent objects from the RES Automation 
    Manager Database.
.PARAMETER Name
    Name of the Agent.
.PARAMETER GUID
    GUID of the Agent.
.PARAMETER Team
    Team object or guid of the team the agent should be member of.
.PARAMETER Full
    Retreive full information (adapter information etc.).
.PARAMETER HasDuplicates
    List agents that have duplicates.
.EXAMPLE
    Get-RESAMAgent -Name PC1234 -Full
    Displays full information on RES Automation Manager agent PC1234.
.EXAMPLE
    Get-RESAMTeam -Name Team1 | Get-RESAMAgent
    Displays default information on RES Automation Manager agent that are member
    of team 'Team1'
.EXAMPLE
    Get-RESAMAgent -HasDuplicates
    Displays a list of agent names that have duplicate agent objects in the
    database.
.EXAMPLE
    Get-RESAMAgent -HasDuplicates | Get-RESAMAgent -Full
    Displays all agent objects that have duplicates in the database.
.NOTES
    Author        : Michaja van der Zouwen
    Version       : 1.0
    Creation Date : 25-6-2015
.LINK
   http://itmicah.wordpress.com
#>
function Get-RESAMAgent
{
    [CmdletBinding(DefaultParameterSetName='Default')]
    param (
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='Default',
                   Position = 0)]
        [Alias('Agent')]
        [string]
        $Name,
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='Default',
                   Position = 1)]
        [Alias('Who')]
        [Alias('WUIDAgent')]
        [Alias('AgentGUID')]
        [guid]
        $GUID,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='Default',
                   Position = 2)]
        [Alias('TeamGUID')]
        [ValidateScript({
            If ($_.PSObject.TypeNames -contains 'RES.AutomationManager.Team' -or
             $_ -is [guid])
             {
                $true
             }
             else
             {
                throw "Object type should be 'RES.AutomationManager.Team'."
             }
        })]
        $Team,

        [Parameter(ParameterSetName='Default')]
        [switch]
        $Full = $false,

        [Parameter(ParameterSetName='Duplicates')]
        [switch]
        $HasDuplicates
    )

    process
    {
        if ($HasDuplicates)
        {
            Write-Verbose "Checking agent for duplicates."
            $Query = "SELECT strName, COUNT(strName) AS #Duplicates
                      FROM dbo.tblAgents
                      group by strName
                      having COUNT(strName) > 1"
            Invoke-SQLQuery $Query -Type Duplicate
            return
        }
        if ($Team)
        {
            $Query = "select * from dbo.tblTeamAgents WHERE TeamGUID = '$($Team.GUID)'"
            Invoke-SQLQuery $Query -Type TeamAgent | %{
                $Query = "select * from dbo.tblAgents WHERE WUIDAgent = '$($_.AgentGUID)'"
                Invoke-SQLQuery $Query -Type Agent -Full:$Full | Optimize-RESAMAgent
            }
            return
        }    
        if ($GUID)
        {
            $Query = "select * from dbo.tblAgents WHERE WUIDAgent = '$GUID'"
        }        
        elseif ($Name)
        {
            $Query = "select * from dbo.tblAgents WHERE strName LIKE '$($Name.replace('*','%'))'"
        }
        else
        {
            $Query = "select * from dbo.tblAgents"
        }
        Invoke-SQLQuery $Query -Type Agent -Full:$Full | Optimize-RESAMAgent
    }
}

<#
.Synopsis
    Get RES Automation Manager Team objects.
.DESCRIPTION
    Get RES Automation Manager Team objects from the RES Automation 
    Manager Database.
.PARAMETER Name
    Name of the Team.
.PARAMETER GUID
    GUID of the Team.
.PARAMETER Full
    Retreive full information (Rules information etc.).
.EXAMPLE
    Get-RESAMTeam -Name Team1
    Displays information on RES Automation Manager team 'Team1'
.EXAMPLE
    Get-RESAMAgent -Name PC1234 | Get-RESAMTeam
    Displays RES Automation Manager teams of which agent 'PC1234'
    is a member.
.NOTES
    Author        : Michaja van der Zouwen
    Version       : 1.0
    Creation Date : 25-6-2015
.LINK
   http://itmicah.wordpress.com
#>
function Get-RESAMTeam
{
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 0)]
        [string]
        $Name,
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 1)]
        [Alias('TeamGUID')]
        [guid]
        $GUID,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 2)]
        [Alias('WUIDAgent')]
        [ValidateScript({
            If ($_.PSObject.TypeNames -contains 'RES.AutomationManager.Agent' -or
             $_ -is [guid])
             {
                $true
             }
             else
             {
                throw "Object type should be 'RES.AutomationManager.Agent'."
             }
        })]
        $Agent,

        [switch]
        $Full = $false
    )
    process
    {
        if ($Agent)
        {
            If ($Agent -isnot [guid]) 
            {
                $Agent = $Agent.WUIDAgent
            }
            $Query = "select * from dbo.tblTeamAgents WHERE AgentGUID = '$Agent.GUID'"
            Invoke-SQLQuery $Query -Type AgentTeam | %{
                $Query = "select * from dbo.tblTeams WHERE GUID = '$($_.TeamGUID)'"
                Invoke-SQLQuery $Query -Type Team
            }
            return
        }
        If ($GUID)
        {
            $Query = "select * from dbo.tblTeams WHERE GUID = '$($GUID.tostring())'"
        }
        elseif ($Name)
        {
            $Query = "select * from dbo.tblTeams WHERE strName LIKE '$($Name.replace('*','%'))'"
        }
        else
        {
            $Query = "select * from dbo.tblTeams"
        }

        Invoke-SQLQuery $Query -Type Team -Full:$Full
    }
}

<#
.Synopsis
    Get RES Automation Manager Audit information.
.DESCRIPTION
    Get RES Automation Manager audit information from the 
    RES Automation Manager Database.
.PARAMETER Action
    Filter audits based on an action. E.G. Abort, Sign in, etc...
.PARAMETER StartDate
    Display audit trail from a start date.
.PARAMETER EndDate
    Display audit trail up to an end date.
.PARAMETER WindowsAccount
    Display audits made by a specific Windows account.
.PARAMETER Last
    Display last 'n' audits.
.EXAMPLE
    Get-RESAMAudit -Action 'Primary Team changed' -StartDate (Get-Date).AddDays(-4)
    Displays information on all Primary Team changes in the last four days.
.EXAMPLE
    Get-RESAMAudit -StartDate 02-2015 -EndDate 03-2015
    Displays all audit information in february of 2015
.EXAMPLE
    Get-RESAMAudit -WindowsAccount DOMAIN\User123 -Last 10
    Displays the last 10 audits made by user DOMAIN\User123.
.NOTES
    Author        : Michaja van der Zouwen
    Version       : 1.0
    Creation Date : 25-6-2015
.LINK
   http://itmicah.wordpress.com
#>
function Get-RESAMAudit
{
    [CmdletBinding(DefaultParameterSetName='Default')]
    param (
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='Default',
                   Position = 0)]
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='TimeSpan',
                   Position = 0)]
        [ValidateSet('Add','Delete','Edit','Edit (details)','Other','Primary Team changed','Register','Sign in','Sign out')]
        [string]
        $Action,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='TimeSpan',
                   Position = 1)]
        [Alias('From')]
        [Alias('Start')]
        [datetime]
        $StartDate,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='TimeSpan',
                   Position = 2)]
        [Alias('Until')]
        [Alias('End')]
        [datetime]
        $EndDate,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='Default',
                   Position = 3)]
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='TimeSpan',
                   Position = 3)]
        [string]
        $WindowsAccount,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='Default')]
        [int]
        $Last
    )
    begin
    {
        If ($Last)
        {
            $LastNr = "TOP $Last"
        }
        elseif (!$StartDate -and !$EndDate)
        {
            $LastNr = "TOP 1000"
            Write-Warning "Only the last 1000 audits will be displayed. If more are required use the '-Last' parameter."
        }
    }
    process
    {
        $Query = "select $LastNr strObjectDescription,
strAction,
strActionDescription,
dtmDateTime,
strWindowsAccount,
strWISDOMAccount,
strComputerName,
strComputerDomain,
strComputerIP,
strComputerMAC from dbo.tblAudits"

        $Filter = @()
        If ($Action)
        {
            $Filter += "strAction = '$Action'"
        }
        
        If ($WindowsAccount)
        {
            $Filter += "strWindowsAccount LIKE '$($WindowsAccount.Replace('*','%'))'"
        }

        If ($StartDate -and !$EndDate)
        {
            $EndDate = Get-Date
        }
        If ($EndDate -and !$StartDate)
        {
            $FirstAudit = "select TOP 1 dtmDateTime from dbo.tblAudits order by dtmDateTime ASC"
            $StartDate = Invoke-SQLQuery $FirstAudit | select -ExpandProperty DateTime
        }

        If ($Filter)
        {
            $Filter = $Filter -join ' AND '
            $Query = "$Query WHERE $Filter"
        }
        $Query = "$Query order by dtmDateTime DESC"

        If ($StartDate)
        {
            Invoke-SQLQuery $Query -Type Audit | ?{$_.DateTime -ge $StartDate -and $_.DateTime -le $EndDate}
        }
        else 
        {
            Invoke-SQLQuery $Query -Type Audit
        }
    }
}


function Get-RESAMDispatcher
{
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 0)]
        [string]
        $Name,
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 1)]
        [Alias('WUIDDispatcher')]
        [guid]
        $GUID,

        [switch]
        $Full = $false
    )
    process
    {
        If ($GUID)
        {
            $Query = "select * from dbo.tblDispatchers WHERE WUIDDispatcher = '$($GUID.tostring())'"
        }
        elseif ($Name)
        {
            $Query = "select * from dbo.tblDispatchers WHERE strName LIKE '$($Name.replace('*','%'))'"
        }
        else
        {
            $Query = "select * from dbo.tblDispatchers"
        }

        Invoke-SQLQuery $Query -Type Dispatcher -Full:$Full
    }
}

function Get-RESAMFolder
{
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 0)]
        [string]
        $Name,
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 1)]
        [Alias('FolderGUID')]
        [guid]
        $GUID
    )
    process
    {
        If ($GUID)
        {
            $Query = "select * from dbo.tblFolders WHERE FolderGUID = '$($GUID.tostring())'"
        }
        elseif ($Name)
        {
            $Query = "select * from dbo.tblFolders WHERE strName LIKE '$($Name.replace('*','%'))'"
        }
        else
        {
            $Query = "select * from dbo.tblFolders"
        }

        Invoke-SQLQuery $Query -Type Folder | Optimize-RESAMFolder
    }
}

function Get-RESAMModule
{
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 0)]
        [Alias('strName')]
        [string]
        $Name,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 1)]
        [guid]
        $GUID,

        [switch]
        $Full = $false
    )
    process
    {
        If ($GUID)
        {
            Write-Verbose "Running query based on GUID $GUID."
            $Query = "select * from dbo.tblModules WHERE GUID = '$($GUID.tostring())'"
        }
        Elseif ($Name)
        {
            Write-Verbose "Running query based on name $Name."
            $Query = "select * from dbo.tblModules WHERE strName LIKE '$($Name.replace('*','%'))'"
        }
        else
        {
            $Query = "select * from dbo.tblModules"
        }

        Invoke-SQLQuery $Query -Type Module -Full:$Full | Add-RESAMFolderName
    }
}

function Get-RESAMProject
{
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 0)]
        [Alias('strName')]
        [string]
        $Name,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 1)]
        [guid]
        $GUID,

        [switch]
        $Full = $False
    )
    process
    {
        If ($GUID)
        {
            Write-Verbose "Running query based on GUID $GUID."
            $Query = "select * from dbo.tblProjects WHERE GUID = '$($GUID.tostring())'"
        }
        Elseif ($Name)
        {
            Write-Verbose "Running query based on name $Name."
            $Query = "select * from dbo.tblProjects WHERE strName LIKE '$($Name.replace('*','%'))'"
        }
        else
        {
            $Query = "select * from dbo.tblProjects"
        }

        Invoke-SQLQuery $Query -Type Project -Full:$Full | Add-RESAMFolderName
    }
}

function Get-RESAMRunBook
{
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 0)]
        [Alias('strName')]
        [string]
        $Name,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 1)]
        [Alias('WUIDAgent')]
        [guid]
        $GUID,

        [switch]
        $Full = $False
    )
    process
    {
        If ($GUID)
        {
            Write-Verbose "Running query based on GUID $GUID."
            $Query = "select * from dbo.tblRunBooks WHERE GUID = '$($GUID.tostring())'"
        }
        Elseif ($Name)
        {
            Write-Verbose "Running query based on name $Name."
            $Query = "select * from dbo.tblRunBooks WHERE strName LIKE '$($Name.replace('*','%'))'"
        }
        else
        {
            $Query = "select * from dbo.tblRunBooks"
        }

        Invoke-SQLQuery $Query -Type RunBook -Full:$Full | Add-RESAMFolderName
    }
}

function Get-RESAMResource
{
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 0)]
        [Alias('strProductName')]
        [string]
        $Name,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 1)]
        [guid]
        $GUID
    )
    process
    {
        If ($GUID)
        {
            Write-Verbose "Running query based on GUID $GUID."
            $Query = "select * from dbo.tblResources WHERE GUID = '$($GUID.tostring())'"
        }
        Elseif ($Name)
        {
            Write-Verbose "Running query based on name $Name."
            $Query = "select * from dbo.tblResources WHERE strProductName LIKE '$($Name.replace('*','%'))'"
        }
        else
        {
            $Query = "select * from dbo.tblResources"
        }

        Invoke-SQLQuery $Query -Type Resource | Add-RESAMFolderName
    }
}

function Get-RESAMConnector
{
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 0)]
        [Alias('strTarget')]
        [string]
        $Target,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 1)]
        [guid]
        $GUID,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 2)]
        [ValidateSet('Exchange','ActiveDirectory','SecureShell')]
        [string]
        $Type
    )

    begin
    {
        Switch ($Type) {
            'DataBase'       {$TypeNr = 1}
            'Virtualization' {$TypeNr = 2}
            'Mail'           {$TypeNr = 3}
            'Directory'      {$TypeNr = 4}
            'RemoteHosts'    {$TypeNr = 5}
            'SmallBusiness'  {$TypeNr = 6}
        }
    }
    process
    {
        $Filter = @()
        If ($GUID)
        {
            Write-Verbose "Running query based on GUID $GUID."
            $Filter += "GUID = '$($GUID.tostring())'"
        }
        Elseif ($Target)
        {
            Write-Verbose "Running query based on target $Target."
            $Filter += "strTarget LIKE '$($Target.replace('*','%'))'"
        }
        If ($Type)
        {
            $Filter += "lngType = $TypeNr"
        }
        $Query = "select * from dbo.tblConnectors"
        If ($Filter)
        {
            $Query = "$Query WHERE $($Filter -join ' AND ')"
        }

        Invoke-SQLQuery $Query -Type Connector | Optimize-RESAMConnector
    }
}

function Get-RESAMConsole
{
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 0)]
        [Alias('strName')]
        [string]
        $Name,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 1)]
        [guid]
        $GUID
    )
    process
    {
        If ($GUID)
        {
            Write-Verbose "Running query based on GUID $GUID."
            $Query = "select * from dbo.tblConsoles WHERE GUID = '$($GUID.tostring())'"
        }
        Elseif ($Name)
        {
            Write-Verbose "Running query based on name $Name."
            $Query = "select * from dbo.tblConsoles WHERE strName LIKE '$($Name.replace('*','%'))'"
        }
        else
        {
            $Query = "select * from dbo.tblConsoles"
        }

        Invoke-SQLQuery $Query -Type Console | %{
            $Console = $_
            switch ($Console.SystemType)
            {
                1 {$Console.SystemType = 'Client'}
                2 {$Console.SystemType = 'Server'}
            }
            $Console
        }
    }
}

function Get-RESAMDatabaseLevel
{
    [CmdletBinding()]
    param ()

    process
    {
        $Query = "select * from dbo.tblDBLevel"
        
        Invoke-SQLQuery $Query -Type DBlevel | Select -ExpandProperty DBLevel
    }
}

function Get-RESAMMasterJob
{
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 0)]
        [Alias('strDescription')]
        [string]
        $Description,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 1)]
        [Alias('MasterJobGUID')]
        [guid]
        $GUID,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 2)]
        [Alias('Agent')]
        [Alias('Team')]
        [string]
        $Who,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 3)]
        [guid]
        $ModuleGUID,
        
        [switch]
        $Scheduled,

        [switch]
        $Active,

        [switch]
        $InvokedByRunbook,

        [int]
        $Last,

        [switch]
        $Full = $false
    )
    begin
    {
        If ($Last)
        {
            $LastNr = "TOP $Last"
        }
        else
        {
            $LastNr = "TOP 1000"
            Write-Warning "Only the last 1000 jobs will be displayed. If more are required use the '-Last' parameter."
        }
    }
    process
    {
        $Filter = @()
        If ($Scheduled)
        {
            $Filter += "(lngStatus = 0 OR lngStatus = -1)"
            $Filter += "RecurringJobGUID IS NULL"
        }
        If ($ModuleGUID)
        {
            $Filter += "ModuleGUID = '$ModuleGUID'"
        }
        if ($InvokedByRunbook)
        {
            $Filter += "lngJobInvoker = 9"
        }
        else
        {
            $Filter += "lngJobInvoker <> 9"
        }
        If ($GUID -and !$ModuleGUID)
        {
            Write-Verbose "Running query based on GUID $GUID."
            $Filter += "MasterJobGUID = '$($GUID.tostring())'"
        }
        If ($Description -and !$ModuleGUID)
        {
            Write-Verbose "Running query based on description '$Description'."
            $Filter += "strDescription LIKE '$($Description.replace('*','%'))'"
        }
        If ($Who)
        {
            If ($Who -notmatch '\*')
            {
                $Who = "*$Who*" #Jobs can have multiple agents
            }
            $Filter += "strWho LIKE '$($Who.Replace('*','%'))'"
        }
        If ($Active)
        {
            $Filter += "lngStatus = 1"
        }

        $Query = "select $LastNr * from dbo.tblMasterJob"
        If ($Filter)
        {
            $Filter = $Filter -join ' AND '
            $Query = "$Query WHERE $Filter"
        }

        $Query = "$Query order by dtmStartDateTime DESC"
        Invoke-SQLQuery $Query -Type MasterJob -Full:$Full | Optimize-RESAMJob
    }
}

<#
function Get-RESAMJobTask
{
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 0)]
        [Alias('strDescription')]
        [string]
        $Description,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 1)]
        [Alias('MasterJobGUID')]
        [guid]
        $GUID,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 2)]
        [Alias('Agent')]
        [Alias('Team')]
        [string]
        $Who,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 3)]
        [guid]
        $ModuleGUID,
        
        [switch]
        $Scheduled,

        [switch]
        $Active,

        [switch]
        $IncludeChildJobs,

        [int]
        $Last,

        [switch]
        $Full = $false
    )
    begin
    {
        If ($Last)
        {
            $LastNr = "TOP $Last"
        }
        else
        {
            $LastNr = "TOP 1000"
            Write-Warning "Only the last 1000 jobs will be displayed. If more are required use the '-Last' parameter."
        }
    }
    process
    {
        $Filter = @()
        If ($Scheduled)
        {
            $Filter += "(lngStatus = 0 OR lngStatus = -1)"
            $Filter += "RecurringJobGUID IS NULL"
        }
        If ($ModuleGUID)
        {
            $Filter += "ModuleGUID = '$ModuleGUID'"
        }
        IF (!$IncludeChildJobs)
        {
            $Filter += "lngJobInvoker <> 9"
        }
        If ($GUID -and !$ModuleGUID)
        {
            Write-Verbose "Running query based on GUID $GUID."
            $Filter += "MasterJobGUID = '$($GUID.tostring())'"
        }
        Elseif ($Description -and !$ModuleGUID)
        {
            Write-Verbose "Running query based on description '$Description'."
            $Filter += "strDescription LIKE '$($Description.replace('*','%'))'"
        }
        If ($Who)
        {
            If ($Who -notmatch '\*')
            {
                $Who = "*$Who*" #Jobs can have multiple agents
            }
            $Filter += "strWho LIKE '$($Who.Replace('*','%'))'"
        }
        If ($Active)
        {
            $Filter += "lngStatus = 1"
        }

        $Query = "select $LastNr * from dbo.tblMasterJob"
        If ($Filter)
        {
            $Filter = $Filter -join ' AND '
            $Query = "$Query WHERE $Filter"
        }

        $Query = "$Query order by dtmStartDateTime DESC"
        Invoke-SQLQuery $Query -Type Job -Full:$Full | Optimize-RESAMJob
    }
}
#>

function Get-RESAMJob
{
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 0)]
        [Alias('WUIDAgent')]
        [Alias('AgentGUID')]
        $Agent,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 1)]
        [guid]
        $MasterJobGUID,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 3)]
        [guid]
        $JobGUID,
        
        [Parameter(ValueFromPipelineByPropertyName=$false,
                   Position = 3)]
        [ValidateSet('On Hold',
                    'Scheduled',
                    'Active',
                    'Aborting',
                    'Aborted',
                    'Completed',
                    'Failed',
                    'Failed Halted',
                    'Cancelled',
                    'Completed with Errors',
                    'Skipped')]
        [string]
        $Status,

        [int]
        $Last,

        [switch]
        $Full = $false
    )
    begin
    {
        If ($Last)
        {
            $LastNr = "TOP $Last"
        }
        else
        {
            $LastNr = "TOP 1000"
            Write-Warning "Only the last 1000 jobs will be displayed. If more are required use the '-Last' parameter."
        }
    }
    process
    {
        $Filter = @()
        If ($Scheduled)
        {
            $Filter += "(lngStatus = 0 OR lngStatus = -1)"
            $Filter += "RecurringJobGUID IS NULL"
        }
        If ($Agent)
        {
            If ($Agent -is [guid])
            {
                $Filter += "AgentGUID = '$Agent'"
            }
            else 
            {
                $Filter += "strAgent = '$Agent'"
            }
        }
        If ($JobGUID)
        {
            $Filter += "JobGUID = '$JobGUID'"
        }
        If ($MasterJobGUID)
        {
            Write-Verbose "Running query based on MasterJobGUID $MasterJobGUID."
            $Filter += "MasterJobGUID = '$MasterJobGUID'"
        }
        If ($Status)
        {
            switch ($Status)
            {
                'On Hold'               {$Status = -1}
                'Scheduled'             {$Status = 0}
                'Active'                {$Status = 1}
                'Aborting'              {$Status = 2}
                'Aborted'               {$Status = 3}
                'Completed'             {$Status = 4}
                'Failed'                {$Status = 5}
                'Failed Halted'         {$Status = 6}
                'Cancelled'             {$Status = 7}
                'Completed with Errors' {$Status = 8}
                'Skipped'               {$Status = 9}
            }
            $Filter += "lngStatus = $Status"
        }

        $Query = "select $LastNr * from dbo.tblJobs"
        If ($Filter)
        {
            $Filter = $Filter -join ' AND '
            $Query = "$Query WHERE $Filter"
        }

        $Query = "$Query order by dtmStartDateTime DESC"
        Invoke-SQLQuery $Query -Type Job -Full:$Full | Optimize-RESAMJob
    }
}

function Get-RESAMQueryResult
{
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 0)]
        [Alias('strAgent')]
        [string]
        $Agent,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 1)]
        [Alias('QueryGUID')]
        [guid]
        $GUID,

        [Parameter(ValueFromPipelineByPropertyName=$true,
                   Position = 2)]
        [guid]
        $MasterJobGUID,

        [int]
        $Last
    )
    begin
    {
        If ($Last)
        {
            $LastNr = "TOP $Last"
        }
        else
        {
            $LastNr = "TOP 1000"
            Write-Warning "Only the last 1000 jobs will be displayed. If more are required use the '-Last' parameter."
        }
    }
    process
    {
        
        $Filter = @()
        If ($MasterJobGUID)
        {
            Write-Verbose "Running query based on MasterJobGUID $MasterJobGUID."
            $Filter += "MasterJobGUID = '$MasterJobGUID'"
        }
        ElseIf ($GUID)
        {
            Write-Verbose "Running query based on GUID $GUID."
            $Filter += "GUID = '$($GUID.tostring())'"
        }
        Elseif ($Agent)
        {
            Write-Verbose "Running query based on Agent $Agent."
            $Filter += "strAgent LIKE '$($Agent.replace('*','%'))'"
        }
        
        $Query = "select * from dbo.tblQueryResults"
        If ($Filter)
        {
            $Filter = $Filter -join ' AND '
            $Query = "$Query WHERE $Filter"
        }
        $Query = "$Query order by dtmDateTime DESC"
        Invoke-SQLQuery $Query -Type QueryResult
    }
}

#NOT READY
function Get-RESAMLog
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$True,
                   ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='Job',
                   Position = 0)]
        [Alias('strAgent')]
        [guid]
        $JobGUID,

        [Parameter(Mandatory=$True,
                   ValueFromPipelineByPropertyName=$true,
                   ParameterSetName='Task',
                   Position = 0)]
        [Alias('QueryGUID')]
        [guid]
        $TaskGUID
    )
    begin
    {
    }
    process
    {
        If ($JobGUID)
        {
            Write-Verbose "Running query based on JobGUID $JobGUID."
            $Query = "select * from dbo.tblLogs WHERE JobGUID = '$JobGUID'"
        }
        ElseIf ($TaskGUID)
        {
            Write-Verbose "Running query based on TaskGUID $TaskGUID."
            $Query = "select * from dbo.tblLogs WHERE TaskGUID = '$TaskGUID'"
        }
        $Logs = Invoke-SQLQuery $Query
        foreach ($Log in $Logs)
        {
            $FileQuery = "select * from dbo.tblFiles WHERE GUID = '$($Log.FileGUID)'"
            Invoke-SQLQuery $FileQuery -Type LogFile
        }
    }
}

function New-RESAMJob {
    [CmdletBinding()]
	param(
        [Parameter(Mandatory=$True)]
		[String]
        $Dispatcher,

        [Parameter(Mandatory=$True)]
		$Credential,

		[String]
        $Description,

		[Parameter(ValueFromPipeline=$true)]
        $Agent,

        [Parameter(ParameterSetName='Module')]
        $Module,

        [Parameter(ParameterSetName='Project')]
        $Project,

        [Parameter(ParameterSetName='RunBook')]
        $RunBook,

		[DateTime]
        $Start,

        [Switch]
        $LocalTime = $true,

		[Switch]
        $UseWOL = $false,

		[HashTable]
        $Parameters
	)

    begin
    {
        If ($Credential) {
            Write-Verbose "Processing credentials."
            $Message = "Please enter RES Automation Manager credentials to connect to the Dispatcher."
            switch ($Credential.GetType().Name)
            {
                'PSCredential' {}
                'String' {$Credential = Get-Credential $Credential -Message $Message}
            }
        }
        If ($Start)
        {
            $Immediate = $false
        }
        else
        {
            $Immediate = $True
            $Start = Get-Date
        }
        If ($Module)
        {
            IF ($Module.PSObject.TypeNames -contains 'RES.AutomationManager.Module')
            {
                $Task = $Module
            }
            elseIf ($Module.GetType().Name -eq 'String')
            {
                $Task = Get-RESAMModule $Module
            }
            else
            {
                Throw 'Incorrect object type for Module parameter.'
            }
            $Type = 0
        }
        If ($Project)
        {
            IF ($Project.PSObject.TypeNames -contains 'RES.AutomationManager.Project')
            {
                $Task = $Project
            }
            elseIf ($Project.GetType().Name -eq 'String')
            {
                $Task = Get-RESAMProject $Project
            }
            else
            {
                Throw 'Incorrect object type for Project parameter.'
            }
            $Type = 1
        }
        If ($RunBook)
        {
            IF ($RunBook.PSObject.TypeNames -contains 'RES.AutomationManager.RunBook')
            {
                $Task = $RunBook
            }
            elseIf ($RunBook.GetType().Name -eq 'String')
            {
                $Task = Get-RESAMProject $RunBook
            }
            else
            {
                Throw 'Incorrect object type for RunBook parameter.'
            }
            $Type = 2
        }
        If (!$Description)
        {
            $Description = $Task.Name
        }

        $InputParameters = Get-RESAMInputParameter -Dispatcher $Dispatcher -Credential $Credential -What $Task -Raw

        If ($InputParameters)
        {
            Write-Verbose 'Required input parameters found.'
            If ($Parameters)
            {
                Write-Verbose 'Setting new parameter values...'
                foreach ($jobParam in $InputParameters.JobParameters)
                {
                    $Parameters.GetEnumerator() | %{
                        If($_.Key -eq $jobParam.Name)
                        {
                            $Value = $_.Value
                            If ($jobParam.Value2)
                            {
                                Write-Verbose 'Testing values...'
                                $Value.Split(';') | %{
                                    If ($jobParam.Value2.Split(';') -contains $_)
                                    {
                                        Write-Verbose "Value $_ is correct."
                                    }
                                    else
                                    {
                                        Throw "Incorrect value for parameter '$($jobParam.Name)'! Only the following values are allowed: '$($jobParam.Value2)'"
                                    }
                                }    
                            }
                            $jobParam.Value1 = $Value
                        }
                    }
                } # end foreach
                Write-Verbose 'All parameter values have been set.'
            }
            else # No Parameters
            {
                Write-Verbose 'Prompting for parameter values:'
                foreach ($jobParam in $InputParameters.JobParameters)
                {
                    $Correct = $True
                    $Value = Read-Host "Please provide value for parameter '$($jobParam.Name)'"
                    If ($jobParam.Value2)
                    {
                        $Value.Split(';') | %{
                            If ($jobParam.Value2.Split(';') -contains $_ -and $Correct)
                            {
                                $Correct = $True
                            }
                            else
                            {
                                Write-Verbose "Incorrect value found for parameter '$($jobParam.Name)':"
                                Write-Verbose "Faulty value is $_."
                                $Correct = $False
                            }
                        }
                        If (!$Correct)
                        {
                            Write-Verbose 'Incorrect parameter value(s) found.'
                            Do {
                                $Value = Read-Host "Allowed values are '$($jobParam.Value2)'"
                                $Correct = $True
                                $Value.Split(';') | %{
                                    If ($jobParam.Value2.Split(';') -contains $_ -and $Correct)
                                    {
                                        $Correct = $True
                                    }
                                    else
                                    {
                                        $Correct = $False
                                    }
                                }
                            }
                            until ($Correct)
                        }
                    } # end If $jobParam.Value2
                    $jobParam.Value1 = $Value
                } # end foreach
            } # end If-else $Parameters
        } # end IF $inputparameters
        $ArrAgents = @()
    }
	process {
        
        If ($Agent.PSObject.TypeNames -contains 'RES.AutomationManager.Agent')
        {
            $ArrAgents += $Agent
        }
        else
        {
            $ArrAgents += (Get-RESAMAgent $Agent)
        }
    }
    End
    {
		$endPoint = "Dispatcher/SchedulingService/jobs"
		$uri = "http://$Dispatcher/$($endPoint)"
		
		$blob = [pscustomobject]@{
			Description = $Description
			When = @{
			    ScheduledDateTime = $Start
                Immediate = $Immediate.ToString().ToLower()
                IsLocalTime = $LocalTime.ToString().ToLower()
                UseWakeOnLAN = $UseWOL.ToString().ToLower()
			}
            What = @(
                        [pscustomobject]@{
                            ID = "{$($Task.GUID.ToString().ToUpper())}"
                            Type = $Type
                            Name = $Task.Name
                        }
                    )
            Who = @(
                foreach ($AMAgent in $arrAgents)
                {
                        [pscustomobject]@{
                            ID = "{$($amAgent.WUIDAgent.ToString().ToUpper())}"
                            Type = 0
                            Name = $AMAgent.Name
                        }
                }
            )
            Parameters = @($InputParameters)
		}
		$pREST = @{
			Uri = $Uri
			Method = "POST"
			Credential = $Credential
		}
		Invoke-RESAMRestMethod @pREST -Body (ConvertTo-Json $blob -Depth 99)
	}
}

