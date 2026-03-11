/*
    This function is triggered by an event being written to the backupEvents queue.  Possible actions
    resulting from reading an event from the queue include:
    * Coping an AMI to the backup region in the source account
    * Tagging the backup image with "created_from" tag with value of source image id

    Because messages are processed in batches, any record in the batch failing means the whole batch
    will be reprocessed.  So any message processing needs to be idempotent.
*/
import 'source-map-support/register';
import { Context, SQSEvent, SQSRecord } from 'aws-lambda'
import { STSClient, AssumeRoleCommand } from "@aws-sdk/client-sts";
import { SQSClient, SendMessageCommand } from "@aws-sdk/client-sqs";
import { EC2Client, DescribeImagesCommand, CopyImageCommand, CreateTagsCommand, ModifyImageAttributeCommand, ModifySnapshotAttributeCommand, EC2ServiceException } from "@aws-sdk/client-ec2";
import { notifyGeneral } from './shared';

const BACKUP_ACCOUNT_ID = process.env.backupAccount!;
const BACKUP_REGION = process.env.backupRegion!;
const PROJECT = process.env.project!.toUpperCase();
const ENVIRONMENT = process.env.environment!.toUpperCase();
const BACKUP_EVENTS_QUEUE_URL = process.env.backupEventsQueueUrl!;
const ORGANIZATION_ARN = process.env.organizationArn!;
const AMI_ENCRYPTION_KMS_KEY_ARN = process.env.amiEncryptionKmsKeyArn!;

const sqs = new SQSClient({});

// Array of expected errors that can occur if resources are not yet ready fr processing.  We don't send
// alert messages if any of these exceptions are thrown.
const EXPECTED_ERRORS = [
    'The storage for the ami is not available in the source region.'
]

interface Credentials {
    accessKeyId: string
    secretAccessKey: string
    sessionToken: string
}

const assumeRole = async (account: string, region: string) => {
    const sts = new STSClient({region: region});
    const credentials = (await sts.send(new AssumeRoleCommand({
        RoleArn: `arn:aws:iam::${account}:role/${PROJECT}-${ENVIRONMENT}-BACKUP-CrossAccountBackupRole`,
        RoleSessionName: 'admin-backup-copy'
    }))).Credentials!;
    return {
        accessKeyId: credentials.AccessKeyId!,
        secretAccessKey: credentials.SecretAccessKey!,
        sessionToken: credentials.SessionToken!
    }
}

const handleImageEvent = async (record: SQSRecord): Promise<void> => {
    const body = JSON.parse(record.body);
    console.info(JSON.stringify(body));

    if (body.action === 'ec2ImageCopy') {
        const sourceCredentials = await assumeRole(body.sourceAccount, BACKUP_REGION);
        const backupCredentials = body.sourceRegion !== BACKUP_REGION ? sourceCredentials : await assumeRole(BACKUP_ACCOUNT_ID, BACKUP_REGION);
        const ec2SourceRegion = new EC2Client({credentials: sourceCredentials, region: body.sourceRegion});
        const ec2BackupRegion = new EC2Client({credentials: backupCredentials, region: BACKUP_REGION});
        const existingImages = (await ec2BackupRegion.send(new DescribeImagesCommand({
            Filters: [{ Name: 'tag:created_from', Values: [body.imageId] }]
        }))).Images;
        if (existingImages && existingImages.length > 0) {
            console.info('Image already exists - nothing to do');
            return;
        }
        const image = (await ec2SourceRegion.send(new DescribeImagesCommand({
            ImageIds: [body.imageId]
        }))).Images![0];
        if (!image.BlockDeviceMappings || image.BlockDeviceMappings.length === 0 || image.State !== 'available') {
            throw new Error('ResourceNotReady');
        }
        const backupImageId = (await ec2BackupRegion.send(new CopyImageCommand({
            SourceRegion: body.sourceRegion,
            SourceImageId: body.imageId,
            Name: image.Name,
            Description: image.Description,
            Encrypted: true,
            KmsKeyId: AMI_ENCRYPTION_KMS_KEY_ARN,
            CopyImageTags: true
        }))).ImageId;
        // Defer tagging until image is created
        await sqs.send(new SendMessageCommand({
            QueueUrl: BACKUP_EVENTS_QUEUE_URL,
            DelaySeconds: 900,
            MessageBody: JSON.stringify({
                action: 'ec2Tag&ShareImage',
                backupImageId: backupImageId,
                sourceAccount: body.sourceRegion !== BACKUP_REGION ? body.sourceAccount : BACKUP_ACCOUNT_ID,
                sourceImageId: body.imageId,
                tags: image.Tags
            })
        }));

    } else if (body.action === 'ec2Tag&ShareImage') {
        const credentials = await assumeRole(body.sourceAccount, BACKUP_REGION);
        const ec2 = new EC2Client({credentials, region: BACKUP_REGION});
        const image = (await ec2.send(new DescribeImagesCommand({
            ImageIds: [body.backupImageId]
        }))).Images![0];
        if (!image.BlockDeviceMappings || image.BlockDeviceMappings.length === 0 || image.State !== 'available') {
            throw new Error('ResourceNotReady');
        }
        const snapshotIds = image.BlockDeviceMappings!.filter(bdm => bdm.Ebs && bdm.Ebs.SnapshotId).map(bdm => bdm.Ebs!.SnapshotId!);
        await ec2.send(new CreateTagsCommand({
            Resources: [body.backupImageId, ...snapshotIds],
            Tags: [
                {Key: 'created_from', Value: body.sourceImageId},
                ...body.tags.filter((tag: {Key: string, Value: string}) => tag.Key !== 'created_from')
            ]
        }));
        if (body.sourceAccount !== BACKUP_ACCOUNT_ID) {
            await ec2.send(new ModifyImageAttributeCommand({
                ImageId: body.backupImageId,
                LaunchPermission: {
                    Add: [{UserId: BACKUP_ACCOUNT_ID}]
                }
            }));
            for await (const snapshotId of snapshotIds) {
                await ec2.send(new ModifySnapshotAttributeCommand({
                    SnapshotId: snapshotId,
                    Attribute: 'createVolumePermission',
                    OperationType: 'add',
                    UserIds: [BACKUP_ACCOUNT_ID]
                }));
            }
        } else {
            await ec2.send(new ModifyImageAttributeCommand({
                ImageId: body.backupImageId,
                LaunchPermission: {
                    Add: [{OrganizationArn: ORGANIZATION_ARN}]
                }
            }));
        }
    }
}

var functionName: string;
export const handler = async (event: SQSEvent, context: Context): Promise<any> => {
    functionName = context.functionName;
    try {
        for await (const record of event.Records) {
            await handleImageEvent(record)
        }
    } catch (err) {
        if (err instanceof EC2ServiceException && EXPECTED_ERRORS.includes(err.message)) {
            console.error(JSON.stringify(err));
        } else if (err instanceof Error && err.message !== 'ResourceNotReady') {
            await notifyGeneral(functionName, err.toString() + '\n' + err.stack);
            console.error(err.stack);
        }
        throw err;
    }
}
