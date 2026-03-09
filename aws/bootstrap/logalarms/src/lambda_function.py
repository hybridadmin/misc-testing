"""
LogsAlarm Lambda Function

Triggered by EventBridge when a CloudWatch alarm transitions to ALARM state.
If the alarm is based on a metric filter, this function collects a sample of
log events from the associated Log Group and publishes them to the alarm's
SNS notification topic(s).
"""

import json
import datetime
import boto3


def lambda_handler(event, context):
    cw = boto3.client("cloudwatch")
    logs = boto3.client("logs")

    alarm_name = event["detail"]["alarmName"]
    alarms = cw.describe_alarms(AlarmNames=[alarm_name])

    try:
        metric_alarms = alarms.get("MetricAlarms", [])
        if not metric_alarms or not metric_alarms[0].get("AlarmActions"):
            print(f"No metric alarms or alarm actions found for: {alarm_name}")
            return
    except (KeyError, IndexError):
        print(f"Unexpected alarm structure: {json.dumps(alarms, default=str)}")
        return

    alarm_sns_topics = metric_alarms[0]["AlarmActions"]
    metrics = event["detail"]["configuration"]["metrics"]

    # For metrics derived from a metric filter, extract log group messages
    # from the last 5 minutes
    log_groups = []

    for m in metrics:
        try:
            metric_namespace = m["metricStat"]["metric"]["namespace"]
            # Skip AWS-native metrics (only process custom metric-filter metrics)
            if metric_namespace.startswith("AWS"):
                continue

            metric_name = m["metricStat"]["metric"]["name"]
        except KeyError:
            continue

        result = logs.describe_metric_filters(
            metricNamespace=metric_namespace,
            metricName=metric_name,
        )

        metric_filters = result.get("metricFilters", [])
        if not metric_filters:
            print(f"No metric filters found for {metric_namespace}/{metric_name}")
            continue

        # Get the sorted dimensions from the alarm metric for comparison
        metric_dimensions = sorted(
            m["metricStat"]["metric"].get("dimensions", {}).items()
        )

        has_matching_dimensions = False
        matched_filter = None

        for mf in metric_filters:
            for t in mf.get("metricTransformations", []):
                transform_dimensions = sorted((t.get("dimensions") or {}).items())
                if metric_dimensions == transform_dimensions:
                    has_matching_dimensions = True
                    matched_filter = mf
                    break
            if has_matching_dimensions:
                break

        if has_matching_dimensions and matched_filter:
            log_group_name = matched_filter["logGroupName"]

            # filter_log_events expects startTime as epoch milliseconds
            start_time = int(
                (
                    datetime.datetime.now(datetime.timezone.utc)
                    - datetime.timedelta(minutes=5)
                ).timestamp()
                * 1000
            )

            try:
                messages = logs.filter_log_events(
                    logGroupName=log_group_name,
                    startTime=start_time,
                    limit=50,
                )
                log_groups.append(
                    {
                        "logGroupName": log_group_name,
                        "messages": messages.get("events", []),
                    }
                )
            except Exception as e:
                print(f"Error fetching log events from {log_group_name}: {e}")

    if log_groups:
        sns = boto3.client("sns")
        log_group_text = json.dumps(log_groups, default=str)

        for topic_arn in alarm_sns_topics:
            try:
                sns.publish(
                    TargetArn=topic_arn,
                    Subject=f"ALARM: {alarm_name}"[:100],  # SNS subject max 100 chars
                    Message=(
                        "Extract of log records associated with this "
                        f"metric filter based alarm:\n{log_group_text}"
                    ),
                )
                print(f"Published log sample to {topic_arn}")
            except Exception as e:
                print(f"Error publishing to {topic_arn}: {e}")
    else:
        print(
            f"No log groups with matching metric filters found for alarm: {alarm_name}"
        )
