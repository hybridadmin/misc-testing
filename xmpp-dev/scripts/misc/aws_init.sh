#!/bin/bash

AWS_ACCOUNT_ID=$1 #"597684347793"
APP_ENVIRONMENT=$2 #"1GRID"

APP_DOMAIN_NAME=$3 #"xmpp.onpremise.moya.app"
APP_HOSTED_ZONE_ID=$4 #"Z07579363KLIWSZ4REYFT"

APP_PROJECT="XMPPONPREMISE"
APP_ROLE=$(echo $HOSTNAME | cut -d '-' -f1 | tr '[:lower:]' '[:upper:]')
AWS_STACK="${APP_PROJECT}-${APP_ENVIRONMENT}-${APP_ROLE}"

APP_XMPP_USERNAME=""
APP_XMPP_PASSWORD=""
APP_GRAPHITE_HOST="postgres-02.onpremise.xmpp.${APP_DOMAIN_NAME}"
APP_ALTERNATIVE_DOMAIN_NAME="xmpp.onpremise.datafree10.co"
IOS_DOMAIN_NAME="ios.onpremise.datafree10.co"

AWS_INSTANCE_ID="non-aws-instance"
AWS_INSTANCE_TYPE="non-aws-instance-type"
AWS_INSTANCE_CLASS=${AWS_INSTANCE_TYPE%%.*}
AWS_INSTANCE_SIZE=${AWS_INSTANCE_TYPE#*.}
AWS_AMI_ID=""
AWS_PRIVATE_IP=$(ip a s eth0 | grep -E -o 'inet [0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | cut -d' ' -f2)

AWS_PUBLIC_IP=$(curl ifconfig.me)

AWS_AZ="dc01"
AWS_MAC=$(ip a s eth0 | grep -o -E ..:..:..:..:..:.. | head -n1)
AWS_SUBNET_ID="non-aws-subnet-id"
AWS_SUBNET_CIDR=$(echo $AWS_PRIVATE_IP | awk -F '.' '{print $1"."$2"."0"."0"/"16}')
AWS_REGION="eu-west-1"
AWS_SUBNET_PREFIX=$(echo $AWS_SUBNET_CIDR | cut -d'/' -f2)

sudo tee /etc/profile.d/awsvars.sh <<EOF
export APP_CLOUD=NON-AWS
export AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID}
export AWS_INSTANCE_ID=${AWS_INSTANCE_ID}
export AWS_INSTANCE_TYPE=${AWS_INSTANCE_TYPE}
export AWS_INSTANCE_CLASS=${AWS_INSTANCE_CLASS}
export AWS_INSTANCE_SIZE=${AWS_INSTANCE_SIZE}
export AWS_AMI_ID=${AWS_AMI_ID}
export AWS_REGION=${AWS_REGION}
export AWS_AZ=${AWS_AZ}
export AWS_MAC=${AWS_MAC}
export AWS_SUBNET_ID=${AWS_SUBNET_ID}
export AWS_SUBNET_CIDR=${AWS_SUBNET_CIDR}
export AWS_SUBNET_PREFIX=${AWS_SUBNET_PREFIX}
export AWS_PRIVATE_IP=${AWS_PRIVATE_IP}
export AWS_PUBLIC_IP=${AWS_PUBLIC_IP}
export APP_PUBLIC_IP=${AWS_PUBLIC_IP}
export APP_PRIVATE_IP=${AWS_PRIVATE_IP}
export APP_PROJECT=${APP_PROJECT}
export APP_ENVIRONMENT=${APP_ENVIRONMENT}
export APP_ROLE=${APP_ROLE}
export AWS_STACK=${AWS_STACK}
export AWS_ENVIRONMENT=${APP_ENVIRONMENT}
export AWS_PROJECT=${APP_PROJECT}

export APP_XMPP_USERNAME=${APP_XMPP_USERNAME}
export APP_XMPP_PASSWORD=${APP_XMPP_PASSWORD}
export APP_HOSTED_ZONE_ID=${APP_HOSTED_ZONE_ID}
export APP_DOMAIN_NAME=${APP_DOMAIN_NAME}
export APP_GRAPHITE_HOST=${APP_GRAPHITE_HOST}
export APP_ALTERNATIVE_DOMAIN_NAME=${APP_ALTERNATIVE_DOMAIN_NAME}
export IOS_DOMAIN_NAME=${IOS_DOMAIN_NAME}
export ALLOW_PING=1
EOF

# Below can be removed when all apps have been migrated to naming convention
source /etc/profile.d/awsvars.sh
