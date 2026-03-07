import boto3 as b3
import json
import os
import logging

# Setting up logging
logger = logging.getLogger()
logging.basicConfig(level=logging.INFO)
logger.setLevel(logging.INFO)


class Repository:
    def __init__(self, repository_name: str, region: str, account_id: str):
        self.repository_name = repository_name
        self.region = region
        self.account_id = account_id

    def __str__(self):
        return json.dumps(self.__dict__)


class PolicyECR:
    def __init__(self, ecr_target: Repository = None):
        self.ecr_target = ecr_target

    @staticmethod
    def get_repo_policy(ecr: Repository):
        b3.setup_default_session()
        cli = b3.client("ecr", region_name=ecr.region)
        try:
            response = cli.get_repository_policy(repositoryName=ecr.repository_name)
            if response is None or response == "":
                return False
            return response
        except Exception as e:
            if type(e).__name__ == "RepositoryPolicyNotFoundException":
                return False
            else:
                raise Exception(str(e))

    @staticmethod
    def build_policy_text(pull_account_ids: list, push_account_ids: list) -> str:
        """Build ECR repository policy from account ID lists."""
        statements = []

        if pull_account_ids:
            pull_principals = [f"arn:aws:iam::{aid}:root" for aid in pull_account_ids]
            statements.append(
                {
                    "Sid": "ImagePullPermissions",
                    "Effect": "Allow",
                    "Principal": {"AWS": pull_principals},
                    "Action": [
                        "ecr:BatchCheckLayerAvailability",
                        "ecr:BatchGetImage",
                        "ecr:GetDownloadUrlForLayer",
                    ],
                }
            )

        if push_account_ids:
            push_principals = [f"arn:aws:iam::{aid}:root" for aid in push_account_ids]
            statements.append(
                {
                    "Sid": "ImagePushPermissions",
                    "Effect": "Allow",
                    "Principal": {"AWS": push_principals},
                    "Action": [
                        "ecr:CompleteLayerUpload",
                        "ecr:InitiateLayerUpload",
                        "ecr:PutImage",
                        "ecr:UploadLayerPart",
                    ],
                }
            )

        policy = {"Version": "2012-10-17", "Statement": statements}
        return json.dumps(policy)

    def add_repo_policy(self, ecr: Repository, policy_text: str):
        b3.setup_default_session()
        cli = b3.client("ecr", region_name=ecr.region)
        try:
            response = cli.set_repository_policy(
                repositoryName=ecr.repository_name, policyText=policy_text
            )
            return response
        except Exception as e:
            raise Exception(str(e))

    def add(self):
        if not self.ecr_target:
            raise Exception("Missing ecr_target")

        existing_policy = self.get_repo_policy(self.ecr_target)
        if not existing_policy:
            logger.info("No existing policy found, adding cross-account policy")

            pull_ids = json.loads(os.environ.get("PULL_ACCOUNT_IDS", "[]"))
            push_ids = json.loads(os.environ.get("PUSH_ACCOUNT_IDS", "[]"))

            if not pull_ids and not push_ids:
                logger.warning(
                    "No PULL_ACCOUNT_IDS or PUSH_ACCOUNT_IDS configured, skipping"
                )
                return

            policy_text = self.build_policy_text(pull_ids, push_ids)
            logger.info("Policy to apply: %s", policy_text)
            self.add_repo_policy(self.ecr_target, policy_text)
            logger.info(
                "Policy applied successfully to %s", self.ecr_target.repository_name
            )
        else:
            formatted_policy = json.dumps(
                existing_policy, indent=4, sort_keys=True, default=str
            )
            logger.info("Policy already exists: %s", formatted_policy)


def lambda_handler(event, context):
    logger.info("REQUEST RECEIVED: %s", event)
    logger.info("REQUEST CONTEXT: %s", context)

    target_repo = str(event["detail"]["requestParameters"]["repositoryName"])
    target_account = str(event["account"])
    target_region = str(event["region"])

    repo_info = Repository(target_repo, target_region, target_account)
    policy = PolicyECR(repo_info)
    policy.add()
