/*
    This function is triggered by creation or deletion of an ECR image.  For a PUSH event it will
    copy that image in to the backup region in the same account and the backup region in the backup
    account. If the repository doesn't exist in the target region it will be created.

    For a DELETE event, the image will be deleted from the backup region in the same account and the
    backup region in the backup account. If there are no images left in the repository it will be
    deleted as well.
*/
import 'source-map-support/register';
import { EventBridgeEvent, Context } from 'aws-lambda'
import { STSClient, AssumeRoleCommand } from "@aws-sdk/client-sts";
import { ECRClient, CreateRepositoryCommand, BatchDeleteImageCommand, DeleteRepositoryCommand } from "@aws-sdk/client-ecr";
import { RepositoryAlreadyExistsException, RepositoryNotFoundException, RepositoryNotEmptyException } from "@aws-sdk/client-ecr";
import { CodeBuildClient, StartBuildCommand } from '@aws-sdk/client-codebuild';
import { notifyGeneral } from './shared';

const BACKUP_ACCOUNT_ID = process.env.backupAccount!;
const BACKUP_REGION = process.env.backupRegion!;
const PROJECT = process.env.project!.toUpperCase();
const ENVIRONMENT = process.env.environment!.toUpperCase();
const COPY_IMAGE_PROJECT = process.env.copyImageProject!;

const codebuild = new CodeBuildClient({});

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

const createRepositoryIfNotExist = async (ecr: ECRClient, repositoryName: string) => {
    try {
        await ecr.send(new CreateRepositoryCommand({ repositoryName: repositoryName }));
    } catch (err) {
        if (!(err instanceof RepositoryAlreadyExistsException)) {
            throw err;
        }
    }
}

const deleteRepositoryIfEmpty = async (ecr: ECRClient, repositoryName: string) => {
    try {
        await ecr.send(new DeleteRepositoryCommand({ repositoryName: repositoryName }));
    } catch (err) {
        if (!(err instanceof RepositoryNotFoundException || err instanceof RepositoryNotEmptyException)) {
            throw err;
        }
    }
}

const handleImageEvent = async (event: EventBridgeEvent<string, any>): Promise<void> => {
    console.info(JSON.stringify(event));

    // If the original copy/delete failed then nothing to do
    if (event.detail.result !== 'SUCCESS') {
        return;
    }

    const sourceCredentials = await assumeRole(event.account, BACKUP_REGION);
    const backupCredentials = await assumeRole(BACKUP_ACCOUNT_ID, BACKUP_REGION);
    const ecrSourceRegion = new ECRClient({credentials: sourceCredentials, region: BACKUP_REGION});
    const ecrBackupRegion = new ECRClient({credentials: backupCredentials, region: BACKUP_REGION});

    if (event.detail['action-type'] === 'PUSH') {
        await createRepositoryIfNotExist(ecrSourceRegion, event.detail['repository-name']);
        await createRepositoryIfNotExist(ecrBackupRegion, event.detail['repository-name']);
        await codebuild.send(new StartBuildCommand({
            projectName: COPY_IMAGE_PROJECT,
            environmentVariablesOverride: [
                {name: 'SRC_ACCOUNT', type: 'PLAINTEXT', value: event.account},
                {name: 'SRC_REGION', type: 'PLAINTEXT', value: event.region},
                {name: 'IMAGE_NAME', type: 'PLAINTEXT', value: event.detail['repository-name']},
                {name: 'IMAGE_TAG', type: 'PLAINTEXT', value: event.detail['image-tag']}
            ]
        }))
    } else if (event.detail['action-type'] === 'DELETE') {
        const batchDeleteImageCommand = new BatchDeleteImageCommand({
            repositoryName: event.detail['repository-name'],
            imageIds: [{imageDigest: event.detail['image-digest'], imageTag: event.detail['image-tag']}]
        });
        await ecrSourceRegion.send(batchDeleteImageCommand);
        await ecrBackupRegion.send(batchDeleteImageCommand);
        await deleteRepositoryIfEmpty(ecrSourceRegion, event.detail['repository-name']);
        await deleteRepositoryIfEmpty(ecrBackupRegion, event.detail['repository-name']);
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
