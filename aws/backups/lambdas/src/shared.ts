/*
Shared library for reusing code across multiple Lambda functions.
*/

import { SNSClient, PublishCommand } from '@aws-sdk/client-sns';
const sns = new SNSClient({});

const PROJECT = process.env.project!.toUpperCase();
const ENVIRONMENT = process.env.environment!.toUpperCase();
const CRITICAL_NOTIFICATION_TOPIC = process.env.criticalNotificationTopic;
const GENERAL_NOTIFICATION_TOPIC = process.env.generalNotificationTopic;

export async function notifyCritical(functionName: string, msgText: string) {
    console.info(`Sending SNS critical message: ${msgText} TO ${CRITICAL_NOTIFICATION_TOPIC}`);
    msgText = "Lambda function '" + functionName + "' critical notification:\n" + msgText;
    try {
        await sns.send(new PublishCommand({
            TargetArn: CRITICAL_NOTIFICATION_TOPIC,
            Subject: `${functionName} CRITICAL NOTIFICATION`,
            Message: msgText
        }));
    } catch(err) {
        console.error(`SNS:Publish failed: ${err}`);
    }
}

export async function notifyGeneral(functionName: string, msgText: string) {
    console.info(`Sending SNS general message: ${msgText} TO ${GENERAL_NOTIFICATION_TOPIC}`);
    msgText = "Lambda function '" + functionName + "' general notification:\n" + msgText;
    try {
        await sns.send(new PublishCommand({
            TargetArn: GENERAL_NOTIFICATION_TOPIC,
            Subject: `${functionName} GENERAL NOTIFICATION`,
            Message: msgText
        }));
    } catch(err) {
        console.error(`SNS:Publish failed: ${err}`);
    }
}

export async function asyncForEach(iterable: Iterable<any>, callback: Function, sequential=false) {
    let promises = [];
    for (let value of iterable) {
        let promise = callback(value);
        promises.push(promise);
        if (sequential) {await promise}
    }
    return Promise.all(promises);
}
