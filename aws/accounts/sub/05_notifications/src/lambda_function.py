"""AWS Health Events Slack Notifier.

Receives AWS Health events via EventBridge and posts a formatted
notification to a configured Slack channel using an incoming webhook.

Ported from the inline ZipFile Lambda in:
  devops-utilities-notifications/stacksets/template.json
"""

from __future__ import print_function

import json
import logging
import os
from urllib.request import Request, urlopen, URLError, HTTPError

# Configuration from environment variables
SLACK_CHANNEL = "#{}".format(os.environ.get("SLACK_CHANNEL", ""))
HOOK_URL = os.environ.get("WEBHOOK_URL", "")

# Logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)


def handler(event, context):
    """Lambda entry point.

    Args:
        event: AWS Health event forwarded by EventBridge.
        context: Lambda context object.
    """
    logger.info("REQUEST RECEIVED: %s", event)

    latest_description = str(
        event["detail"]["eventDescription"][0]["latestDescription"]
        + os.linesep
        + os.linesep
    )
    event_arn = event["detail"]["eventArn"]

    message = (
        str(
            latest_description
            + "<https://phd.aws.amazon.com/phd/home?region=us-east-1#/event-log?eventID="
            + event_arn
            + "|Click here> for details."
        )
        .replace("\\n", "\n")
        .replace("\\t", "\t")
    )

    json.dumps(message)

    slack_message = {
        "channel": SLACK_CHANNEL,
        "text": message,
        "username": "AWS Account: {} - Health Updates".format(event["account"]),
    }

    logger.info(str(slack_message))

    req = Request(
        HOOK_URL,
        data=json.dumps(slack_message).encode("utf-8"),
        headers={"content-type": "application/json"},
    )

    try:
        response = urlopen(req)
        response.read()
        logger.info("Message posted to: %s", slack_message["channel"])
    except HTTPError as e:
        logger.error("Request failed : %d %s", e.code, e.reason)
    except URLError as e:
        logger.error("Server connection failed: %s", e.reason)
