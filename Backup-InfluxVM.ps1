<#
.SYNOPSIS
    Azure Automation runbook: application-consistent backup di una VM Linux che ospita InfluxDB.

    Per avere uno snapshot coerente, il database va fermato mentre si fa il backup. La VM
    alimenta un feeder in esecuzione come deployment su un cluster AKS, quindi la sequenza e':

      1 - stop del feeder su AKS (scale a 0, attesa terminazione pod)
      2 - stop del servizio InfluxDB sulla VM
      3 - backup on-demand della VM (Azure Backup / Recovery Services vault)
      4 - start di InfluxDB (con attesa del warm-up)
      5 - start del feeder su AKS

    Gli step 4 e 5 sono in un blocco finally: il servizio e il feeder ripartono anche se
    il backup fallisce, cosi' l'ambiente non resta mai in stato degradato.

.NOTES
    Runtime  : PowerShell 7.4 (modulo Az)
    Auth     : managed identity dell'Automation Account (Connect-AzAccount -Identity)

    Ruoli richiesti dalla managed identity:
      - Backup Operator sul Recovery Services vault
      - un ruolo con Microsoft.Compute/virtualMachines/runCommand/action sulla VM
        (es. Virtual Machine Contributor)
      - Azure Kubernetes Service Contributor Role sul cluster AKS (per il Run Command)
      - Azure Kubernetes Service RBAC Writer sul namespace del deployment

    Lezioni dai test (documentate per riuso):
      - Il vault rifiuta una scadenza inferiore a 1 giorno pieno su un backup on-demand:
        'adesso + 1 giorno', ritardato dagli step precedenti, cade sotto il minimo.
        RetentionDays = 2 da' margine. Per tenere SEMPRE esattamente N punti serve una
        pulizia esplicita dei recovery point piu' vecchi, non la sola scadenza.
      - Dopo lo stop, al riavvio InfluxDB ricostruisce la cache in memoria e resta in
        stato 'activating' per diversi minuti su dataset grandi: l'attesa dello start
        va dimensionata di conseguenza (qui 15 minuti).
#>
param(
    [string] $SubscriptionId     = '<SUBSCRIPTION_ID_OR_NAME>',
    [string] $AksResourceGroup   = '<AKS_RESOURCE_GROUP>',
    [string] $AksClusterName     = '<AKS_CLUSTER_NAME>',
    [string] $K8sNamespace       = '<K8S_NAMESPACE>',
    [string] $DeploymentName     = '<K8S_DEPLOYMENT_NAME>',
    # $false = non tocca il feeder (fa solo stop/backup/start di InfluxDB):
    # in quel caso i parametri AKS non sono necessari.
    [bool]   $ManageFeeder       = $true,
    [string] $VaultResourceGroup = '<VAULT_RESOURCE_GROUP>',
    [string] $VaultName          = '<RECOVERY_SERVICES_VAULT_NAME>',
    [string] $VmName             = '<VM_NAME>',
    [string] $InfluxService      = 'influxdb',
    [int]    $RetentionDays      = 2   # vedi .NOTES: 1 giorno e' il minimo del vault, 2 da' margine
)

$ErrorActionPreference = 'Stop'

# Blocca l'avvio se un parametro obbligatorio e' rimasto a placeholder.
$required = @('SubscriptionId','VaultResourceGroup','VaultName','VmName')
if ($ManageFeeder) { $required += 'AksResourceGroup','AksClusterName','K8sNamespace','DeploymentName' }
foreach ($p in $required) {
    if ([string](Get-Variable $p -ValueOnly) -like '<*') { throw "Parametro '$p' non configurato (placeholder presente)." }
}

function Write-Log([string] $Message) {
    Write-Output ("[{0:yyyy-MM-dd HH:mm:ss}Z] {1}" -f (Get-Date).ToUniversalTime(), $Message)
}

# Invoke-AzAksRunCommand termina con successo anche quando kubectl fallisce:
# senza questo controllo lo step 1 potrebbe fallire in silenzio e il backup
# verrebbe eseguito con il feeder ancora acceso.
function Invoke-Kubectl([string] $Command) {
    $r = Invoke-AzAksRunCommand -ResourceGroupName $AksResourceGroup -Name $AksClusterName -Command $Command -Force
    if ($r.ExitCode -ne 0) { throw "kubectl fallito (exit $($r.ExitCode)): $($r.Logs)" }
    return "$($r.Logs)".Trim()
}

# Run Command non propaga l'exit code dello script remoto: l'esito si legge dall'output.
function Invoke-VmShell([string] $Script) {
    $res = Invoke-AzVMRunCommand -ResourceGroupName $script:VmResourceGroup -VMName $VmName `
                                 -CommandId 'RunShellScript' -ScriptString $Script
    return ($res.Value | ForEach-Object { $_.Message }) -join "`n"
}

Connect-AzAccount -Identity | Out-Null
Set-AzContext -Subscription $SubscriptionId | Out-Null

$vm = @(Get-AzVM -Name $VmName)
if ($vm.Count -ne 1) { throw "Attesi 1 risultato per la VM $VmName, trovati $($vm.Count)." }
$script:VmResourceGroup = $vm[0].ResourceGroupName

$replicas      = 1
$feederStopped = $false
$influxStopped = $false
$influxUp      = $true
$failed        = $false

try {
    # --- 1 - stop del feeder su AKS --------------------------------------------
    if ($ManageFeeder) {
        $replicas = [int](Invoke-Kubectl "kubectl get deployment $DeploymentName -n $K8sNamespace -o jsonpath='{.spec.replicas}'")
        Write-Log "Repliche attuali: $replicas"
        if ($replicas -le 0) { throw "Il deployment e' gia' a 0 repliche: stato anomalo, interrompo." }

        Invoke-Kubectl "kubectl scale deployment $DeploymentName -n $K8sNamespace --replicas=0" | Out-Null
        $feederStopped = $true

        $deadline = (Get-Date).AddMinutes(10)
        do {
            Start-Sleep -Seconds 15
            $pods = @((Invoke-Kubectl "kubectl get pods -n $K8sNamespace -o name") -split "`n" |
                      Where-Object { $_.Trim() -like "pod/$DeploymentName-*" }).Count
            Write-Log "Pod ancora attivi: $pods"
        } while ($pods -gt 0 -and (Get-Date) -lt $deadline)
        if ($pods -gt 0) { throw "I pod del feeder non sono terminati entro 10 minuti." }
        Write-Log "Feeder fermo."
    }
    else {
        Write-Log "ManageFeeder = false: il feeder non viene toccato."
    }

    # --- 2 - stop del servizio InfluxDB ----------------------------------------
    # Il flag va alzato PRIMA dello stop: se lo stop fallisce a meta', il finally prova comunque a riavviare.
    $influxStopped = $true
    $stopScript = @'
systemctl stop __SVC__
echo "STATE=$(systemctl is-active __SVC__)"
'@.Replace('__SVC__', $InfluxService)
    $out = Invoke-VmShell $stopScript
    Write-Log "Stop InfluxDB: $($out.Trim())"
    if ($out -notmatch 'STATE=(inactive|failed)') { throw "InfluxDB non risulta fermo: $out" }

    # --- 3 - backup on-demand della VM -----------------------------------------
    $vault     = Get-AzRecoveryServicesVault -ResourceGroupName $VaultResourceGroup -Name $VaultName
    $container = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -FriendlyName $VmName -VaultId $vault.ID
    $item      = Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType AzureVM -VaultId $vault.ID
    $expiry    = (Get-Date).ToUniversalTime().AddDays($RetentionDays)
    $job       = Backup-AzRecoveryServicesBackupItem -Item $item -VaultId $vault.ID -ExpiryDateTimeUTC $expiry
    Write-Log "Backup avviato: job $($job.JobId), scadenza $expiry UTC"

    # Si attende il solo Take Snapshot: lo snapshot e' il punto che richiede il servizio fermo.
    # Il trasferimento al vault prosegue poi in background e non necessita del servizio spento.
    $deadline = (Get-Date).AddMinutes(60)
    do {
        Start-Sleep -Seconds 60
        $details = Get-AzRecoveryServicesBackupJobDetail -JobId $job.JobId -VaultId $vault.ID
        $snap    = $details.SubTasks | Where-Object { $_.Name -eq 'Take Snapshot' }
        Write-Log "Stato: $($details.Status) | Take Snapshot: $($snap.Status)"
        if ($details.Status -in @('Failed','Cancelled')) { throw "Backup terminato in stato $($details.Status)." }
        $done = ($snap.Status -eq 'Completed') -or ($details.Status -in @('Completed','CompletedWithWarnings'))
    } while (-not $done -and (Get-Date) -lt $deadline)
    if (-not $done) { throw "Timeout di 60 minuti in attesa del backup." }
    Write-Log "Snapshot completato."
}
catch {
    $failed = $true
    Write-Error "ERRORE: $($_.Exception.Message)" -ErrorAction Continue
}
finally {
    # --- 4 - start di InfluxDB -------------------------------------------------
    # Nel finally: InfluxDB e feeder devono ripartire anche se il backup fallisce.
    if ($influxStopped) {
        try {
            # Polling fino a 15 minuti: al riavvio InfluxDB ricostruisce la cache in memoria
            # e resta in 'activating' per diversi minuti su dataset grandi.
            $startScript = @'
systemctl start __SVC__
for i in $(seq 1 60); do
  s=$(systemctl is-active __SVC__)
  [ "$s" = "active" ] && break
  sleep 15
done
echo "STATE=$s"
'@.Replace('__SVC__', $InfluxService)
            $out = Invoke-VmShell $startScript
            Write-Log "Start InfluxDB: $($out.Trim())"
            if ($out -notmatch 'STATE=active') { throw "InfluxDB non e' attivo dopo lo start: $out" }
        }
        catch {
            $failed   = $true
            $influxUp = $false
            Write-Error "ERRORE CRITICO: InfluxDB non riavviato (il feeder NON viene riacceso). Ripristino manuale su $VmName`: systemctl start $InfluxService, poi kubectl scale deployment $DeploymentName -n $K8sNamespace --replicas=$replicas | Dettaglio: $($_.Exception.Message)" -ErrorAction Continue
        }
    }

    # --- 5 - start del feeder su AKS -------------------------------------------
    if ($feederStopped -and $influxUp) {
        try {
            Invoke-Kubectl "kubectl scale deployment $DeploymentName -n $K8sNamespace --replicas=$replicas" | Out-Null
            Invoke-Kubectl "kubectl rollout status deployment/$DeploymentName -n $K8sNamespace --timeout=600s" | Out-Null
            Write-Log "Feeder ripartito ($replicas repliche)."
        }
        catch {
            $failed = $true
            Write-Error "ERRORE CRITICO: feeder non riavviato. Ripristino manuale: kubectl scale deployment $DeploymentName -n $K8sNamespace --replicas=$replicas | Dettaglio: $($_.Exception.Message)" -ErrorAction Continue
        }
    }
}

if ($failed) { throw "Runbook terminato con errori." }
Write-Log "Completato."
