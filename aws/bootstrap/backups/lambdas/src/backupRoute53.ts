/*
    This function runs on a schedule and is passed an array of accounts whose Route 53 Hosted
    Zones are to be backed up.  It assumes a role in each of these accounts and dumps each of
    the Hoset Zones to JSON which it stores in an S3 Bucket in the backup account in the
    Oregon region.
*/
import 'source-map-support/register';
import { ScheduledEvent, Context } from 'aws-lambda'
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { STSClient, AssumeRoleCommand } from "@aws-sdk/client-sts";
import { Route53Client, ListHostedZonesCommand, HostedZone, ListResourceRecordSetsCommand } from "@aws-sdk/client-route-53";
import { notifyGeneral, asyncForEach } from './shared';

const BACKUP_ACCOUNT_ID = process.env.backupAccount!;
const BACKUP_REGION = process.env.backupRegion!;
const PROJECT = process.env.project!.toUpperCase();
const ENVIRONMENT = process.env.environment!.toUpperCase();
const CONFIG = process.env.config!;
const sts = new STSClient({region: BACKUP_REGION});

const backupRoute53 = async () => {
    const config = JSON.parse(CONFIG);
    const backupAccountCreds = (await sts.send(new AssumeRoleCommand({
        RoleArn: `arn:aws:iam::${BACKUP_ACCOUNT_ID}:role/${PROJECT}-${ENVIRONMENT}-BACKUP-CrossAccountBackupRole`,
        RoleSessionName: 'admin-backup-route53'
    }))).Credentials;
    const s3 = new S3Client({
        region: BACKUP_REGION,
        credentials: {
            accessKeyId: backupAccountCreds!.AccessKeyId!,
            secretAccessKey: backupAccountCreds!.SecretAccessKey!,
            sessionToken: backupAccountCreds!.SessionToken
        }
    });
    await asyncForEach(config, async (accountId: string) => {
        const sourceAccountCreds = (await sts.send(new AssumeRoleCommand({
            RoleArn: `arn:aws:iam::${accountId}:role/ORGRoleForBackupServices`,
            RoleSessionName: 'admin-backup-route53'
        }))).Credentials;
        const route53 = new Route53Client({
            credentials: {
                accessKeyId: sourceAccountCreds!.AccessKeyId!,
                secretAccessKey: sourceAccountCreds!.SecretAccessKey!,
                sessionToken: sourceAccountCreds!.SessionToken
            }
        });
        const hostedZones = (await route53.send(new ListHostedZonesCommand({}))).HostedZones;
        await asyncForEach(hostedZones!, async (zone: HostedZone) => {
            console.info(`Backuping up ${zone.Name} (${zone.Id})`);
            const records = (await route53.send(new ListResourceRecordSetsCommand({
                HostedZoneId: zone.Id,
                MaxItems: 1000
            }))).ResourceRecordSets;
            await s3.send(new PutObjectCommand({
                Bucket: `${PROJECT}-${ENVIRONMENT}-backups-${BACKUP_REGION}`.toLowerCase(),
                Key: `route53/${accountId}/${zone.Name}json`,
                Body: JSON.stringify(records),
                ACL: 'bucket-owner-full-control'
            }));
        });
    });
}

var functionName: string;
export const handler = async (event: ScheduledEvent, context: Context): Promise<any> => {
    functionName = context.functionName;
    try {
        return await backupRoute53();
    } catch (err) {
        if (err instanceof Error) {
            await notifyGeneral(functionName, err.toString() + '\n' + err.stack);
            console.error(err.stack);
        }
        return err;
    }
}
