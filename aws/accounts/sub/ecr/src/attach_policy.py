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
    def get_lifecycle_policy(ecr: Repository):
        b3.setup_default_session()
        cli = b3.client("ecr", region_name=ecr.region)
        try:
            response = cli.get_lifecycle_policy(repositoryName=ecr.repository_name)
            if response is None or response == "":
                return False
            return response
        except Exception as e:
            if type(e).__name__ == "LifecyclePolicyNotFoundException":
                return False
            else:
                raise Exception(str(e))

    @staticmethod
    def build_lifecycle_policy(max_image_count: int) -> str:
        """Build ECR lifecycle policy JSON."""
        policy = {
            "rules": [
                {
                    "rulePriority": 1,
                    "selection": {
                        "tagStatus": "any",
                        "countType": "imageCountMoreThan",
                        "countNumber": max_image_count,
                    },
                    "action": {"type": "expire"},
                }
            ]
        }
        return json.dumps(policy)

    def add_lifecycle_policy(self, ecr: Repository, policy_text: str):
        b3.setup_default_session()
        cli = b3.client("ecr", region_name=ecr.region)
        try:
            response = cli.put_lifecycle_policy(
                repositoryName=ecr.repository_name, lifecyclePolicyText=policy_text
            )
            return response
        except Exception as e:
            raise Exception(str(e))

    def attach(self):
        if not self.ecr_target:
            raise Exception("Missing ecr_target")

        existing_policy = self.get_lifecycle_policy(self.ecr_target)
        if not existing_policy:
            max_count = int(os.environ.get("MAX_IMAGE_COUNT", "10"))
            logger.info(
                "No existing lifecycle policy found, applying (max images: %d)",
                max_count,
            )

            policy_text = self.build_lifecycle_policy(max_count)
            logger.info("Lifecycle policy to apply: %s", policy_text)
            self.add_lifecycle_policy(self.ecr_target, policy_text)
            logger.info(
                "Lifecycle policy applied successfully to %s",
                self.ecr_target.repository_name,
            )
        else:
            formatted_policy = json.dumps(
                existing_policy, indent=4, sort_keys=True, default=str
            )
            logger.info("Lifecycle policy already exists: %s", formatted_policy)


def lambda_handler(event, context):
    logger.info("REQUEST RECEIVED: %s", event)
    logger.info("REQUEST CONTEXT: %s", context)

    target_repo = str(event["detail"]["requestParameters"]["repositoryName"])
    target_account = str(event["account"])
    target_region = str(event["region"])

    repo_info = Repository(target_repo, target_region, target_account)
    policy = PolicyECR(repo_info)
    policy.attach()
