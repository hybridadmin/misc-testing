#!/usr/bin/env bash

source /etc/profile.d/awsvars.sh

export AWS_ACCESS_KEY_ID=$(cat /home/moyaadmin/.aws/aws_session_creds | grep "aws_access_key_id" |sed 's/aws_access_key_id = //')
export AWS_SECRET_ACCESS_KEY=$(cat /home/moyaadmin/.aws/aws_session_creds | grep "aws_secret_access_key" |sed 's/aws_secret_access_key = //')
export AWS_SESSION_TOKEN=$(cat /home/moyaadmin/.aws/aws_session_creds | grep "aws_session_token" |sed 's/aws_session_token = //')

function update_route53_dns(){
        DNS_HOSTNAME=$1
        PRIVATE_IP=$2

        UPDATE_DNS=$(aws route53 change-resource-record-sets --hosted-zone-id "${APP_HOSTED_ZONE_ID}" --change-batch '{"Changes": [{"Action": "UPSERT","ResourceRecordSet": {"Name": "'"${DNS_HOSTNAME}"'","Type": "A","TTL": 60,"ResourceRecords": [{"Value": "'"${PRIVATE_IP}"'"}]}}]}')
        DNS_CHANGE_ID=$(echo $UPDATE_DNS | jq -r ".ChangeInfo.Id")

        DNS_CHANGE_STATUS="PENDING"
        while [ "$DNS_CHANGE_STATUS" != "INSYNC" ]
        do
                DNS_CHANGE_STATUS=$(aws route53 get-change --id $DNS_CHANGE_ID | jq -r '.ChangeInfo.Status')
                sleep 1
        done
        if [[ "$DNS_CHANGE_STATUS" == "INSYNC"  ]]; then echo "DnsName ${DNS_HOSTNAME} has successfully updated to point to ${PRIVATE_IP}"; fi

}

#Execute fw script if exists for reboots
if [ -f /usr/local/bin/firewall.sh ]; then
        /usr/local/bin/firewall.sh start
fi

# Add additonal internal ip addresses
#for i in $ASSIGNED_IPS ; do
#  	sudo ip addr add $i dev eth0
#done

# Generate container name
if ! $(grep -q "ejabberd" /etc/hosts); then
  	INSTANCE_INDEX_NO=$(echo $HOSTNAME | cut -d '-' -f3 | sed 's/^0*//')
  	APP_CONTAINER_NAME=$(printf "ejabberd-%02d" $INSTANCE_INDEX_NO)
  	echo "${APP_PRIVATE_IP}    ${APP_CONTAINER_NAME}" | tee -a /etc/hosts
  	echo "export APP_CONTAINER_NAME=$APP_CONTAINER_NAME" | tee -a /etc/profile

        # Update DnsName in Route53
        APP_DOMAIN_NAME=$(aws route53 get-hosted-zone --id "${APP_HOSTED_ZONE_ID}" --query 'HostedZone.Name' --output text | sed 's/.$//')
        # NB: DnsName format should be as below:
        # PROD - ejabberd-02.internal.xmpp.moya.app
        # SYSTEST - ejabberd-02.internal.xmpp.systest.moya.app

        if [[ "${APP_ENVIRONMENT,,}" =~ (prod) ]]; then
          APP_DNS_HOSTNAME="${APP_CONTAINER_NAME}.internal.${APP_DOMAIN_NAME}"
        else
          APP_DNS_HOSTNAME="${APP_CONTAINER_NAME}.internal.${APP_PROJECT,,}.${APP_DOMAIN_NAME}"
        fi
        # Export APP_DNS_HOSTNAME to use as fqdn in ERLANG_NODE setting in ejabberdctl.cfg
        echo "export APP_DNS_HOSTNAME=$APP_DNS_HOSTNAME" | tee -a /etc/profile
        update_route53_dns ${APP_DNS_HOSTNAME} ${AWS_PRIVATE_IP}

        # Update hostname
        hostnamectl set-hostname ${APP_DNS_HOSTNAME}
fi

## Restrict SSH Access to bastion only
#cat > /usr/local/bin/update_hosts_allow.sh << 'EOL'
##!/usr/bin/env bash
#source /etc/profile.d/awsvars.sh
#

#APP_BASTION_ASG=$(aws cloudformation describe-stack-resources --stack-name "${APP_PROJECT}-${APP_ENVIRONMENT}-BASTION" --region $AWS_REGION | jq -r '.StackResources | map(select(.ResourceType == "AWS::AutoScaling::AutoScalingGroup"))' | jq -r '.[].PhysicalResourceId')
#APP_BASTION_INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name ${APP_BASTION_ASG} | jq -r '.AutoScalingGroups[].Instances[0].InstanceId')
#APP_BASTION_PRIVATE_IP=$(aws ec2 describe-instances --instance-ids ${APP_BASTION_INSTANCE_ID} | jq -r '.Reservations[].Instances[].PrivateIpAddress')
#if grep -Fq "sshd" /etc/hosts.allow; then
#        sed -i -e "s/^sshd.*/sshd: ${APP_BASTION_PRIVATE_IP}/g" /etc/hosts.allow
#else
#        sed -i "/^ALL.*/i sshd: ${APP_BASTION_PRIVATE_IP}" /etc/hosts.allow
#fi
#EOL
#chmod +x /usr/local/bin/update_hosts_allow.sh
#
#cat > /etc/cron.d/refresh_hosts_allow << 'EOL'
#*/5 * * * * root /usr/local/bin/update_hosts_allow.sh
#EOL

if [ ! -f "/etc/init.d/codedeploy-agent" ]; then
        #Install codedeploy
        cd /home/binu/
        wget https://aws-codedeploy-eu-west-1.s3.amazonaws.com/latest/install
        chmod +x ./install
        ./install auto
fi
