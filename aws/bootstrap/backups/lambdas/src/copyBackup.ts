/*
    This function is triggered by an AWS Backup "Copy Job State Change" event.  If the event signals
    completion of a copy job, it initates a copy of the resource that was just copied to the Oregon
    region into the backup vault located in Oregon in the "backups" account.
*/
import 'source-map-support/register';
import { EventBridgeEvent, Context } from 'aws-lambda'
import { STSClient, AssumeRoleCommand } from "@aws-sdk/client-sts";
import { BackupClient, StartCopyJobCommand } from "@aws-sdk/client-backup";
import { notifyGeneral, asyncForEach } from './shared';

const BACKUP_ACCOUNT_ID = process.env.backupAccount!;
const BACKUP_REGION = process.env.backupRegion!;
const PROJECT = process.env.project!.toUpperCase();
const ENVIRONMENT = process.env.environment!.toUpperCase();
const BACKUP_VAULT_ARN = `arn:aws:backup:${BACKUP_REGION}:${BACKUP_ACCOUNT_ID}:backup-vault:${PROJECT}-${ENVIRONMENT}-backups`.toLowerCase();
const sts = new STSClient({region: BACKUP_REGION});

const copyBackup = async (event: EventBridgeEvent<string,any>) => {
    console.info(JSON.stringify(event));

    if (event.detail.state != 'COMPLETED') {
        return;
    }

    const sourceAccountId = event.account;
    const sourceRegion = /arn:aws:backup:(.*):.*:backup-vault:.*/.exec(event.detail.destinationBackupVaultArn)![1]
    const sourceVaultName = /arn:aws:backup:.*:.*:backup-vault:(.*)/.exec(event.detail.destinationBackupVaultArn)![1];
    const copyJobRoleArn = `arn:aws:iam::${sourceAccountId}:role/${PROJECT}-${ENVIRONMENT}-BACKUP-BackupSelectionRole-${BACKUP_REGION}`;

    const sourceAccountCreds = (await sts.send(new AssumeRoleCommand({
        RoleArn: `arn:aws:iam::${sourceAccountId}:role/${PROJECT}-${ENVIRONMENT}-BACKUP-CrossAccountBackupRole`,
        RoleSessionName: 'admin-backup-copy'
    }))).Credentials;

    const backup = new BackupClient({
        region: sourceRegion,
        credentials: {
            accessKeyId: sourceAccountCreds!.AccessKeyId!,
            secretAccessKey: sourceAccountCreds!.SecretAccessKey!,
            sessionToken: sourceAccountCreds!.SessionToken
        }
    });

    const copyJob = await backup.send(new StartCopyJobCommand({
        SourceBackupVaultName: sourceVaultName,
        RecoveryPointArn: event.detail.destinationRecoveryPointArn,
        DestinationBackupVaultArn: BACKUP_VAULT_ARN,
        IamRoleArn: copyJobRoleArn,
        Lifecycle: {
            DeleteAfterDays: 14
        }
    }));
    console.info(JSON.stringify(copyJob));
}

var functionName: string;
export const handler = async (event: EventBridgeEvent<string,any>, context: Context): Promise<any> => {
    functionName = context.functionName;
    try {
        return await copyBackup(event);
    } catch (err) {
        if (err instanceof Error) {
            await notifyGeneral(functionName, err.toString() + '\n' + err.stack);
            console.error(err.stack);
        }
        return err;
    }
}
