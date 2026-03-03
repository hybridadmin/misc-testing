#!/usr/bin/env bash
source /etc/profile.d/awsvars.sh

SERVER_ROLE=$1
if [ ! -n "${SERVER_ROLE}" ]; then echo "SERVER_ROLE is unset"; exit 1; fi

AWS_ACCESS_KEY_ID=$2
if [ ! -n "${AWS_SECRET_ACCESS_KEY}" ]; then echo "AWS_SECRET_ACCESS_KEY is unset"; exit 1; fi

AWS_SECRET_ACCESS_KEY=$3
if [ ! -n "${AWS_ACCESS_KEY_ID}" ]; then echo "AWS_ACCESS_KEY_ID is unset"; exit 1; fi


ADMIN_USER="moyaadmin"
# Create user(s)/bin folder(s)
for user_name in "binu" "${ADMIN_USER}"; do
    if [ ! -d /home/$user_name ]; do
        sudo useradd -m -s /sbin/nologin $user_name
    if

    if [ ! -d "/home/${user_name}/.local/bin" ] ; then
        mkdir -p "/home/${user_name}/.local/bin"
        printf '\nexport "PATH=$PATH:'/home/${user_name}/.local/bin'"' >> "/home/${user_name}/.bashrc"
        # Change the PATH right now:
        PATH="$PATH:/home/$user_name/.local/bin"
    fi
done

# Copy scripts
_SOURCE_DIR=$HOME/moya-xmpp-baremetal/scripts/misc
for SCRIPT in $(ls $_SOURCE_DIR); do cp $_SOURCE_DIR/$SCRIPT /usr/local/bin ; done
/usr/local/bin/aws_init.sh "597684347793" "1GRID" "xmpp.onpremise.moya.app" "Z07579363KLIWSZ4REYFT"

# Install packages
sudo apt install -y wget ruby unzip postgresql-client-18 selinux-utils rsync incron

if [[ "${SERVER_ROLE}" =~ (ejabberd|postgres) ]]; do
    # Install docker
    wget -qO - https://get.docker.com -o get-docker.sh | sh -
    sudo usermod -aG docker $USER
    newgrp docker

    sudo tee -a /etc/docker/daemon.json <<EOF
    {
      "log-driver": "json-file",
      "log-opts": {
        "max-size": "100m",
        "max-file": "5"
      }
    }
EOF
    sudo systemctl restart docker

    ## Install docker-compose
    sudo apt install -y docker-compose-plugin
    echo "alias docker-compose='docker compose'" | sudo tee -a /etc/bash.bashrc
fi

## Install python/ansible
sudo apt install -y python3-pip
sudo python3 -m pip install jinjanator==25.3.0 boto3 docker PyMySQL
sudo python3 -m pip install ansible-core==2.15.13
for COLLECTION in "amazon.aws" "community.docker" "community.mysql" "ansible.posix" "community.general"; do sudo ansible-galaxy collection install ${COLLECTION}; done

# Install AWS cli
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# setup sshkey for repo clone
sudo touch /root/.ssh/github.key
sudo chmod 0600 /root/.ssh/github.key

sudo tee /root/.ssh/config <<EOT
Host github.com
    IdentityFile ~/.ssh/github.key
    StrictHostKeyChecking no
EOT
sudo chmod 0600 /root/.ssh/config
ssh-keyscan -H github.com | sudo tee -a /root/.ssh/known_hosts

# Symlink pip to /bin
if [ ! -f /bin/pip-3 ]; then
    INSTALLED_PIP3=$(find /usr/bin/ | grep pip3 | head -n1)
    ln -s ${INSTALLED_PIP3} /bin/pip-3
fi

# Setup AWS cred
mkdir -p /{root,home/${ADMIN_USER}}/.aws/
tee -a /home/${ADMIN_USER}/.aws/config <<EOF
[default]
aws_access_key_id = \${AWS_ACCESS_KEY_ID}
aws_secret_access_key = \${AWS_SECRET_ACCESS_KEY}
EOF
sudo chown -R ${ADMIN_USER}:${ADMIN_USER} /home/${ADMIN_USER}/.aws

# Install aws codedeploy session handler
## git clone https://github.com/awslabs/aws-codedeploy-samples.git
sudo apt-get install git ruby rubygems
sudo gem install aws-sdk-core
sudo gem install aws-codedeploy-session-helper

SERVER_ROLE_CAPITALIZED="$(tr '[:lower:]' '[:upper:]' <<< ${SERVER_ROLE:0:1})${SERVER_ROLE:1}"

sudo tee /etc/cron.d/aws-codedeploy-session-helper <<EOF
0,15,30,45 * * * * ${ADMIN_USER} /home/${ADMIN_USER}/.local/bin/update_sts_token.sh
EOF

sudo tee /home/${ADMIN_USER}/.local/bin/update_sts_token.sh <<EOF
#!/usr/bin/env bash
/usr/local/bin/get_sts_creds --role-arn "arn:aws:iam::\${AWS_ACCOUNT_ID}:role/\${APP_PROJECT}-\${APP_ENVIRONMENT}-\${SERVER_ROLE_CAPITALIZED}-OnPremise" --region "${AWS_REGION}" --file /home/${ADMIN_USER}/.aws/aws_session_creds
EOF
sudo chmod +x /home/${ADMIN_USER}/.local/bin/update_sts_token.sh
sudo chown -R ${ADMIN_USER}:${ADMIN_USER} /home/${ADMIN_USER}/.local/bin/update_sts_token.sh

# incron - https://www.cyberciti.biz/faq/linux-inotify-examples-to-replicate-directories/
sudo tee /etc/incron.d/sync_aws_creds <<EOF
/home/${ADMIN_USER}/.aws IN_MODIFY,IN_CREATE sh -c '/usr/local/bin/sync_aws_creds.sh; exit 1'
EOF

sudo tee /usr/local/bin/sync_aws_creds.sh <<EOF
cp /home/${ADMIN_USER}/.aws/aws_session_creds /root/.aws/credentials
systemctl reload codedeploy-agent
EOF
chmod +x /usr/local/bin/sync_aws_creds.sh

# Install Codedeploy
wget "https://aws-codedeploy-${AWS_REGION}.s3.${AWS_REGION}.amazonaws.com/latest/install"
chmod +x ./install
sudo ./install auto

sudo tee -a /etc/codedeploy-agent/conf/codedeploy.onpremises.yml <<EOF
iam_session_arn: arn:aws:sts::\${AWS_ACCOUNT_ID}:assumed-role/\${APP_PROJECT}-\${APP_ENVIRONMENT}-\${SERVER_ROLE_CAPITALIZED}-OnPremise/\${HOSTNAME}.internal.${APP_DOMAIN_NAME}
aws_credentials_file: /root/.aws/credentials
region: \${AWS_REGION}
EOF

## codedeploy reload fix - https://github.com/aws/aws-codedeploy-agent/issues/354
sed -i $'/status)/i\\\treload)\\n\\t\\tPROC_PID=$(ps aux | grep -E "codedeploy-agent: [master]" | awk \'{print \$2}\')\\n\\\t\\t/bin/kill -USR2 \$PROC_PID\\n\\\t\\tstart\\n\\\t\\t;;' /etc/init.d/codedeploy-agent
sed -i 's/status|restart/status|restart|reload/g' /etc/init.d/codedeploy-agent
systemctl daemon-reload
systemctl reload codedeploy-agent

#/usr/local/bin/get_sts_creds --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${APP_PROJECT}-${APP_ENVIRONMENT}-${SERVER_ROLE_CAPITALIZED}-OnPremise" \
#        --region "${AWS_REGION}" --file /home/${ADMIN_USER}/.aws/aws_session_creds

