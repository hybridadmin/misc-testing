/*
    This function is triggered by creation or deletion of an AMI.  If the event indicates creation
    of an AMI, a message will be written to the backEvents queue to trigger the ec2ImageCopy lambda
    function in 15 minutes.  This delay is to allow time for the AMI to be available for copying.

    If the event indicates derigistration of an AMI then it deregisters it in the backup region.
*/
import 'source-map-support/register';
import { EventBridgeEvent, Context } from 'aws-lambda'
import { STSClient, AssumeRoleCommand } from "@aws-sdk/client-sts";
import { EC2Client, DescribeImagesCommand, DeregisterImageCommand, DeleteSnapshotCommand } from "@aws-sdk/client-ec2";
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";
import { notifyGeneral } from './shared';

const BACKUP_ACCOUNT_ID = process.env.backupAccount!;
const BACKUP_REGION = process.env.backupRegion!;
const PROJECT = process.env.project!.toUpperCase();
const ENVIRONMENT = process.env.environment!.toUpperCase();
const BACKUP_EVENTS_QUEUE_URL = process.env.backupEventsQueueUrl!;

const sqs = new SQSClient({});

interface Credentials {
    accessKeyId: string
    secretAccessKey: string
    sessionToken: string
}

const assumeRole = async (account: string, region: string) => {
    const sts = new STSClient({ region: region });
    const credentials = (await sts.send(new AssumeRoleCommand({
        RoleArn: `arn:aws:iam::${account}:role/${PROJECT}-${ENVIRONMENT}-BACKUP-CrossAccountBackupRole`,
        RoleSessionName: 'admin-backup-copy'
    }))).Credentials!;
    return {
        accessKeyId: credentials.AccessKeyId!,
        secretAccessKey: credentials.SecretAccessKey!,
        sessionToken: credentials.SessionToken
    }
}

const handleImageEvent = async (event: EventBridgeEvent<string, any>): Promise<void> => {
    console.info(JSON.stringify(event));

    const sourceCredentials = await assumeRole(event.account, BACKUP_REGION);
    const backupCredentials = event.region !== BACKUP_REGION ? sourceCredentials : await assumeRole(BACKUP_ACCOUNT_ID, BACKUP_REGION);
    const ec2SourceRegion = new EC2Client({credentials: sourceCredentials, region: BACKUP_REGION});
    const ec2BackupRegion = new EC2Client({credentials: backupCredentials, region: BACKUP_REGION});

    if (event.detail.eventName === 'CopyImage' && !event.detail.errorCode && !event.detail.requestParameters.name.startsWith('AwsBackup')) {
        // AMIs where the name starts with AwsBackup are from AWS Backup creating snapshots of running instances
        // These are already managed by AWS Backup so no need to copy them for DR
        const existingImages = (await ec2SourceRegion.send(new DescribeImagesCommand({
            Filters: [{ Name: 'tag:created_from', Values: [event.detail.responseElements.imageId] }]
        }))).Images;
        if (existingImages && existingImages.length > 0) {
            console.info('Image already exists - nothing to do');
        } else {
            await sqs.send(new SendMessageCommand({
                QueueUrl: BACKUP_EVENTS_QUEUE_URL,
                DelaySeconds: 900,
                MessageBody: JSON.stringify({
                    action: 'ec2ImageCopy',
                    sourceAccount: event.account,
                    sourceRegion: event.region,
                    imageId: event.detail.responseElements.imageId,
                })
            }));
        }
    } else if (event.detail.eventName === 'DeregisterImage') {
        // Find backup images and delete them
        const backupImages = (await ec2BackupRegion.send(new DescribeImagesCommand({
            Filters: [{ Name: 'tag:created_from', Values: [event.detail.requestParameters.imageId] }]
        }))).Images;
        if (backupImages) {
            for await (const image of backupImages) {
                console.info(`Deleting ${image.Name}(${image.ImageId})`);
                const snapshotIds = image.BlockDeviceMappings!.filter(bdm => bdm.Ebs && bdm.Ebs.SnapshotId).map(bdm => bdm.Ebs!.SnapshotId!);
                await ec2BackupRegion.send(new DeregisterImageCommand({ImageId: image.ImageId!}));
                for await (const snapshotId of snapshotIds) {
                    await ec2BackupRegion.send(new DeleteSnapshotCommand({SnapshotId: snapshotId}));
                }
            };
        }
    }
}

var functionName: string;
export const handler = async (event: EventBridgeEvent<string, any>, context: Context): Promise<any> => {
    functionName = context.functionName;
    try {
        return await handleImageEvent(event);
    } catch (err) {
        if (err instanceof Error) {
            await notifyGeneral(functionName, err.toString() + '\n' + err.stack);
            console.error(err.stack);
        }
        return err;
    }
}
